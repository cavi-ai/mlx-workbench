import SwiftUI
import AppKit

/// Semantic colors for the Silicon Instrument Bench visual language.
///
/// Each color is an appearance-aware token. Components should consume these
/// roles instead of hard-coding light/dark values or using decorative effects.
enum WorkbenchColor {
    static let alloyCanvas = adaptive(light: "F2F3F0", dark: "151817")
    static let instrumentSurface = adaptive(light: "FFFFFF", dark: "202422")
    static let graphiteInk = adaptive(light: "1B211F", dark: "EEF1ED")
    static let graphiteMuted = adaptive(light: "5F6965", dark: "AAB4AE")
    // Semantic colors are deliberately darker in light appearance so the
    // smallest 11-point utility labels retain WCAG AA contrast on their
    // tinted surfaces. Dark appearance uses brighter instrument colors.
    static let fluxTeal = adaptive(light: "00645E", dark: "64D8CD")
    static let verifiedGreen = adaptive(light: "176B3A", dark: "71E19A")
    static let thermalAmber = adaptive(light: "7A4600", dark: "FFC766")
    static let systemRed = adaptive(light: "A51D24", dark: "FF7770")
    static let hairline = adaptive(light: "D6DBD7", dark: "3A423E")

    private static func adaptive(light: String, dark: String) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }
}

private extension NSColor {
    convenience init(hex: String) {
        let value = UInt64(hex, radix: 16) ?? 0
        self.init(
            calibratedRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }
}

enum WorkbenchTypography {
    static let display = Font.system(size: 30, weight: .semibold, design: .rounded)
    static let section = Font.system(size: 17, weight: .semibold, design: .rounded)
    static let body = Font.system(size: 13, weight: .regular, design: .default)
    static let navigation = Font.system(size: 12, weight: .medium, design: .default)
    static let monoUtility = Font.system(size: 11, weight: .medium, design: .monospaced)
}

enum WorkbenchSpacing {
    static let hairline: CGFloat = 1
    static let xxs: CGFloat = 4
    static let xs: CGFloat = 8
    static let sm: CGFloat = 12
    static let md: CGFloat = 16
    static let lg: CGFloat = 24
    static let xl: CGFloat = 32
    static let pageInset: CGFloat = 24
    static let surfaceInset: CGFloat = 16
}

enum WorkbenchRadius {
    static let control: CGFloat = 6
    static let surface: CGFloat = 10
    static let page: CGFloat = 14
}
