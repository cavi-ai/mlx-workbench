import SwiftUI
import AppKit

/// Semantic colors, resolved by AppKit so they follow the system appearance,
/// accent, and accessibility settings. Views consume roles, never literals.
enum WorkbenchColor {
    static let canvas = Color(nsColor: .windowBackgroundColor)
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let ink = Color(nsColor: .labelColor)
    static let muted = Color(nsColor: .secondaryLabelColor)
    static let hairline = Color(nsColor: .separatorColor)

    static let accent = Color.accentColor
    static let success = Color(nsColor: .systemGreen)
    static let warning = Color(nsColor: .systemOrange)
    static let failure = Color(nsColor: .systemRed)
}

/// Type roles mapped onto the system text styles so Dynamic Type and the
/// system font stack apply. Values (paths, hashes, receipts, numbers) use the
/// monospaced body size; nothing user-facing renders below 11 points.
enum WorkbenchTypography {
    static let title = Font.title2.weight(.semibold)
    static let section = Font.title3.weight(.semibold)
    static let emphasis = Font.body.weight(.semibold)
    static let body = Font.body
    static let secondary = Font.callout
    static let label = Font.subheadline.weight(.medium)
    static let value = Font.body.monospaced()
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

/// Whether the enclosing route is the one currently shown in the detail
/// column. Visited routes stay mounted so their local state survives tab
/// switches; only the active one may contribute toolbar items or a search
/// field, otherwise every mounted route's toolbar would render at once.
private struct RouteActiveKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var isRouteActive: Bool {
        get { self[RouteActiveKey.self] }
        set { self[RouteActiveKey.self] = newValue }
    }
}
