import SwiftUI
import AppKit

/// Semantic colors, resolved by AppKit so they follow the system appearance,
/// accent, and accessibility settings. Views consume roles, never literals.
enum WorkbenchColor {
    /// Window content background.
    static let canvas = Color(nsColor: .windowBackgroundColor)
    /// Cards and grouped sections, one translucent step above the canvas.
    /// The window and control backgrounds resolve to the same color, so an
    /// opaque control color leaves cards indistinguishable from the canvas.
    static let surface = Color(nsColor: .tertiarySystemFill)
    /// Recessed wells inside a surface: capacity-bar track, slot cells.
    static let well = Color(nsColor: .secondarySystemFill)
    /// Text and symbols on a solid accent fill.
    static let onAccent = Color(nsColor: .alternateSelectedControlTextColor)
    static let ink = Color(nsColor: .labelColor)
    static let muted = Color(nsColor: .secondaryLabelColor)
    static let hairline = Color(nsColor: .separatorColor)

    static let accent = Color.accentColor
    static let success = Color(nsColor: .systemGreen)
    static let warning = Color(nsColor: .systemOrange)
    static let failure = Color(nsColor: .systemRed)
}

/// Strengths for tone-tinted fills and strokes. Every translucent tone color
/// in the UI comes from one of these.
enum WorkbenchTint: Double {
    /// Large tinted panels and callouts.
    case wash = 0.05
    /// Badges, icon chips, selected cells.
    case fill = 0.12
    /// Borders and dividers on tinted panels.
    case stroke = 0.25
}

extension Color {
    func opacity(_ tint: WorkbenchTint) -> Color {
        opacity(tint.rawValue)
    }
}

/// Type roles mapped onto the system text styles so Dynamic Type and the
/// system font stack apply. One voice: SF Pro everywhere, rounded only for
/// large numerals. Nothing renders below 11 points (macOS caption and
/// footnote are 10 points).
enum WorkbenchTypography {
    /// The one lead numeral on a page, with tabular digits.
    static let hero = Font.system(size: WorkbenchSize.heroNumeral, weight: .semibold, design: .rounded).monospacedDigit()
    /// Large numerals in stats and meters, with tabular digits.
    static let display = Font.system(.title, design: .rounded).weight(.semibold).monospacedDigit()
    /// Sheet and window headings.
    static let title = Font.title2.weight(.semibold)
    /// Section headings inside a page.
    static let section = Font.title3.weight(.semibold)
    /// Card headers.
    static let cardTitle = Font.headline
    static let emphasis = Font.body.weight(.semibold)
    static let body = Font.body
    static let secondary = Font.callout
    static let label = Font.subheadline.weight(.medium)
    /// Paths, hashes, receipts: monospaced at body size.
    static let value = Font.body.monospaced()
    /// Numbers in tables and prose: proportional text with tabular digits.
    static let tabular = Font.body.monospacedDigit()
    static let secondaryTabular = Font.callout.monospacedDigit()
    static let metadata = Font.subheadline
    static let compactValue = Font.subheadline.monospaced()
}

/// A 4-point grid; `xxxs` exists for hairline gaps inside dense clusters.
enum WorkbenchSpacing {
    static let hairline: CGFloat = 1
    static let xxxs: CGFloat = 2
    static let xxs: CGFloat = 4
    static let xs: CGFloat = 8
    static let sm: CGFloat = 12
    static let md: CGFloat = 16
    static let lg: CGFloat = 24
    static let xl: CGFloat = 32
    static let pageInset: CGFloat = 24
    static let surfaceInset: CGFloat = 16
}

/// Fixed dimensions that are not spacing: instrument parts, window and
/// layout thresholds. Views take every such number from here.
enum WorkbenchSize {
    static let heroNumeral: CGFloat = 40
    static let barHeight: CGFloat = 22
    static let barGap: CGFloat = 2
    static let markerWidth: CGFloat = 3
    static let markerOverhang: CGFloat = 4
    static let stageNode: CGFloat = 32
    static let stageTrack: CGFloat = 2
    static let tileMinimum: CGFloat = 150
    static let instrumentMinimum: CGFloat = 360
    static let nextStepMinimum: CGFloat = 240
    static let nextStepMaximum: CGFloat = 360
    static let alertTitleIdeal: CGFloat = 240
    /// Instrument plus Next Step plus the gap between them.
    static let heroRowMinimum: CGFloat = 616
    static let barLabelsMinimum: CGFloat = 460
    static let stageStateMinimum: CGFloat = 600
    static let tileCaptionsMinimum: CGFloat = 594
    static let twoColumnMinimum: CGFloat = 1040
    static let alertRowMinimum: CGFloat = 560
    static let contentMaxWidth: CGFloat = 1120
    /// Detail-column content width assumed before the first measurement.
    static let assumedContentWidth: CGFloat = 792
    static let windowDefaultWidth: CGFloat = 1050
    static let windowDefaultHeight: CGFloat = 720
    static let windowMinimumWidth: CGFloat = 740
    static let windowMinimumHeight: CGFloat = 560
    /// Accent-tinted tile behind a model type symbol in an inspector header.
    static let symbolTile: CGFloat = 44
    /// Capacity bar track in a compact region such as the Library inspector.
    static let barHeightCompact: CGFloat = 12
}

extension WorkbenchSize {
    /// Library table and inspector dimensions. Table widths are the table's own
    /// width (window minus sidebar and inspector); tier thresholds are the
    /// widths below which a column or part of a cell gives way.
    enum Library {
        static let fitGaugeHeight: CGFloat = 6
        static let fitGaugeMinimum: CGFloat = 48
        static let fitGaugeMaximum: CGFloat = 64
        static let sizeBarWidth: CGFloat = 32
        static let sizeBarHeight: CGFloat = 4
        static let rowSymbol: CGFloat = 18

        static let inspectorMinimum: CGFloat = 380
        static let inspectorIdeal: CGFloat = 440
        static let inspectorMaximum: CGFloat = 720

        static let tierHysteresis: CGFloat = 16
        static let tierModified: CGFloat = 780
        static let tierSizeBar: CGFloat = 700
        static let tierStatus: CGFloat = 640
        static let tierGauge: CGFloat = 520
        static let tierQuant: CGFloat = 440
        static let tierSize: CGFloat = 350

        static let modelMinimum: CGFloat = 112
        static let modelIdeal: CGFloat = 220
        static let fitsMinimum: CGFloat = 64
        static let fitsIdeal: CGFloat = 148
        static let fitsMaximum: CGFloat = 180
        static let quantMinimum: CGFloat = 56
        static let quantIdeal: CGFloat = 64
        static let quantMaximum: CGFloat = 72
        static let sizeMinimum: CGFloat = 72
        static let sizeIdeal: CGFloat = 104
        static let sizeMaximum: CGFloat = 120
        static let statusMinimum: CGFloat = 100
        static let statusIdeal: CGFloat = 112
        static let statusMaximum: CGFloat = 140
        static let modifiedMinimum: CGFloat = 90
        static let modifiedIdeal: CGFloat = 96
        static let modifiedMaximum: CGFloat = 120
    }
}

extension WorkbenchSize {
    /// Prepare route dimensions: quantization tiles, transform header, pipeline
    /// track, and the conversion progress ring.
    enum Prepare {
        static let tileMinimum: CGFloat = 168
        static let tileMaximum: CGFloat = 280
        static let endpointMinimum: CGFloat = 240
        static let arrow: CGFloat = 32
        static let trackColumnMinimum: CGFloat = 88
        static let ringDiameter: CGFloat = 76
        static let ringStroke: CGFloat = 8
        /// Content width from which the ring sits centered under the Convert node.
        static let ringCenteredMinimum: CGFloat = 640
        static let logMaximumHeight: CGFloat = 220
    }
}

extension WorkbenchSize {
    /// Compare route dimensions: lettered lanes, the prompt-by-lane grid and
    /// the setup tiles. Widths are content widths inside the results surface.
    enum Compare {
        static let promptColumn: CGFloat = 184
        static let promptColumnCompact: CGFloat = 140
        /// Content width below which the prompt column uses its compact width.
        static let compactBreakpoint: CGFloat = 600
        static let laneMinimum: CGFloat = 200
        static let laneIdeal: CGFloat = 240
        static let laneMaximum: CGFloat = 320
        static let columnSpacing: CGFloat = 12
        static let cellInset: CGFloat = 12
        static let chip: CGFloat = 28
        static let thumbnailMaximum: CGFloat = 280
        static let inputThumbnail: CGFloat = 96
        /// Lines of model output a result cell shows before truncating.
        static let textCellLineLimit = 8
        static let detailsPopoverWidth = WorkbenchSize.detailsPopoverWidth
        static let tileMinimum: CGFloat = 220
        static let tileMaximum: CGFloat = 360
        static let tileSpacing: CGFloat = 12
        static let historyMaximum: CGFloat = 420
        static let promptSetMaximum: CGFloat = 260
        static let promptSetRenameWidth: CGFloat = 420
        static let musicPromptEditorWidth: CGFloat = 620
        static let musicPromptEditorHeight: CGFloat = 390
        static let filterPopoverWidth: CGFloat = 340
        static let emptyMinimumHeight: CGFloat = 200
    }
}

extension WorkbenchSize {
    /// Width of a details popover that holds a full failure text.
    static let detailsPopoverWidth: CGFloat = 360

    /// Activity route dimensions. Row widths are the width inside a row
    /// (page content minus `rowChrome`), derived from the width the page is offered.
    enum Activity {
        static let rowChrome: CGFloat = 32
        /// The narrowest row that fits every wide header column and its gaps.
        static let rowThreshold: CGFloat = stateWord + trackWidth + nameMinimum + timeColumn + actionColumn + WorkbenchSpacing.sm * 4
        static let stateWord: CGFloat = 88
        static let trackWidth: CGFloat = 120
        static let nameMinimum: CGFloat = 200
        static let timeColumn: CGFloat = 96
        static let overflow: CGFloat = 28
        /// Horizontal padding of a small bordered button around its title.
        static let smallButtonChrome: CGFloat = 24
        /// The widest primary action ("Keep anyway (unverified)"), the gap and the overflow menu.
        static let actionColumn: CGFloat = ceil(
            NSAttributedString(
                string: "Keep anyway (unverified)",
                attributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize(for: .small))]
            ).size().width
        ) + smallButtonChrome + WorkbenchSpacing.xs + overflow
        static let nodeCompact: CGFloat = 16
        static let connector: CGFloat = 10
        static let detailLabel: CGFloat = 80
        static let serverNameMinimum: CGFloat = 160
        static let portColumn: CGFloat = 130
        /// Where a wide row's detail lines start: under the name.
        static let nameIndent: CGFloat = stateWord + trackWidth + WorkbenchSpacing.sm * 2
    }
}

extension WorkbenchSize {
    /// Run route dimensions. Collapse thresholds are measured against the
    /// content width inside a surface (page content minus `surfaceChrome`).
    enum Run {
        static let contentMaxWidth: CGFloat = 1100
        static let surfaceChrome: CGFloat = 40
        static let compactThreshold: CGFloat = 600
        static let rowThreshold: CGFloat = 700

        static let heroBarHeight: CGFloat = 36
        static let segmentMinimum: CGFloat = 8
        static let labelMinimum: CGFloat = 72
        static let nextOutline: CGFloat = 2
        static let swatch: CGFloat = 10
        static let legendSpacing: CGFloat = 16
        /// Runway widths animate in steps of this many bytes, not on every memory tick.
        static let animationStepBytes: Int64 = 500_000_000

        static let chip: CGFloat = 72
        static let nameMinimum: CGFloat = 160
        static let portColumn: CGFloat = 130
        static let detailLabel: CGFloat = 80
        static let runtimeWidth: CGFloat = 150
        static let portField: CGFloat = 96
        static let contextWidth: CGFloat = 150
        static let roleWidth: CGFloat = 150
        static let loadToggle: CGFloat = 170
        static let overflow: CGFloat = 28
        static let slotModelMinimum: CGFloat = 160
        static let memoryPopoverWidth: CGFloat = 480
        static let idlePickerMaximum: CGFloat = 280
        static let reservePickerMaximum: CGFloat = 270
        static let loginSheetWidth: CGFloat = 640
        static let loginSheetHeight: CGFloat = 420
    }
}

extension WorkbenchSize {
    /// Reclaim route dimensions. Thresholds are measured against the page
    /// content width (stages) or the width inside a surface (rows), both
    /// derived from the width the page is offered.
    enum Reclaim {
        static let contentMaxWidth: CGFloat = Run.contentMaxWidth
        static let surfaceChrome: CGFloat = Run.surfaceChrome
        static let historyIndent: CGFloat = 24
        static let hysteresis: CGFloat = Library.tierHysteresis

        static let stageMinimum: CGFloat = 200
        static let stageGap: CGFloat = WorkbenchSpacing.md
        static let stageThreshold: CGFloat = stageMinimum * 3 + stageGap * 2

        static let symbolColumn: CGFloat = 24
        static let suggestionNameMinimum: CGFloat = 240
        static let byteColumn: CGFloat = 88
        static let checkboxColumn: CGFloat = 28
        static let suggestionThreshold: CGFloat = 520
        static let headerThreshold: CGFloat = 680

        static let quarantineNameMinimum: CGFloat = 200
        static let dateColumn: CGFloat = 120
        static let quarantineThreshold: CGFloat = 644

        static let historyNameMinimum: CGFloat = 200
        static let historyBytesColumn: CGFloat = 112
        static let historyThreshold: CGFloat = 600
        static let detailLabel: CGFloat = 80
    }
}

enum WorkbenchRadius {
    /// Small chips and swatches.
    static let chip: CGFloat = 4
    static let control: CGFloat = 6
    static let surface: CGFloat = 10
}

/// Animation curves. Views animate through `workbenchAnimation`, which drops
/// motion when Reduce Motion is on.
enum WorkbenchMotion {
    /// State changes, badge relabels, inserted rows.
    static let standard = Animation.snappy(duration: 0.28)
    /// Progress that advances in coarse steps.
    static let progress = Animation.easeInOut(duration: 0.6)
    /// Indeterminate rotation.
    static let spin = Animation.linear(duration: 1.1).repeatForever(autoreverses: false)
    /// One beat of the live-status pulse.
    static let pulse = Animation.easeInOut(duration: 0.9)
}

private struct ReducibleAnimation<Value: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let animation: Animation
    let value: Value

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}

/// Fades a live indicator between full and stroke-strength opacity while
/// active; static when inactive or when Reduce Motion is on.
private struct LivePulse: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let isActive: Bool

    func body(content: Content) -> some View {
        if isActive && !reduceMotion {
            content.phaseAnimator([1.0, WorkbenchTint.stroke.rawValue]) { view, phase in
                view.opacity(phase)
            } animation: { _ in
                WorkbenchMotion.pulse
            }
        } else {
            content
        }
    }
}

extension View {
    func workbenchAnimation<Value: Equatable>(_ animation: Animation = WorkbenchMotion.standard, value: Value) -> some View {
        modifier(ReducibleAnimation(animation: animation, value: value))
    }

    func livePulse(_ isActive: Bool) -> some View {
        modifier(LivePulse(isActive: isActive))
    }

    /// On macOS 26 the toolbar floats over scrolled content; a hard edge keeps
    /// the window title legible above dense text instead of overlapping it.
    @ViewBuilder
    func workbenchScrollEdge() -> some View {
#if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            scrollEdgeEffectStyle(.hard, for: .top)
        } else {
            self
        }
#else
        self
#endif
    }
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
