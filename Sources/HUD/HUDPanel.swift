import AppKit
import SwiftUI

final class HUDPanel: NSPanel {
    init(model: HUDModel) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 386, height: 76),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        // Dragging is handled by the view, so the drop can snap to an edge.
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false // the SwiftUI view draws its own soft shadow

        let hosting = NSHostingView(rootView: RecordingHUDView(model: model))
        hosting.autoresizingMask = [.width, .height]
        contentView = hosting
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Places the bar on its saved spot. `screen` is the one it was just dropped
    /// on; otherwise it follows the app being dictated into. `animated` glides it
    /// there, for the snap after a drag.
    func reposition(on screen: NSScreen? = nil, animated: Bool = false) {
        // Anchor to the screen holding the app being dictated into. Fall back to
        // the mouse's screen, then the main one, so the widget still lands
        // somewhere sensible when no focused window can be resolved.
        guard let screen = screen
            ?? FocusedWindow.screen()
            ?? NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.main else { return }

        let target = HUDPlacement.frame(for: HUDPlacement.edge, in: screen.visibleFrame)
        guard animated else {
            setFrame(target, display: true)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().setFrame(target, display: true)
        }
    }
}
