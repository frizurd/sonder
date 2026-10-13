import AppKit

/// On macOS 26, an AppKit scroll view under the title bar gets the system's "hard" top edge: a solid
/// band with a line under the header. AppKit has no public switch for it yet, so the editor turns
/// that edge off and draws the same soft fade as the other columns (`softTopEdge`). The call is
/// checked first; if the method goes away, the system edge simply stays.
enum ScrollPocket {
    private static let topEdge = 1

    static func hideTop(of scrollView: NSScrollView) {
        guard #available(macOS 26.0, *) else { return }
        let key = "allowedPocketEdges"
        guard scrollView.responds(to: NSSelectorFromString("setAllowedPocketEdges:")),
              let edges = scrollView.value(forKey: key) as? Int else { return }
        scrollView.setValue(edges & ~topEdge, forKey: key)
    }
}
