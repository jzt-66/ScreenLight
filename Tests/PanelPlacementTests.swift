import Foundation
import CoreGraphics

@main
struct PlacementTests {
    static func main() {
        // AppKit coordinates, including monitors above/left/below the main screen.
        let screens = [
            CGRect(x: 0, y: 38, width: 1440, height: 838),
            CGRect(x: -2560, y: 0, width: 2560, height: 1415),
            CGRect(x: 0, y: 938, width: 1920, height: 1055),
            CGRect(x: 1440, y: -1080, width: 1920, height: 1055),
            CGRect(x: -800, y: -600, width: 800, height: 575),
            CGRect(x: 120, y: 40, width: 300, height: 240)
        ]
        var checks = 0
        for visible in screens {
            let safe = PanelPlacement.safeArea(in: visible)
            for x in [visible.minX, visible.midX, visible.maxX - 10] {
                let anchor = CGRect(x: x, y: visible.maxY, width: 24, height: 24)
                for height in [420.0, 640.0, 1200.0] {
                    let frame = PanelPlacement.menuPanel(size: CGSize(width: 350, height: height), visibleFrame: visible, anchor: anchor)
                    assert(safe.contains(frame), "Panel outside visible screen: \(frame) / \(safe)")
                    assert(frame.maxY <= anchor.minY - 10 + 0.001)
                    checks += 1
                }
            }
            let feedback = PanelPlacement.feedback(size: CGSize(width: 230, height: 108), visibleFrame: visible)
            assert(safe.contains(feedback))
            checks += 1
            // A stale status-item anchor from the other screen still must not
            // place the panel outside the selected visible bounds.
            let stale = PanelPlacement.menuPanel(size: CGSize(width: 350, height: 420), visibleFrame: visible, anchor: CGRect(x: 9999, y: -9999, width: 24, height: 24))
            assert(safe.contains(stale))
            checks += 1
        }
        print("\(checks) panel placement cases passed (multi-display origins, edges, small screens, resizing, feedback).")
    }
}
