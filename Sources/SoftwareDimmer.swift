import Foundation
import CoreGraphics

@MainActor
final class SoftwareDimmer {
    private struct Tables {
        var red: [CGGammaValue]
        var green: [CGGammaValue]
        var blue: [CGGammaValue]
    }
    private var originals: [CGDirectDisplayID: Tables] = [:]

    func set(_ percent: Double, display: CGDirectDisplayID) throws {
        guard CGDisplayIsBuiltin(display) == 0, CGDisplayIsOnline(display) != 0 else {
            throw HelperError.message("外接显示器已断开，请重新检测。")
        }
        if originals[display] == nil {
            let capacity = Int(CGDisplayGammaTableCapacity(display))
            guard capacity > 0, capacity <= 65536 else {
                throw HelperError.message("当前显示模式不支持软件调光，请检查 HDR 设置。")
            }
            var red = [CGGammaValue](repeating: 0, count: capacity)
            var green = red
            var blue = red
            var count: UInt32 = 0
            let result = CGGetDisplayTransferByTable(display, UInt32(capacity), &red, &green, &blue, &count)
            guard result == .success, count > 0, count <= capacity else {
                throw HelperError.message("无法读取画面亮度曲线（\(result.rawValue)）。")
            }
            originals[display] = Tables(red: Array(red.prefix(Int(count))), green: Array(green.prefix(Int(count))), blue: Array(blue.prefix(Int(count))))
        }
        guard let original = originals[display] else { return }
        let factor = CGGammaValue(min(100, max(5, percent)) / 100)
        let red = original.red.map { $0 * factor }
        let green = original.green.map { $0 * factor }
        let blue = original.blue.map { $0 * factor }
        let result = CGSetDisplayTransferByTable(display, UInt32(red.count), red, green, blue)
        guard result == .success else {
            throw HelperError.message("软件调光失败（\(result.rawValue)）。")
        }
    }

    func restoreAll() {
        for (display, table) in originals where CGDisplayIsOnline(display) != 0 {
            _ = CGSetDisplayTransferByTable(display, UInt32(table.red.count), table.red, table.green, table.blue)
        }
        originals.removeAll()
    }

    func removeDisconnected(keeping displays: Set<CGDirectDisplayID>) {
        for display in Array(originals.keys) where !displays.contains(display) {
            if CGDisplayIsOnline(display) != 0, let table = originals[display] {
                _ = CGSetDisplayTransferByTable(display, UInt32(table.red.count), table.red, table.green, table.blue)
            }
            originals.removeValue(forKey: display)
        }
    }
}
