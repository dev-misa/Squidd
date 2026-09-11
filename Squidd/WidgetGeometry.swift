import Foundation
import CoreGraphics

enum CardCorner: CaseIterable {
    case topLeft, topRight, bottomLeft, bottomRight
    var left: Bool { self == .topLeft || self == .bottomLeft }
    var top: Bool { self == .topLeft || self == .topRight }
}

enum WidgetGeometry {
    static let minimum = CGSize(width: 282, height: 170)
    static let launcherAllowance: CGFloat = 72

    static func fit(_ frame: CGRect, in screen: CGRect) -> CGRect {
        let width = min(max(minimum.width, frame.width), screen.width)
        let height = min(max(minimum.height, frame.height), max(1, screen.height - launcherAllowance))
        return CGRect(x: max(screen.minX, min(frame.minX, screen.maxX - width)),
                      y: max(screen.minY, min(frame.minY, screen.maxY - height - launcherAllowance)),
                      width: width, height: height)
    }

    static func resize(_ original: CGRect, corner: CardCorner, delta: CGPoint, screen: CGRect) -> CGRect {
        let bounds = screen.insetBy(dx: 0, dy: 0)
        let minWidth = min(minimum.width, bounds.width)
        let minHeight = min(minimum.height, max(1, bounds.height - launcherAllowance))
        let left = corner.left ? max(bounds.minX, min(original.minX + delta.x, original.maxX - minWidth)) : original.minX
        let right = corner.left ? original.maxX : min(bounds.maxX, max(original.maxX + delta.x, original.minX + minWidth))
        let bottom = corner.top ? original.minY : max(bounds.minY, min(original.minY + delta.y, original.maxY - minHeight))
        let top = corner.top ? min(bounds.maxY - launcherAllowance, max(original.maxY + delta.y, original.minY + minHeight)) : original.maxY
        return fit(CGRect(x: left, y: bottom, width: right - left, height: top - bottom), in: screen)
    }

    static func launcher(for card: CGRect) -> CGRect {
        CGRect(x: card.midX - 84.5, y: card.maxY - 8, width: 169, height: 80)
    }
}
