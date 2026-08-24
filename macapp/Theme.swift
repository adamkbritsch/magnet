import AppKit
import SwiftUI

// Chrome constants. The window uses .fullSizeContentView with a hidden title, so the
// top bar is drawn by us and has to leave room for the traffic lights itself.
enum Theme {
    static let barHeight: CGFloat = 44
    static let trafficLightGutter: CGFloat = 78
    static let hairline = Color.primary.opacity(0.09)
    static let pillFill = Color.primary.opacity(0.06)
    static let pillFillHover = Color.primary.opacity(0.11)

    static let minWindow = NSSize(width: 900, height: 560)
    static let defaultWindow = NSSize(width: 1440, height: 920)
}

/// Status colors for the route pill. Kept semantic rather than literal so both
/// appearances read correctly.
enum StatusTint {
    case live, needsAuth, probing, offline

    var color: Color {
        switch self {
        case .live: return Color(nsColor: .systemGreen)
        case .needsAuth: return Color(nsColor: .systemOrange)
        case .probing: return Color(nsColor: .systemBlue)
        case .offline: return Color(nsColor: .systemRed)
        }
    }
}

/// Native blurred material, so the bar looks right in light and dark without
/// hardcoding either.
struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .headerView
    var blending: NSVisualEffectView.BlendingMode = .withinWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blending
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blending
    }
}

/// Makes an area behave like titlebar for dragging. Used as a background layer so
/// the controls painted on top still receive their clicks.
private final class DragBackingView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }

    override func mouseDragged(with event: NSEvent) {
        window?.performDrag(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        // Double-click in the titlebar region should zoom, matching system behavior.
        if event.clickCount == 2 {
            window?.zoom(nil)
        } else {
            super.mouseDown(with: event)
        }
    }
}

struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragBackingView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Toolbar-style icon button: no bezel, subtle hover fill, consistent hit target.
struct ChromeButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Color.primary.opacity(0.72))
                .frame(width: 26, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(hovering ? Theme.pillFill : Color.clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

// Menu commands are posted as notifications so the AppKit menu bar and the SwiftUI
// tree stay decoupled — neither has to hold a reference to the other.
extension Notification.Name {
    static let qbHome = Notification.Name("qb.home")
    static let qbBack = Notification.Name("qb.back")
    static let qbReload = Notification.Name("qb.reload")
    static let qbZoomIn = Notification.Name("qb.zoomIn")
    static let qbZoomOut = Notification.Name("qb.zoomOut")
    static let qbZoomReset = Notification.Name("qb.zoomReset")
    static let qbSettings = Notification.Name("qb.settings")
    static let qbRecheck = Notification.Name("qb.recheck")
}
