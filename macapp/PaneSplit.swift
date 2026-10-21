import CoreGraphics

/// Where the qBittorrent pane sits beside Magnet, worked out from the window's size.
///
/// The rule: qBittorrent comes first. In a window wide enough for two usable halves it
/// is the left half, which is the side-by-side arrangement that used to take two
/// windows. In a narrower window two halves would each be too cramped to use, so it
/// moves to the top instead and the two share the height. Hidden, it waits just off the
/// edge it slides in from, so showing and hiding it is a slide rather than a jump.
enum PaneSplit {
    enum Axis: Equatable { case horizontal, vertical }

    /// Two halves of at least 620pt: qBittorrent's toolbar at its default 110% zoom
    /// needs about 600, and so does Magnet's top bar once it no longer leaves room
    /// for the window buttons.
    static let sideBySideMinWidth: CGFloat = 1240
    /// How far the divider can be dragged. Magnet's top bar needs about 600pt before its
    /// controls start to collide; qBittorrent's list is still readable at 400.
    static let minPaneWidth: CGFloat = 400
    static let minMagnetWidth: CGFloat = 600
    /// Stacked, neither part may shrink below a header plus something to look at.
    static let minPaneHeight: CGFloat = 240
    static let minMagnetHeight: CGFloat = 300
    /// Where the divider sits until it is dragged: an even split.
    static let defaultFraction: CGFloat = 0.5
    /// The divider's grab area, wider than the line it draws.
    static let handleThickness: CGFloat = 8

    struct Frames: Equatable {
        var axis: Axis
        var pane: CGRect
        var magnet: CGRect
        /// The divider's grab area, centred on the line between the two.
        var handle: CGRect
    }

    static func axis(for size: CGSize) -> Axis {
        size.width >= sideBySideMinWidth ? .horizontal : .vertical
    }

    /// `fraction` is qBittorrent's share of the width (side by side) or of the height
    /// (stacked) -- a share rather than points, so a dragged divider keeps its place
    /// proportionally as the window is resized. It is held inside both minimums.
    static func frames(for size: CGSize, shown: Bool, fraction: CGFloat = defaultFraction) -> Frames {
        let w = max(0, size.width), h = max(0, size.height)
        let t = handleThickness
        switch axis(for: size) {
        case .horizontal:
            let paneWidth = clamp(w * fraction, low: minPaneWidth, high: w - minMagnetWidth, total: w)
            return Frames(axis: .horizontal,
                          pane: CGRect(x: shown ? 0 : -paneWidth, y: 0, width: paneWidth, height: h),
                          magnet: shown
                            ? CGRect(x: paneWidth, y: 0, width: w - paneWidth, height: h)
                            : CGRect(x: 0, y: 0, width: w, height: h),
                          handle: CGRect(x: (shown ? paneWidth : 0) - t / 2, y: 0, width: t, height: h))
        case .vertical:
            let paneHeight = clamp(h * fraction, low: minPaneHeight, high: h - minMagnetHeight, total: h)
            return Frames(axis: .vertical,
                          pane: CGRect(x: 0, y: shown ? 0 : -paneHeight, width: w, height: paneHeight),
                          magnet: shown
                            ? CGRect(x: 0, y: paneHeight, width: w, height: h - paneHeight)
                            : CGRect(x: 0, y: 0, width: w, height: h),
                          handle: CGRect(x: 0, y: (shown ? paneHeight : 0) - t / 2, width: w, height: t))
        }
    }

    /// The share a drag to `position` (points along the split axis) asks for, held to
    /// what frames(for:) would actually allow, so the stored value never drifts past
    /// where the divider can go.
    static func fraction(forDragTo position: CGFloat, in size: CGSize) -> CGFloat {
        let horizontal = axis(for: size) == .horizontal
        let total = horizontal ? size.width : size.height
        guard total > 0 else { return defaultFraction }
        let length = horizontal
            ? clamp(position, low: minPaneWidth, high: total - minMagnetWidth, total: total)
            : clamp(position, low: minPaneHeight, high: total - minMagnetHeight, total: total)
        return length / total
    }

    /// Rounded to whole points and held between the two minimums. A window too small
    /// for both falls back to a plain proportion rather than letting either side go
    /// negative.
    private static func clamp(_ value: CGFloat, low: CGFloat, high: CGFloat, total: CGFloat) -> CGFloat {
        guard high >= low else { return (total * 0.45).rounded(.down) }
        return min(max(value.rounded(.down), low), high)
    }
}
