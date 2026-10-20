import SwiftUI
import AppKit

/// The shared black-and-yellow palette. Dynamic AppKit colors also give
/// isolated light-appearance panels a legible counterpart.
enum WorkbenchColor {
    static let canvas = adaptive("Canvas", dark: 0x111111, light: 0xF8F8F5)
    static let sidebar = adaptive("Sidebar", dark: 0x0C0C0C, light: 0xEFEFEB)
    static let surface = adaptive("Surface", dark: 0x191919, light: 0xFFFFFF)
    static let well = adaptive("Well", dark: 0x272727, light: 0xE5E5DF)
    /// Yellow controls always use dark text, including in dark appearance.
    static let onAccent = Color(nsColor: rgb(0x111111))
    static let ink = Color(nsColor: .labelColor)
    static let muted = Color(nsColor: .secondaryLabelColor)
    static let hairline = adaptive("Hairline", dark: 0x343434, light: 0xD3D3CB)

    static let accent = adaptive("Accent", dark: 0xFFD43B, light: 0x785900)
    static let action = Color(nsColor: rgb(0xFFD43B))
    static let actionPressed = Color(nsColor: rgb(0xE7BA24))
    static let success = Color(nsColor: .systemGreen)
    static let warning = Color(nsColor: .systemOrange)
    static let failure = Color(nsColor: .systemRed)

    private static func rgb(_ value: UInt32) -> NSColor {
        NSColor(srgbRed: Double((value >> 16) & 255) / 255,
                green: Double((value >> 8) & 255) / 255,
                blue: Double(value & 255) / 255, alpha: 1)
    }

    private static func adaptive(_ name: String, dark: UInt32, light: UInt32) -> Color {
        Color(nsColor: NSColor(name: NSColor.Name("Workbench" + name)) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return rgb(isDark ? dark : light)
        })
    }
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
/// system font stack apply. One voice: SF Pro with tabular figures for
/// measurements. Nothing renders below 11 points (macOS caption and
/// footnote are 10 points).
enum WorkbenchTypography {
    static let pageTitle = Font.system(size: 30, weight: .semibold)
    static let inspectorTitle = Font.system(size: 22, weight: .semibold)
    static let brand = Font.system(size: 14, weight: .semibold)
    /// The one lead numeral on a page, with tabular digits.
    static let hero = Font.system(size: WorkbenchSize.heroNumeral, weight: .semibold).monospacedDigit()
    /// Large numerals in stats and meters, with tabular digits.
    static let display = Font.title.weight(.semibold).monospacedDigit()
    /// Sheet and window headings.
    static let title = Font.title2.weight(.semibold)
    /// Section headings inside a page.
    static let section = Font.title3.weight(.semibold)
    /// Card headers.
    static let cardTitle = Font.headline
    static let emphasis = Font.body.weight(.semibold)
    static let body = Font.system(size: 14)
    static let reading = Font.system(size: 16)
    static let secondary = Font.system(size: 13)
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
    enum SetupAssistant {
        static let sheetWidth: CGFloat = 560
        static let sheetHeight: CGFloat = 540
    }

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
    static let windowDefaultWidth: CGFloat = 1440
    static let windowDefaultHeight: CGFloat = 900
    static let windowMinimumWidth: CGFloat = 740
    static let windowMinimumHeight: CGFloat = 560
    /// Accent-tinted tile behind a model type symbol in an inspector header.
    static let symbolTile: CGFloat = 44
    /// Capacity bar track in a compact region such as the Library inspector.
    static let barHeightCompact: CGFloat = 12
    /// Common height for mixed controls (menus, toggles, buttons) sharing one line.
    static let controlRowHeight: CGFloat = 28
    static let brandIcon: CGFloat = 36
    static let sidebarIdeal: CGFloat = 220
    static let sidebarMinimum: CGFloat = 200
    static let sidebarMaximum: CGFloat = 280
    static let primaryControlHeight: CGFloat = 32
    static let smallControlHeight: CGFloat = 24
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

        static let inspectorMinimum: CGFloat = 320
        static let inspectorIdeal: CGFloat = 360
        static let inspectorMaximum: CGFloat = 720
        static let inspectorWindowMinimum: CGFloat = 1100
        static let inspectorSheetWidth: CGFloat = 560
        static let inspectorSheetHeight: CGFloat = 720

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
        static let statusMinimum: CGFloat = 140
        static let statusIdeal: CGFloat = 154
        static let statusMaximum: CGFloat = 180
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
        static let boardBreakpoint: CGFloat = 1000
        static let boardMatrixMaximum: CGFloat = 506
        static let boardModelColumn: CGFloat = 168
        static let boardPromptColumn: CGFloat = 92
        static let boardMetricColumn: CGFloat = 80
        static let boardRowHeight: CGFloat = 72
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
        static let promptEditorWidth: CGFloat = 620
        static let promptEditorHeight: CGFloat = 390
        static let musicPromptEditorWidth: CGFloat = promptEditorWidth
        static let musicPromptEditorHeight: CGFloat = promptEditorHeight
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

extension WorkbenchSize {
    /// Health route dimensions. Fork thresholds are measured against the page
    /// content width, header and finding thresholds against the width inside a surface.
    enum Health {
        static let contentMaxWidth: CGFloat = Run.contentMaxWidth
        static let surfaceChrome: CGFloat = Run.surfaceChrome
        static let hysteresis: CGFloat = Library.tierHysteresis

        static let linkMinimum: CGFloat = 224
        static let symbolColumn: CGFloat = 24
        static let linkSymbolGap: CGFloat = 10
        static let forkGap: CGFloat = 12
        static let connectorWidth: CGFloat = 56
        static let partGlyph: CGFloat = 14

        /// A foundation column, the connector and a capability column in one row.
        static let forkRowThreshold: CGFloat = linkMinimum * 2 + connectorWidth + forkGap * 2
        /// Two links side by side.
        static let forkStackThreshold: CGFloat = linkMinimum * 2 + forkGap

        static let headerThreshold: CGFloat = 400
        static let findingThreshold: CGFloat = 400
        static let findingSymbol: CGFloat = 20
        static let findingNameMinimum: CGFloat = 240
        static let findingSizeColumn: CGFloat = 88
    }
}

extension WorkbenchSize {
    /// Clients route dimensions. Board and header thresholds are measured against the
    /// page content width, the preview header threshold against the width inside the preview surface.
    enum Clients {
        static let contentMaxWidth: CGFloat = Run.contentMaxWidth
        static let surfaceChrome: CGFloat = Run.surfaceChrome
        static let hysteresis: CGFloat = Library.tierHysteresis

        static let endpointMinimum: CGFloat = 220
        static let endpointIdeal: CGFloat = 300
        static let endpointMaximum: CGFloat = 360
        static let gapMinimum: CGFloat = 56
        static let gapIdeal: CGFloat = 72
        static let gapMaximum: CGFloat = 96
        static let clientMinimum: CGFloat = 280

        static let rowSymbol: CGFloat = Health.symbolColumn
        static let rowSymbolGap: CGFloat = 8
        static let ghostRowMinimum: CGFloat = 190
        /// Spacing between the vertical buses of neighbouring endpoints inside the connector gap.
        static let lineFan: CGFloat = 12
        static let lineDash: [CGFloat] = [WorkbenchSpacing.xxxs, WorkbenchSpacing.xxxs]
        static let maximumLines = 3
        static let treeGutter: CGFloat = 24

        static let refreshWidth: CGFloat = 150

        /// An endpoint column, the connector gap and a client column.
        static let boardThreshold: CGFloat = endpointMinimum + gapMinimum + clientMinimum
        static let previewHeaderThreshold: CGFloat = 460
        static let actionsThreshold: CGFloat = 332
    }
}

extension WorkbenchSize {
    /// Settings route dimensions. Row and ledger thresholds are measured against the
    /// width inside a group (the offered width less page insets and group padding).
    enum Settings {
        static let contentMaxWidth: CGFloat = 720
        static let groupPadding: CGFloat = WorkbenchSpacing.md
        static let rowVerticalPadding: CGFloat = WorkbenchSpacing.sm
        static let hysteresis: CGFloat = Library.tierHysteresis

        static let labelColumn: CGFloat = 168
        static let labelGap: CGFloat = 12
        /// A label column, the gap and a control of at least 340.
        static let rowThreshold: CGFloat = 520
        static let ledgerThreshold: CGFloat = 480
        static let figuresWidth: CGFloat = 150
        static let symbolColumn: CGFloat = Health.symbolColumn
        static let removeColumn: CGFloat = 20
        static let pathMinimum: CGFloat = 200

        static let fieldNarrow: CGFloat = 120
        static let fieldMedium: CGFloat = 200
        static let bitsPickerWidth: CGFloat = 180
        static let channelPickerMaximum: CGFloat = 320
        static let updateLogMaxHeight: CGFloat = 160
    }
}

extension WorkbenchSize {
    /// Discover route dimensions. Thresholds are measured against the page content
    /// width (the offered width less page insets, capped at the Run content width).
    enum Discover {
        static let contentMaxWidth: CGFloat = Run.contentMaxWidth
        static let hysteresis: CGFloat = Library.tierHysteresis

        static let headerThreshold: CGFloat = 720
        static let headerStackThreshold: CGFloat = 420
        static let legendThreshold: CGFloat = 520

        static let symbolColumn: CGFloat = Health.symbolColumn
        static let barWidth: CGFloat = 220
        static let barHeight: CGFloat = WorkbenchSize.stageTrack * 3
        static let figuresWidth: CGFloat = 120
        /// Wide rows keep a full Hugging Face repo id on one line.
        static let nameMinimum: CGFloat = barWidth + figuresWidth
        static let actionWidth: CGFloat = 190
        static let columnGap: CGFloat = WorkbenchSpacing.sm
        /// The symbol, name, bar, figures and action columns with the gaps between them.
        static let rowThreshold: CGFloat = symbolColumn + nameMinimum + barWidth + figuresWidth + actionWidth + columnGap * 4

        static let placeholderRows = 4
    }

    /// Add from Hugging Face window dimensions.
    enum Intake {
        static let minWidth: CGFloat = 560
        static let idealWidth: CGFloat = 720
        static let minHeight: CGFloat = 480
        static let idealHeight: CGFloat = 640
    }

    /// Controlled-studies panel and sheet dimensions.
    enum Lab {
        static let scoreControlWidth: CGFloat = 80
        static let videoHeight: CGFloat = 260
        static let authorMinWidth: CGFloat = 540
        static let authorIdealWidth: CGFloat = 620
        static let reviewMinWidth: CGFloat = 700
        static let reviewIdealWidth: CGFloat = 900
        static let adoptMinWidth: CGFloat = 600
        static let adoptIdealWidth: CGFloat = 740
        static let progressFigureMinimum: CGFloat = 72
        static let storePathMaxWidth: CGFloat = 360
    }

    /// Training route dimensions.
    enum Training {
        static let baseModelMenuWidth: CGFloat = 420
        static let iterationsWidth: CGFloat = 120
        static let evidenceMaxHeight: CGFloat = 240
        static let recipeMaxHeight: CGFloat = 180
    }

    /// LM Studio route dimensions, measured against the page content width.
    enum LMStudio {
        static let contentMaxWidth: CGFloat = Run.contentMaxWidth
        static let hysteresis: CGFloat = Library.tierHysteresis

        static let headerThreshold: CGFloat = 560
        static let legendThreshold: CGFloat = Discover.legendThreshold

        static let symbolColumn: CGFloat = Health.symbolColumn
        static let fitColumn: CGFloat = Discover.barWidth
        static let figuresWidth: CGFloat = Discover.figuresWidth
        static let actionWidth: CGFloat = 96
        static let nameMinimum: CGFloat = 300
        static let columnGap: CGFloat = WorkbenchSpacing.sm
        /// The symbol, name, fit, figures and action columns with the gaps between them, inside the lane surface.
        static let rowThreshold: CGFloat = symbolColumn + nameMinimum + fitColumn + figuresWidth + actionWidth
            + columnGap * 4 + WorkbenchSpacing.surfaceInset * 2
        static let nameMediumMinimum: CGFloat = 200
        /// The medium row: symbol, name, fit, and a trailing column holding the figures over the action.
        static let mediumThreshold: CGFloat = symbolColumn + nameMediumMinimum + fitColumn + max(figuresWidth, actionWidth)
            + columnGap * 3 + WorkbenchSpacing.surfaceInset * 2

        static let placeholderRows = 3
    }
}

enum WorkbenchRadius {
    /// Small chips and swatches.
    static let chip: CGFloat = 4
    static let control: CGFloat = 8
    static let surface: CGFloat = 12
}

/// A branded primary action with an explicit text contrast contract. A
/// native prominent button otherwise puts white text on the yellow tint.
struct WorkbenchPrimaryButtonStyle: PrimitiveButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        if configuration.role == .destructive {
            Button(configuration).buttonStyle(.bordered)
        } else {
            Button(role: configuration.role, action: configuration.trigger) {
                configuration.label
                    .foregroundStyle(isEnabled ? WorkbenchColor.onAccent : WorkbenchColor.muted)
            }
            .buttonStyle(.borderedProminent)
            .tint(WorkbenchColor.action)
        }
    }
}

extension PrimitiveButtonStyle where Self == WorkbenchPrimaryButtonStyle {
    static var workbenchPrimary: Self { .init() }
}

extension View {
    /// Apply at window roots; routes and sheets inherit one coherent theme.
    func workbenchTheme() -> some View {
        self.tint(WorkbenchColor.accent)
            .background(WorkbenchColor.canvas, in: Rectangle())
            .preferredColorScheme(.dark)
    }

    func workbenchCanvas() -> some View {
        background(WorkbenchColor.canvas, in: Rectangle())
    }
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

private struct WorkbenchViewportKey: EnvironmentKey {
    static let defaultValue = CGSize(width: WorkbenchSize.windowDefaultWidth, height: WorkbenchSize.windowDefaultHeight)
}

extension EnvironmentValues {
    var workbenchViewport: CGSize {
        get { self[WorkbenchViewportKey.self] }
        set { self[WorkbenchViewportKey.self] = newValue }
    }

    var isRouteActive: Bool {
        get { self[RouteActiveKey.self] }
        set { self[RouteActiveKey.self] = newValue }
    }
}
