import Observation

enum HUDDragPhase { case changed, ended }

@MainActor
@Observable
final class HUDModel {
    static let waveformSampleCount = 32

    var phase: HUDPhase = .listening
    var level: Float = 0
    // Rolling window, oldest first: drawn as a scrolling waveform so the meter reads as a timeline rather than a single bouncing bar.
    var levels: [Float] = Array(repeating: 0, count: HUDModel.waveformSampleCount)
    var partial: String = ""
    var device: String?
    // Cancel/finish buttons. Hidden while fn is held (releasing it is the finish),
    // shown in hands-free and for every other trigger.
    var controlsVisible = true
    // Docked to a side of the screen: the pill stands up.
    var vertical = false
    var onDrag: ((HUDDragPhase) -> Void)?

    var onConfirm: (() -> Void)?
    var onCancel: (() -> Void)?
}
