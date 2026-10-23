import AppKit

@MainActor
final class HUDController: HUDControlling {
    private let model = HUDModel()
    private var panel: HUDPanel?
    private var hideTask: Task<Void, Never>?

    // Fast attack so speech registers immediately, slower release so bars glide back instead of snapping to zero between words.
    private var smoothedLevel: Float = 0

    // Where the drag began, in screen coordinates. The view moves with the
    // window, so its own gesture translation can't be trusted mid-drag.
    private var dragStart: (mouse: NSPoint, origin: NSPoint)?
    private let guides = HUDDropGuides()
    private var screenObserver: NSObjectProtocol?

    /// Whether the bar stays on screen between dictations, as a resting pill.
    var alwaysVisible: () -> Bool = { false }

    /// A click on the resting pill.
    var onIdleTap: (() -> Void)? {
        get { model.onStart }
        set { model.onStart = newValue }
    }

    func setActions(onConfirm: @escaping () -> Void, onCancel: @escaping () -> Void) {
        model.onConfirm = onConfirm
        model.onCancel = onCancel
    }

    // Built ahead of time: creating it on first use rendered an unlaid-out window for a frame — a flicker before "Listening" appeared.
    func prepare() {
        guard panel == nil else { return }
        model.onDrag = { [weak self] phase in self?.handleDrag(phase) }
        model.vertical = HUDPlacement.edge.isVertical
        let panel = HUDPanel(model: model)
        panel.alphaValue = 0
        panel.reposition()
        self.panel = panel

        // A display plugged in or rearranged moves the edges the pill rests on.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.model.phase == .idle else { return }
                self.rest()
            }
        }
    }

    /// Between dictations: the resting pill on its saved spot, or nothing when
    /// the bar is set to show only while dictating.
    func rest() {
        hideTask?.cancel()
        guides.hide()
        dragStart = nil
        model.controlsVisible = true
        guard alwaysVisible() else {
            panel?.orderOut(nil)
            return
        }

        prepare()
        guard let panel else { return }
        model.phase = .idle
        model.vertical = HUDPlacement.edge.isVertical
        panel.reposition(idle: true)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
    }

    func show(device: String?) {
        hideTask?.cancel()

        // Reset state BEFORE the panel is on screen, so no stale frame from the previous session is ever visible.
        model.device = device
        model.partial = ""
        model.level = 0
        model.levels = Array(repeating: 0, count: HUDModel.waveformSampleCount)
        model.phase = .listening
        model.vertical = HUDPlacement.edge.isVertical
        smoothedLevel = 0
        dragStart = nil

        prepare()
        guard let panel else { return }

        panel.alphaValue = 0
        panel.reposition()
        panel.orderFrontRegardless()

        // Short fade covers any residual first-frame layout settling.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }
    }

    func setPhase(_ phase: HUDPhase) {
        model.phase = phase
    }

    /// Set before `show` for an fn hold; it stays until the next hide.
    func setControlsVisible(_ visible: Bool) {
        model.controlsVisible = visible
    }

    func setLevel(_ level: Float) {
        // Very fast attack keeps transients visible; gentler release lets the trace fall away instead of collapsing between syllables.
        let coefficient: Float = level > smoothedLevel ? 0.75 : 0.22
        smoothedLevel += (level - smoothedLevel) * coefficient
        model.level = smoothedLevel

        var samples = model.levels
        samples.removeFirst()
        samples.append(smoothedLevel)
        model.levels = samples
    }

    /// Follows the pointer while dragging, with the dock spots outlined and the
    /// nearest one lit; on drop, glides into that spot (standing up on the
    /// sides) and remembers it for next time.
    private func handleDrag(_ phase: HUDDragPhase) {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) })
            ?? panel.screen ?? NSScreen.main else { return }

        switch phase {
        case .changed:
            if dragStart == nil { dragStart = (mouse, panel.frame.origin) }
            guard let start = dragStart else { return }
            panel.setFrameOrigin(NSPoint(
                x: start.origin.x + mouse.x - start.mouse.x,
                y: start.origin.y + mouse.y - start.mouse.y
            ))
            if guides.screen != screen { guides.show(on: screen, below: panel) }
            guides.highlight(HUDPlacement.nearest(to: panel.frame, in: screen.visibleFrame))
        case .ended:
            dragStart = nil
            guides.hide()
            let edge = HUDPlacement.nearest(to: panel.frame, in: screen.visibleFrame)
            HUDPlacement.save(edge: edge)
            model.vertical = edge.isVertical
            panel.reposition(on: screen, idle: model.phase == .idle, animated: true)
        }
    }

    func setPartial(_ text: String) {
        model.partial = text
    }

    func hide(after seconds: Double) {
        guard seconds > 0 else {
            rest()
            return
        }
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.rest()
        }
    }
}
