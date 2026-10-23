import AVFoundation
import Foundation

/// Keeps a 16 kHz mono copy of the dictation so it can be sent for cloud
/// transcription once the key is released. Memory only, dropped on the next take.
///
/// Receives on the audio thread, so the sample store is lock-protected.
final class AudioRecorder {
    private let lock = NSLock()
    private let converter = BufferConverter()
    private var samples = Data()
    private var overflowed = false
    private var pcmHandler: ((Data) -> Void)?

    /// Each converted chunk as it is captured, for streaming. Audio thread.
    var onPCM: ((Data) -> Void)? {
        get { lock.withLock { pcmHandler } }
        set { lock.withLock { pcmHandler = newValue } }
    }

    private static let sampleRate: Double = 16_000
    private let format = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: AudioRecorder.sampleRate, channels: 1, interleaved: true
    )!

    /// About 7 minutes. Inline audio has to keep the whole request under 20 MB,
    /// and base64 inflates it by a third. Past this, `wav()` returns nil and the
    /// on-device transcript is used instead of a truncated cloud one.
    private static let maximumBytes = 32_000 * 60 * 7

    func reset() {
        lock.withLock {
            samples.removeAll(keepingCapacity: true)
            overflowed = false
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let converted = try? converter.convertBuffer(buffer, to: format),
              let channel = converted.int16ChannelData else { return }
        let frames = Int(converted.frameLength)
        let chunk = Data(buffer: UnsafeBufferPointer(start: channel[0], count: frames))
        let handler: ((Data) -> Void)? = lock.withLock {
            if !overflowed {
                if samples.count + chunk.count <= Self.maximumBytes {
                    samples.append(chunk)
                } else {
                    overflowed = true
                }
            }
            return pcmHandler
        }
        handler?(chunk)
    }

    /// The take as a 16-bit PCM WAV file, or nil when empty or too long.
    func wav() -> Data? {
        let pcm: Data? = lock.withLock { overflowed || samples.isEmpty ? nil : samples }
        guard let pcm else { return nil }

        var header = Data()
        func append32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) } }

        let rate = UInt32(Self.sampleRate)
        header.append(contentsOf: Array("RIFF".utf8))
        append32(UInt32(36 + pcm.count))
        header.append(contentsOf: Array("WAVEfmt ".utf8))
        append32(16)            // fmt chunk size
        append16(1)             // PCM
        append16(1)             // mono
        append32(rate)
        append32(rate * 2)      // byte rate
        append16(2)             // block align
        append16(16)            // bits per sample
        header.append(contentsOf: Array("data".utf8))
        append32(UInt32(pcm.count))
        return header + pcm
    }
}
