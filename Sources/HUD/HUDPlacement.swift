import AppKit
import SwiftUI

/// The three spots the bar docks to, like Wispr Flow's bar: centered at the
/// bottom, or standing up in the middle of either side.
enum HUDEdge: String, CaseIterable, Identifiable {
    case bottom, left, right

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bottom: return "Bottom"
        case .left: return "Left side"
        case .right: return "Right side"
        }
    }

    var isVertical: Bool { self != .bottom }
}

/// Where the bar lives, remembered across launches. Set by dragging the bar
/// to one of the spots, or from Settings.
enum HUDPlacement {
    private static let edgeKey = "hudEdge"

    /// Gap between the pill's canvas and the screen edge.
    private static let margin: CGFloat = 10

    /// A typical pill, for the drop guides: the real one grows with its buttons.
    private static let slotLength: CGFloat = 80
    private static let slotThickness: CGFloat = 28

    static var edge: HUDEdge {
        HUDEdge(rawValue: UserDefaults.standard.string(forKey: edgeKey) ?? "") ?? .bottom
    }

    static func save(edge: HUDEdge) {
        UserDefaults.standard.set(edge.rawValue, forKey: edgeKey)
    }

    /// The canvas the pill is drawn in, before the shadow margin.
    static func canvas(vertical: Bool) -> CGSize {
        vertical ? CGSize(width: 40, height: 320) : CGSize(width: 320, height: 40)
    }

    /// Fixed rather than measured, so a flip between horizontal and vertical
    /// can be sized before SwiftUI has laid the new orientation out.
    static func windowSize(vertical: Bool) -> NSSize {
        let canvas = canvas(vertical: vertical)
        let insets = RecordingHUDView.shadowInsets
        return NSSize(
            width: canvas.width + insets.leading + insets.trailing,
            height: canvas.height + insets.top + insets.bottom
        )
    }

    /// Screen point the pill is centered on when docked at `edge`.
    private static func dockCenter(for edge: HUDEdge, in visible: NSRect) -> NSPoint {
        let canvas = canvas(vertical: edge.isVertical)
        switch edge {
        case .bottom: return NSPoint(x: visible.midX, y: visible.minY + margin + canvas.height / 2)
        case .left: return NSPoint(x: visible.minX + margin + canvas.width / 2, y: visible.midY)
        case .right: return NSPoint(x: visible.maxX - margin - canvas.width / 2, y: visible.midY)
        }
    }

    /// The bar's window frame when docked at `edge`.
    static func frame(for edge: HUDEdge, in visible: NSRect) -> NSRect {
        let size = windowSize(vertical: edge.isVertical)
        let canvas = canvas(vertical: edge.isVertical)
        let insets = RecordingHUDView.shadowInsets
        let center = dockCenter(for: edge, in: visible)
        return NSRect(
            x: center.x - insets.leading - canvas.width / 2,
            y: center.y - insets.bottom - canvas.height / 2,
            width: size.width,
            height: size.height
        )
    }

    /// Outline of a pill docked at `edge`, in screen coordinates.
    static func slot(for edge: HUDEdge, in visible: NSRect) -> NSRect {
        let center = dockCenter(for: edge, in: visible)
        let size = edge.isVertical
            ? CGSize(width: slotThickness, height: slotLength)
            : CGSize(width: slotLength, height: slotThickness)
        return NSRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
                      width: size.width, height: size.height)
    }

    /// The spot nearest to where the bar is now.
    static func nearest(to windowFrame: NSRect, in visible: NSRect) -> HUDEdge {
        let insets = RecordingHUDView.shadowInsets
        let center = NSPoint(
            x: windowFrame.minX + (windowFrame.width + insets.leading - insets.trailing) / 2,
            y: windowFrame.minY + (windowFrame.height + insets.bottom - insets.top) / 2
        )
        func distance(_ edge: HUDEdge) -> CGFloat {
            let dock = dockCenter(for: edge, in: visible)
            return hypot(dock.x - center.x, dock.y - center.y)
        }
        return HUDEdge.allCases.min { distance($0) < distance($1) } ?? .bottom
    }
}
