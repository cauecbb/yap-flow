import AppKit
import Observation
import SwiftUI

/// While the bar is dragged, outlines the spots it can dock to and lights up
/// the one it will snap to on release, the way Wispr Flow's bar does.
@MainActor
final class HUDDropGuides {
    private let model = DropGuidesModel()
    private var panel: NSPanel?
    private(set) var screen: NSScreen?

    func show(on screen: NSScreen, below hud: NSWindow) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        self.screen = screen

        // Slots in the view's top-left coordinates.
        let frame = screen.frame
        var slots: [HUDEdge: CGRect] = [:]
        for edge in HUDEdge.allCases {
            let slot = HUDPlacement.slot(for: edge, in: screen.visibleFrame)
            slots[edge] = CGRect(x: slot.minX - frame.minX, y: frame.maxY - slot.maxY,
                                 width: slot.width, height: slot.height)
        }
        model.slots = slots
        model.highlighted = nil

        panel.setFrame(frame, display: true)
        panel.order(.below, relativeTo: hud.windowNumber)
    }

    func highlight(_ edge: HUDEdge?) {
        model.highlighted = edge
    }

    func hide() {
        panel?.orderOut(nil)
        screen = nil
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.contentView = NSHostingView(rootView: DropGuidesView(model: model))
        return panel
    }
}

@MainActor
@Observable
private final class DropGuidesModel {
    var slots: [HUDEdge: CGRect] = [:]
    var highlighted: HUDEdge?
}

private struct DropGuidesView: View {
    @Bindable var model: DropGuidesModel

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(HUDEdge.allCases) { edge in
                if let rect = model.slots[edge] {
                    let active = model.highlighted == edge
                    Capsule(style: .continuous)
                        // Dark under the outline so it reads on light windows too.
                        .fill(Color.black.opacity(active ? 0.55 : 0.3))
                        .overlay(
                            Capsule(style: .continuous).strokeBorder(
                                Color.white.opacity(active ? 0.95 : 0.55),
                                style: StrokeStyle(lineWidth: 1.5, dash: active ? [] : [4, 3])
                            )
                        )
                        .frame(width: rect.width, height: rect.height)
                        .scaleEffect(active ? 1.06 : 1)
                        .position(x: rect.midX, y: rect.midY)
                        .animation(.easeOut(duration: 0.12), value: active)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
