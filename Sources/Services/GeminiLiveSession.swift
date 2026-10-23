import Foundation

/// A cloud transcription that streams while the user talks.
protocol CloudStream: AnyObject {
    /// 16 kHz mono 16-bit PCM. Called on the audio thread.
    func append(_ pcm: Data)
    /// The SMART transcript, or nil on any failure or timeout so the caller can
    /// fall back to the one-shot request.
    func finish() async -> String?
    func cancel()
}

/// One dictation streamed to Gemini 3.5 Transcribe Live over a WebSocket. Audio
/// goes up in 100 ms chunks as it is spoken, with push-to-talk turn control
/// (activityStart/activityEnd) instead of server-side silence detection, so on
/// release only the tail is left to transcribe. That is what makes the paste
/// land as fast as Wispr's instead of waiting on a whole-file upload.
///
/// All state is confined to `queue`.
final class GeminiLiveSession: CloudStream, @unchecked Sendable {
    var onError: ((String) -> Void)?

    private let queue = DispatchQueue(label: "com.frigade.yap.gemini-live")
    private let task: URLSessionWebSocketTask
    private let setup: String

    private var ready = false
    private var endRequested = false
    private var endSent = false
    private var finalAfterEnd = false
    private var completed = false
    private var completedValue: String?
    private var pending: [Data] = []
    private var chunk = Data()
    private var transcript = ""
    private var settleWork: DispatchWorkItem?
    private var continuation: CheckedContinuation<String?, Never>?

    /// 100 ms of 16 kHz, 16-bit mono audio, the chunk size the docs ask for.
    private static let chunkBytes = 3_200
    /// After a final transcript, how long to wait for another segment.
    private static let settle: TimeInterval = 0.2
    /// Past this after release, the one-shot request is the faster bet.
    private static let finishTimeout: TimeInterval = 3

    init(task: URLSessionWebSocketTask, setup: [String: Any]) {
        self.task = task
        let data = (try? JSONSerialization.data(withJSONObject: ["setup": setup])) ?? Data()
        self.setup = String(decoding: data, as: UTF8.self)
    }

    func start() {
        queue.async { [self] in
            task.resume()
            send(setup)
            receive()
        }
    }

    func append(_ pcm: Data) {
        queue.async { [self] in
            guard !endRequested, !completed else { return }
            chunk.append(pcm)
            if chunk.count >= Self.chunkBytes {
                sendAudio(chunk)
                chunk.removeAll(keepingCapacity: true)
            }
        }
    }

    func finish() async -> String? {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard !completed else {
                    continuation.resume(returning: completedValue)
                    return
                }
                self.continuation = continuation
                if !chunk.isEmpty {
                    sendAudio(chunk)
                    chunk.removeAll()
                }
                endRequested = true
                sendEndIfReady()
                queue.asyncAfter(deadline: .now() + Self.finishTimeout) { [self] in
                    complete(finalAfterEnd ? cleaned : nil)
                }
            }
        }
    }

    func cancel() {
        queue.async { [self] in complete(nil) }
    }

    // MARK: - Protocol

    private func sendAudio(_ data: Data) {
        guard ready else {
            // The socket is still opening: hold the first words until setup lands.
            pending.append(data)
            return
        }
        send(#"{"realtimeInput":{"audio":{"mimeType":"audio/pcm;rate=16000","data":"\#(data.base64EncodedString())"}}}"#)
    }

    private func sendEndIfReady() {
        guard ready, endRequested, !endSent else { return }
        endSent = true
        send(#"{"realtimeInput":{"activityEnd":{}}}"#)
    }

    private func send(_ text: String) {
        task.send(.string(text)) { [weak self] error in
            guard let self, let error else { return }
            self.queue.async { self.fail("Gemini live send failed: \(error.localizedDescription)") }
        }
    }

    private func receive() {
        task.receive { [weak self] outcome in
            guard let self else { return }
            self.queue.async {
                switch outcome {
                case .success(let message):
                    self.handle(message)
                    if !self.completed { self.receive() }
                case .failure(let error):
                    self.fail("Gemini live connection failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message {
        case .string(let text): data = Data(text.utf8)
        case .data(let bytes): data = bytes
        @unknown default: return
        }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }

        if json["setupComplete"] != nil {
            ready = true
            send(#"{"realtimeInput":{"activityStart":{}}}"#)
            let held = pending
            pending.removeAll()
            held.forEach(sendAudio)
            sendEndIfReady()
            return
        }

        if let error = json["error"] as? [String: Any] {
            fail("Gemini live error: \(error["message"] as? String ?? "unknown")")
            return
        }

        guard let content = json["serverContent"] as? [String: Any] else { return }
        if let text = (content["inputTranscription"] as? [String: Any])?["text"] as? String {
            merge(text)
            if endSent {
                finalAfterEnd = true
                scheduleSettle()
            }
        }
        if (content["turnComplete"] as? Bool) == true, endSent, finalAfterEnd {
            complete(cleaned)
        }
    }

    /// Finals arrive per segment. Joined as they come, with a space where a
    /// segment doesn't bring its own; a segment that repeats everything so far
    /// replaces it instead.
    private func merge(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if transcript.isEmpty || text.hasPrefix(transcript) {
            transcript = text
            return
        }
        let needsSpace = !(transcript.last?.isWhitespace ?? true)
            && !(text.first.map { $0.isWhitespace || ",.!?;:".contains($0) } ?? true)
        transcript += (needsSpace ? " " : "") + text
    }

    private var cleaned: String? {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private func scheduleSettle() {
        settleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.complete(self.cleaned)
        }
        settleWork = work
        queue.asyncAfter(deadline: .now() + Self.settle, execute: work)
    }

    private func fail(_ message: String) {
        guard !completed else { return }
        onError?(message)
        complete(nil)
    }

    private func complete(_ value: String?) {
        guard !completed else { return }
        completed = true
        completedValue = value
        settleWork?.cancel()
        continuation?.resume(returning: value)
        continuation = nil
        task.cancel(with: .normalClosure, reason: nil)
    }
}
