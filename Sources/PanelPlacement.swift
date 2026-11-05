import Foundation
import CoreGraphics

enum PanelPlacement {
    static func safeArea(in visibleFrame: CGRect) -> CGRect {
        visibleFrame.insetBy(dx: min(12, visibleFrame.width / 4), dy: min(12, visibleFrame.height / 4))
    }

    static func menuPanel(size: CGSize, visibleFrame: CGRect, anchor: CGRect) -> CGRect {
        let safe = safeArea(in: visibleFrame)
        let fitted = CGSize(width: min(size.width, safe.width), height: min(size.height, safe.height))
        let top = min(safe.maxY, anchor.minY - 10)
        let x = min(max(anchor.midX - fitted.width / 2, safe.minX), safe.maxX - fitted.width)
        let y = min(max(top - fitted.height, safe.minY), safe.maxY - fitted.height)
        return CGRect(origin: CGPoint(x: x, y: y), size: fitted)
    }

    static func feedback(size: CGSize, visibleFrame: CGRect) -> CGRect {
        let safe = safeArea(in: visibleFrame)
        let fitted = CGSize(width: min(size.width, safe.width), height: min(size.height, safe.height))
        let y = min(safe.minY + 88, safe.maxY - fitted.height)
        return CGRect(x: safe.midX - fitted.width / 2, y: max(safe.minY, y), width: fitted.width, height: fitted.height)
    }
}
