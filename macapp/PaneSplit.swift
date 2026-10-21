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
    /// Stacked, neither part may shrink below a header plus something to look at.
    static let minPaneHeight: CGFloat = 240
    static let minMagnetHeight: CGFloat = 300

    struct Frames: Equatable {
        var axis: Axis
        var pane: CGRect
        var magnet: CGRect
    }

    static func axis(for size: CGSize) -> Axis {
        size.width >= sideBySideMinWidth ? .horizontal : .vertical
    }

    static func frames(for size: CGSize, shown: Bool) -> Frames {
        let w = max(0, size.width), h = max(0, size.height)
        switch axis(for: size) {
        case .horizontal:
            let paneWidth = (w / 2).rounded(.down)
            return Frames(axis: .horizontal,
                          pane: CGRect(x: shown ? 0 : -paneWidth, y: 0, width: paneWidth, height: h),
                          magnet: shown
                            ? CGRect(x: paneWidth, y: 0, width: w - paneWidth, height: h)
                            : CGRect(x: 0, y: 0, width: w, height: h))
        case .vertical:
            let paneHeight = stackedPaneHeight(for: h)
            return Frames(axis: .vertical,
                          pane: CGRect(x: 0, y: shown ? 0 : -paneHeight, width: w, height: paneHeight),
                          magnet: shown
                            ? CGRect(x: 0, y: paneHeight, width: w, height: h - paneHeight)
                            : CGRect(x: 0, y: 0, width: w, height: h))
        }
    }

    /// Half the height, held between the two minimums. In a window too short for both
    /// minimums the split falls back to a plain proportion rather than letting either
    /// side go negative.
    static func stackedPaneHeight(for height: CGFloat) -> CGFloat {
        guard height >= minPaneHeight + minMagnetHeight else {
            return (height * 0.45).rounded(.down)
        }
        let half = (height / 2).rounded(.down)
        return min(max(half, minPaneHeight), height - minMagnetHeight)
    }
}
