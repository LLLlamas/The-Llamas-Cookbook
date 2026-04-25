import SwiftUI
import UIKit

/// Hex string ↔ `Color` conversion. Used by `AppearanceSettings` to persist
/// the user's chosen accent into UserDefaults — `Color` itself isn't
/// `Codable`, so we round-trip through a 6-char "#RRGGBB" string.
extension Color {
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.replacingOccurrences(of: "#", with: "")
        guard s.count == 6, let int = UInt64(s, radix: 16) else { return nil }
        let r = Double((int >> 16) & 0xff) / 255
        let g = Double((int >> 8)  & 0xff) / 255
        let b = Double( int        & 0xff) / 255
        self = Color(red: r, green: g, blue: b)
    }

    /// Round-trip safe: returns "#RRGGBB" for sRGB colors. Nil if the color
    /// can't be coerced into RGB (display-P3 wide-gamut edge cases, etc.).
    var toHex: String? {
        let ui = UIColor(self)
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        guard ui.getRed(&r, green: &g, blue: &b, alpha: &a) else { return nil }
        return String(
            format: "#%02X%02X%02X",
            Int((r * 255).rounded()),
            Int((g * 255).rounded()),
            Int((b * 255).rounded())
        )
    }
}
