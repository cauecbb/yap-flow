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
            panel.reposition(on: screen, animated: true)
        }
    }

    func setPartial(_ text: String) {
        model.partial = text
    }

    func hide(after seconds: Double) {
        hideTask?.cancel()
        guides.hide()
        dragStart = nil
        guard seconds > 0 else {
            panel?.orderOut(nil)
            model.controlsVisible = true
            return
        }
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.panel?.orderOut(nil)
            self?.model.controlsVisible = true
        }
    }
}
