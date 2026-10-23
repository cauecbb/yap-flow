import SwiftUI

/// A Wispr Flow-style bar: a small dark pill at the bottom of the screen with a
/// white waveform. No live transcript. Cancel and finish buttons appear only
/// when there is no held key to release (hands-free and the other triggers).
/// Between dictations, with "Always show the bar" on, it rests as a thin pill
/// that starts a dictation when clicked.
struct RecordingHUDView: View {
    @Bindable var model: HUDModel

    var body: some View {
        Group {
            if model.phase == .idle {
                RestingPill(vertical: model.vertical)
                    .onTapGesture { model.onStart?() }
            } else {
                activePill
            }
        }
        // Drag the bar anywhere; dropped near a side it docks there standing up.
        .gesture(
            DragGesture(minimumDistance: 3)
                .onChanged { _ in model.onDrag?(.changed) }
                .onEnded { _ in model.onDrag?(.ended) }
        )
        // A fixed canvas: the panel is sized once on show, and the pill grows
        // inside it when hands-free adds the buttons instead of being clipped.
        .frame(width: canvas.width, height: canvas.height)
        .padding(Self.shadowInsets)
        .environment(\.colorScheme, .dark)
        .animation(.spring(duration: 0.22), value: showsButtons)
        .animation(.easeInOut(duration: 0.18), value: model.phase)
    }

    private var activePill: some View {
        let vertical = model.vertical
        let layout = vertical ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))

        return layout {
            if showsButtons {
                PillButton(systemName: "xmark", prominent: false) { model.onCancel?() }
                    .help("Discard")
            }

            content
                .frame(minWidth: vertical ? nil : 44, minHeight: vertical ? 44 : nil)

            if showsButtons {
                PillButton(systemName: "stop.fill", prominent: true) { model.onConfirm?() }
                    .help("Finish and insert")
            }
        }
        .padding(vertical ? Edge.Set.vertical : .horizontal, showsButtons ? 4 : 10)
        .frame(width: vertical ? 28 : nil, height: vertical ? nil : 28)
        .background(Capsule(style: .continuous).fill(Color.black.opacity(0.9)))
        .overlay(Capsule(style: .continuous).strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
        .shadow(color: .black.opacity(0.28), radius: 10, y: 4)
        .contentShape(Capsule(style: .continuous))
    }

    static let shadowInsets = EdgeInsets(top: 8, leading: 8, bottom: 16, trailing: 8)

    private var canvas: CGSize {
        HUDPlacement.canvas(vertical: model.vertical, idle: model.phase == .idle)
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .idle, .listening:
            Waveform(levels: model.levels, vertical: model.vertical)
        case .transcribing, .cleaning:
            ProcessingDots(vertical: model.vertical)
        case .confirmCancel:
            PillLabel("Press esc again to cancel", systemName: "escape", compact: model.vertical)
        case .restarting:
            PillLabel("Restarting Yap", systemName: "arrow.clockwise", compact: model.vertical)
        }
    }

    private var showsButtons: Bool {
        model.controlsVisible && (model.phase == .listening || model.phase == .confirmCancel)
    }
}

/// The bar between dictations: a thin pill that swells under the pointer.
private struct RestingPill: View {
    let vertical: Bool
    @State private var hovering = false

    var body: some View {
        let length: CGFloat = hovering ? 46 : 34
        let thickness: CGFloat = hovering ? 12 : 7

        Capsule(style: .continuous)
            .fill(Color.black.opacity(hovering ? 0.85 : 0.55))
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(Color.white.opacity(hovering ? 0.55 : 0.32), lineWidth: 1)
            )
            .frame(width: vertical ? thickness : length, height: vertical ? length : thickness)
            .shadow(color: .black.opacity(0.2), radius: 4, y: 1)
            // A target bigger than the pill. Not fully clear, or the window
            // server would let clicks fall through to the app underneath.
            .frame(width: vertical ? 22 : 54, height: vertical ? 54 : 22)
            .background(Color.black.opacity(0.01))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.15), value: hovering)
            .help("Click to dictate, or hold fn")
    }
}

/// Text on a horizontal bar; just the symbol when it stands up and there's no room.
private struct PillLabel: View {
    let text: String
    let systemName: String
    let compact: Bool

    init(_ text: String, systemName: String, compact: Bool) {
        self.text = text
        self.systemName = systemName
        self.compact = compact
    }

    var body: some View {
        Group {
            if compact {
                Image(systemName: systemName)
                    .font(.system(size: 12, weight: .semibold))
                    .help(text)
            } else {
                Text(text)
                    .font(.system(size: 12, weight: .medium))
                    .fixedSize()
            }
        }
        .foregroundStyle(.white.opacity(0.9))
    }
}

private struct PillButton: View {
    let systemName: String
    let prominent: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: prominent ? 8 : 9, weight: .bold))
                .foregroundStyle(prominent ? Color.white : Color.white.opacity(0.8))
                .frame(width: 20, height: 20)
                .background {
                    Circle().fill(
                        prominent
                            ? Theme.recording.opacity(hovering ? 1.0 : 0.88)
                            : Color.white.opacity(hovering ? 0.22 : 0.12)
                    )
                }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// The newest samples, drawn as white bars that swell toward the middle, so the
/// pill pulses with your voice and rests as a row of dots in silence.
private struct Waveform: View {
    let levels: [Float]
    var vertical = false

    private static let barCount = 12
    private let barWidth: CGFloat = 2.5
    private let spacing: CGFloat = 2
    private let minHeight: CGFloat = 2.5
    private let maxHeight: CGFloat = 14

    var body: some View {
        let recent = Array(levels.suffix(Self.barCount))
        // Standing up, the bars lie down and stack: the same meter turned 90°.
        let layout = vertical ? AnyLayout(VStackLayout(spacing: spacing)) : AnyLayout(HStackLayout(spacing: spacing))
        layout {
            ForEach(recent.indices, id: \.self) { index in
                let length = height(for: recent[index], at: index, of: recent.count)
                Capsule()
                    .fill(Color.white.opacity(0.95))
                    .frame(width: vertical ? length : barWidth, height: vertical ? barWidth : length)
            }
        }
        .frame(width: vertical ? maxHeight : nil, height: vertical ? nil : maxHeight)
        .animation(.easeOut(duration: 0.08), value: levels)
    }

    private func height(for level: Float, at index: Int, of count: Int) -> CGFloat {
        // Center bars reach full height, the edges about half.
        let position = count > 1 ? Double(index) / Double(count - 1) : 0.5
        let envelope = 0.5 + 0.5 * sin(.pi * position)
        let boosted = min(1, Double(max(0, level)) * 1.4)
        return minHeight + (maxHeight - minHeight) * CGFloat(boosted * envelope)
    }
}

/// Three dots breathing in turn while the transcript is finished and cleaned up.
private struct ProcessingDots: View {
    var vertical = false

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let layout = vertical ? AnyLayout(VStackLayout(spacing: 5)) : AnyLayout(HStackLayout(spacing: 5))
            layout {
                ForEach(0..<3, id: \.self) { index in
                    let phase = (t * 2.4 - Double(index) * 0.45).truncatingRemainder(dividingBy: 2 * .pi)
                    let pulse = 0.5 + 0.5 * sin(phase)
                    Circle()
                        .fill(Color.white.opacity(0.35 + 0.6 * pulse))
                        .frame(width: 5, height: 5)
                        .scaleEffect(0.8 + 0.3 * pulse)
                }
            }
        }
        .frame(width: vertical ? 14 : nil, height: vertical ? nil : 14)
    }
}
