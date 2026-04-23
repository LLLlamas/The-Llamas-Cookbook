import SwiftUI

enum AppColor {
    // MARK: Surfaces — warm cream system, layered light → less light
    static let background = Color(red: 0.980, green: 0.965, blue: 0.937)       // #FAF6EF — page
    static let surface = Color(red: 1.000, green: 0.992, blue: 0.972)          // #FFFDF8 — cards
    static let surfaceRaised = Color(red: 1.000, green: 0.996, blue: 0.984)    // #FFFEFB — hero/raised
    static let surfaceSunken = Color(red: 0.957, green: 0.937, blue: 0.898)    // #F4EFE5 — wells / inset

    // MARK: Text
    static let textPrimary = Color(red: 0.169, green: 0.137, blue: 0.125)      // #2B2320
    static let textSecondary = Color(red: 0.478, green: 0.435, blue: 0.400)    // #7A6F66
    static let textTertiary = Color(red: 0.620, green: 0.580, blue: 0.541)     // #9E948A — captions, metadata

    // MARK: Accents — terracotta family
    static let accent = Color(red: 0.788, green: 0.486, blue: 0.365)           // #C97C5D — primary
    static let accentDeep = Color(red: 0.624, green: 0.353, blue: 0.247)       // #9F5A3F — headings, hover/pressed
    static let accentSoft = Color(red: 0.969, green: 0.890, blue: 0.847)       // #F7E3D8 — tinted backgrounds, subtle highlights

    // MARK: Status
    static let success = Color(red: 0.541, green: 0.651, blue: 0.541)          // #8AA68A
    static let destructive = Color(red: 0.710, green: 0.290, blue: 0.235)      // #B54A3C

    // MARK: Lines
    static let divider = Color(red: 0.910, green: 0.882, blue: 0.839)          // #E8E1D6
    static let dividerStrong = Color(red: 0.847, green: 0.808, blue: 0.749)    // #D8CEBF — emphasized rules

    // MARK: Cook mode
    static let cookModeBackground = Color(red: 0.953, green: 0.918, blue: 0.859) // #F3EADB

    // MARK: Shadows — low-saturation warm browns, not pure black
    static var shadow: Color { Color(red: 0.40, green: 0.30, blue: 0.20).opacity(0.10) }
    static var shadowSoft: Color { Color(red: 0.40, green: 0.30, blue: 0.20).opacity(0.05) }
}
