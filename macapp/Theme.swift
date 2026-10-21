import AppKit
import SwiftUI

// Chrome constants. The window uses .fullSizeContentView with a hidden title, so the
// top bar is drawn by us and has to leave room for the traffic lights itself.
enum Theme {
    static let barHeight: CGFloat = 44
    static let trafficLightGutter: CGFloat = 78

    /// Distance from the window's top edge to the CENTRE of the traffic lights, measured
    /// from the real buttons at launch (main.swift) rather than assumed. The content view
    /// starts at the true window top, so a bar in the titlebar row centres its controls
    /// on this line. The seed is a sane fallback for the frame before it is measured.
    static var trafficLightCenterY: CGFloat = 20
    /// The band of a top bar that lines up with the window buttons.
    static var titlebarBandHeight: CGFloat { max(26, trafficLightCenterY * 2) }
    /// 640 tall: stacked, qBittorrent keeps 240 and the lower side the 380 that Files'
    /// browser over its queue needs (PaneSplit).
    static let minWindow = NSSize(width: 900, height: 640)
    static let defaultWindow = NSSize(width: 1440, height: 920)

    // MARK: - qBittorrent's palette
    //
    // The whole window takes qBittorrent's look, so the app reads as one thing with
    // the qBittorrent pane beside it. These are the WebUI's own colour variables,
    // copied from src/webui/www/private/css/style.css at release-5.2.3 (the version
    // the seedbox runs), light and dark, and applied the way it applies them:
    //   chrome   -- menu bar, toolbars and side panels: --color-background-default
    //   surface  -- lists and content: --color-background-primary
    //   accent   -- selected rows and the selected tab, white text on it
    //   hover    -- its orange, white text on it: every row and menu item it points at
    //   border   -- 1px lines between everything
    // Dynamic, so each resolves per appearance exactly as the WebUI's .dark class does.

    static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: dynamicNS(light: light, dark: dark))
    }

    static func dynamicNS(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }

    /// CSS hsl(): hue in degrees, saturation and lightness in percent.
    static func hsl(_ h: Double, _ s: Double, _ l: Double) -> NSColor {
        let s = s / 100, l = l / 100
        let c = (1 - abs(2 * l - 1)) * s
        let hp = h.truncatingRemainder(dividingBy: 360) / 60
        let x = c * (1 - abs(hp.truncatingRemainder(dividingBy: 2) - 1))
        let (r, g, b): (Double, Double, Double)
        switch hp {
        case ..<1: (r, g, b) = (c, x, 0)
        case ..<2: (r, g, b) = (x, c, 0)
        case ..<3: (r, g, b) = (0, c, x)
        case ..<4: (r, g, b) = (0, x, c)
        case ..<5: (r, g, b) = (x, 0, c)
        default: (r, g, b) = (c, 0, x)
        }
        let m = l - c / 2
        return NSColor(srgbRed: r + m, green: g + m, blue: b + m, alpha: 1)
    }

    static let chromeNS = dynamicNS(light: hsl(0, 0, 94), dark: hsl(0, 0, 25))
    static let surfaceNS = dynamicNS(light: hsl(0, 0, 100), dark: hsl(0, 0, 7))

    static let chrome = Color(nsColor: chromeNS)
    static let surface = Color(nsColor: surfaceNS)
    static let popup = dynamic(light: hsl(0, 0, 100), dark: hsl(0, 0, 20))
    static let text = dynamic(light: hsl(0, 0, 33), dark: hsl(0, 0, 90))
    static let textDisabled = Color(nsColor: hsl(0, 0, 60))
    static let accent = dynamic(light: hsl(210, 65, 55), dark: hsl(210, 42, 48))
    static let hover = dynamic(light: hsl(26, 80, 60), dark: hsl(26, 50, 55))
    static let border = dynamic(light: hsl(0, 0, 85), dark: hsl(0, 0, 33))
    /// Text and status colours. Green is the WebUI's in light; in dark, where its
    /// green does not change and reads poorly on near-black, its tracker "working"
    /// green, which it uses for the same meaning.
    static let blue = dynamic(light: hsl(210, 100, 55), dark: hsl(210, 88.1, 73.5))
    static let orange = dynamic(light: hsl(26, 100, 45), dark: hsl(26, 65, 70))
    static let red = dynamic(light: hsl(0, 100, 65), dark: hsl(0, 100, 71))
    static let green = dynamic(light: hsl(110, 94, 27), dark: hsl(142, 69, 58))

    static var hairline: Color { border }
    /// A resting control on chrome: barely there, so the bar stays flat.
    static let pillFill = Color.primary.opacity(0.06)
}

/// qBittorrent's rule for anything you can point at or pick: orange under the
/// pointer, blue once chosen, white text on either. Hover wins over selected, as in
/// the WebUI's tables, where a selected row still turns orange under the pointer.
struct QBFill {
    static func background(hovering: Bool, selected: Bool, enabled: Bool = true,
                           resting: Color = .clear) -> Color {
        if enabled && hovering { return Theme.hover }
        if selected { return Theme.accent }
        return resting
    }

    static func foreground(hovering: Bool, selected: Bool, enabled: Bool = true,
                           resting: Color = Color.primary.opacity(0.78)) -> Color {
        if (enabled && hovering) || selected { return .white }
        return enabled ? resting : Theme.textDisabled
    }
}

/// Status colors for the route pill. Kept semantic rather than literal so both
/// appearances read correctly.
enum StatusTint {
    case live, needsAuth, probing, offline

    var color: Color {
        switch self {
        case .live: return Theme.green
        case .needsAuth: return Theme.orange
        case .probing: return Theme.blue
        case .offline: return Theme.red
        }
    }
}

/// A qBittorrent tab or chip. The label should not set its own foreground or
/// background: the style paints both, by QBFill's rule.
struct QBTabButtonStyle: ButtonStyle {
    var selected: Bool
    /// The fill at rest. Chips on a bar keep a faint one so they read as buttons;
    /// tabs in a strip have none, like the WebUI's.
    var resting: Color = .clear
    var cornerRadius: CGFloat = 6

    func makeBody(configuration: Configuration) -> some View {
        QBTabBody(configuration: configuration, selected: selected, resting: resting,
                  cornerRadius: cornerRadius)
    }
}

private struct QBTabBody: View {
    let configuration: ButtonStyleConfiguration
    let selected: Bool
    let resting: Color
    let cornerRadius: CGFloat
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        configuration.label
            .foregroundStyle(QBFill.foreground(hovering: hovering, selected: selected, enabled: enabled))
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(QBFill.background(hovering: hovering, selected: selected,
                                            enabled: enabled, resting: resting))
            )
            .opacity(configuration.isPressed ? 0.85 : 1)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

/// qBittorrent's tab strip (Transfers / Search / RSS): one bordered group, the
/// chosen tab filled blue. Replaces a native segmented control, whose selection is
/// drawn in the system's grey and could not take the WebUI's look.
struct QBTabs<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, title: String)]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                Button { selection = option.value } label: {
                    Text(option.title)
                        .font(.system(size: 12, weight: selection == option.value ? .semibold : .medium))
                        .frame(maxWidth: .infinity)
                        .frame(height: 20)
                }
                .buttonStyle(QBTabButtonStyle(selected: selection == option.value, cornerRadius: 4))
                .accessibilityAddTraits(selection == option.value ? .isSelected : [])
            }
        }
        .padding(1)
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Theme.border))
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
    /// Drawn pressed, for a button that shows or hides something.
    var isOn: Bool = false
    /// Shuttle's buttons grey out rather than disappear when there is nothing to act on.
    var enabled: Bool = true
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(QBFill.foreground(hovering: hovering, selected: isOn, enabled: enabled,
                                                   resting: Color.primary.opacity(0.72)))
                .frame(width: 26, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(QBFill.background(hovering: hovering, selected: isOn, enabled: enabled))
                )
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
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
    static let qbModeManual = Notification.Name("qb.mode.manual")
    static let qbModeAutomatic = Notification.Name("qb.mode.automatic")
    static let qbTogglePane = Notification.Name("qb.pane.toggle")
    static let qbCredentialsChanged = Notification.Name("qb.credentials.changed")
}
