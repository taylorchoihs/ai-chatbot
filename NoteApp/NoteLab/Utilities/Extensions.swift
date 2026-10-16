import SwiftUI
import UIKit

extension UIColor {
    /// "#RRGGBB" 또는 "#RRGGBBAA"
    convenience init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if s.hasPrefix("#") { s.removeFirst() }
        var value: UInt64 = 0
        Scanner(string: s).scanHexInt64(&value)
        let r, g, b, a: CGFloat
        if s.count == 8 {
            r = CGFloat((value >> 24) & 0xFF) / 255
            g = CGFloat((value >> 16) & 0xFF) / 255
            b = CGFloat((value >> 8) & 0xFF) / 255
            a = CGFloat(value & 0xFF) / 255
        } else {
            r = CGFloat((value >> 16) & 0xFF) / 255
            g = CGFloat((value >> 8) & 0xFF) / 255
            b = CGFloat(value & 0xFF) / 255
            a = 1
        }
        self.init(red: r, green: g, blue: b, alpha: a)
    }

    var hexString: String {
        let c = resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getRed(&r, green: &g, blue: &b, alpha: &a)
        func clamp(_ v: CGFloat) -> Int { Int(round(max(0, min(1, v)) * 255)) }
        return String(format: "#%02X%02X%02X%02X", clamp(r), clamp(g), clamp(b), clamp(a))
    }
}

extension Color {
    init(hex: String) { self.init(uiColor: UIColor(hex: hex)) }
    var hexString: String { UIColor(self).hexString }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

extension CGRect {
    init(corner a: CGPoint, _ b: CGPoint) {
        self.init(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}

enum Format {
    static func duration(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) }
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    static func studyTime(_ t: TimeInterval) -> String {
        let m = Int(t) / 60
        if m < 60 { return "\(m)분" }
        return "\(m / 60)시간 \(m % 60)분"
    }

    static let shortDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = "M월 d일"
        return f
    }()

    static let dateTime: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = "yyyy. M. d. a h:mm"
        return f
    }()
}

/// 디스크 이미지를 메모리에 캐시 (페이지 이미지, 오답노트 이미지 등)
final class ImageCache {
    static let shared = ImageCache()
    private let cache = NSCache<NSURL, UIImage>()
    init() { cache.totalCostLimit = 120 * 1024 * 1024 }

    func image(at url: URL) -> UIImage? {
        if let img = cache.object(forKey: url as NSURL) { return img }
        guard let img = UIImage(contentsOfFile: url.path) else { return nil }
        let cost = Int(img.size.width * img.size.height * img.scale * img.scale * 4)
        cache.setObject(img, forKey: url as NSURL, cost: cost)
        return img
    }

    func remove(_ url: URL) { cache.removeObject(forKey: url as NSURL) }
}
