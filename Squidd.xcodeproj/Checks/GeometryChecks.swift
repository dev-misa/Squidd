import Foundation
import CoreGraphics

// Compile with WidgetGeometry.swift; no UI, account, or preference mutations.
@main
enum GeometryChecks {
    static func main() {
        let screen = CGRect(x: -1920, y: 100, width: 1920, height: 1000)
        let original = CGRect(x: -1200, y: 400, width: 316, height: 192)
        for corner in CardCorner.allCases {
            let frame = WidgetGeometry.resize(original, corner: corner, delta: CGPoint(x: 10, y: 8), screen: screen)
            assert(corner.left ? frame.maxX == original.maxX : frame.minX == original.minX)
            assert(corner.top ? frame.minY == original.minY : frame.maxY == original.maxY)
            for dx in stride(from: -2500.0, through: 2500.0, by: 125) {
                for dy in stride(from: -1500.0, through: 1500.0, by: 125) {
                    let resized = WidgetGeometry.resize(original, corner: corner, delta: CGPoint(x: dx, y: dy), screen: screen)
                    assert(resized.width >= 282 && resized.height >= 170)
                    assert(screen.contains(resized))
                    assert(WidgetGeometry.launcher(for: resized).maxY <= screen.maxY)
                    assert(corner.left ? resized.maxX == original.maxX : resized.minX == original.minX)
                    assert(corner.top ? resized.minY == original.minY : resized.maxY == original.maxY)
                }
            }
        }
        let launcher = WidgetGeometry.launcher(for: original)
        assert(launcher.midX == original.midX)
        assert(launcher.minY + 14 - original.maxY == 6)
        for screen in [screen, CGRect(x: 0, y: -900, width: 1440, height: 900), CGRect(x: 0, y: 0, width: 200, height: 200)] {
            let fitted = WidgetGeometry.fit(CGRect(x: 99999, y: -99999, width: 9000, height: 9000), in: screen)
            assert(screen.contains(fitted))
            assert(fitted.maxY + WidgetGeometry.launcherAllowance <= screen.maxY)
            assert(WidgetGeometry.fit(fitted, in: screen) == fitted)
        }
        print("Geometry checks passed: four-corner anchoring, extreme deltas, negative screen coordinates, small displays, launcher spacing, and idempotent clamping.")
    }
}
