import SwiftUI

// MARK: - Lines

/// An identifier (path, receipt, PID): muted label, one monospaced middle-truncated line, full value selectable and in help.
struct ActivityPathLine: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: WorkbenchSpacing.xs) {
            Text(label)
                .font(WorkbenchTypography.metadata)
                .foregroundStyle(WorkbenchColor.muted)
                .frame(width: WorkbenchSize.Activity.detailLabel, alignment: .leading)
            ActivityPathValue(value: value)
            Spacer(minLength: 0)
        }
    }
}

/// A path or id value: muted, monospaced, one middle-truncated line, full value selectable and in help.
struct ActivityPathValue: View {
    let value: String

    var body: some View {
        Text(verbatim: value)
            .font(WorkbenchTypography.compactValue)
            .foregroundStyle(WorkbenchColor.muted)
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
            .help(value)
    }
}

/// A fact in words (a time, a state): muted label, plain value.
struct ActivityFactLine: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: WorkbenchSpacing.xs) {
            Text(label)
                .font(WorkbenchTypography.metadata)
                .foregroundStyle(WorkbenchColor.muted)
                .frame(width: WorkbenchSize.Activity.detailLabel, alignment: .leading)
            Text(verbatim: value)
                .font(WorkbenchTypography.secondary)
                .foregroundStyle(WorkbenchColor.ink)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Conversion row

struct ActivityRowView: View {
    let row: ActivityRowPresentation
    let isCompact: Bool
    let pulses: Bool
    @Binding var isExpanded: Bool
    let perform: (ActivityWorkflowAction) -> Void
    let viewLog: (String) -> Void
    let copySource: (String) -> Void
    let dismiss: () -> Void

    private var detailIndent: CGFloat { isCompact ? 0 : WorkbenchSize.Activity.nameIndent }

    private var stateColor: Color {
        switch row.workflow.state {
        case .failed, .verificationFailed: return WorkbenchColor.failure
        case .queued, .running, .verifying: return WorkbenchColor.accent
        default: return WorkbenchColor.ink
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
            if isCompact { compactHeader } else { wideHeader }
            VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
                paths
                if let receipt = row.receipt { ActivityPathLine(label: "Receipt", value: receipt) }
                message
                inlineLog
                disclosure
            }
            .padding(.leading, detailIndent)
            if isCompact {
                actions
            }
        }
    }

    /// Source and destination: one muted line when wide, two when compact; no labels.
    @ViewBuilder
    private var paths: some View {
        if isCompact {
            if let source = row.source { ActivityPathValue(value: source) }
            if let destination = row.destination { ActivityPathValue(value: destination) }
        } else if let source = row.source, let destination = row.destination {
            HStack(spacing: WorkbenchSpacing.xs) {
                ActivityPathValue(value: source)
                Image(systemName: "arrow.right")
                    .font(WorkbenchTypography.metadata)
                    .foregroundStyle(WorkbenchColor.muted)
                    .accessibilityHidden(true)
                ActivityPathValue(value: destination)
            }
        } else if let only = row.source ?? row.destination {
            ActivityPathValue(value: only)
        }
    }

    // MARK: Header

    private var wideHeader: some View {
        HStack(alignment: .center, spacing: WorkbenchSpacing.sm) {
            stateWord.frame(width: WorkbenchSize.Activity.stateWord, alignment: .leading)
            VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
                track
                trackCaption
            }
            .frame(width: WorkbenchSize.Activity.trackWidth, alignment: .leading)
            nameText
                .frame(minWidth: WorkbenchSize.Activity.nameMinimum, maxWidth: .infinity, alignment: .leading)
            time.frame(width: WorkbenchSize.Activity.timeColumn, alignment: .trailing)
            actions.frame(width: WorkbenchSize.Activity.actionColumn, alignment: .trailing)
        }
    }

    private var compactHeader: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
            HStack(alignment: .center, spacing: WorkbenchSpacing.sm) {
                stateWord
                track
                trackCaption
                Spacer(minLength: WorkbenchSpacing.xs)
                time
            }
            nameText
        }
    }

    private var stateWord: some View {
        Text(row.stateWord)
            .font(WorkbenchTypography.emphasis)
            .foregroundStyle(stateColor)
            .lineLimit(1)
    }

    private var track: some View {
        FlightTrackView(
            nodes: row.nodes.map { node in
                FlightTrackNode(
                    id: node.id, title: node.title, symbol: node.symbol, state: node.state, detail: node.detail,
                    pulses: node.pulses && pulses, isNotApplicable: node.isNotApplicable
                )
            },
            showsStateText: false,
            accessibilityTitle: row.trackLabel,
            compact: true
        )
        .help(row.trackLabel)
        .accessibilityHidden(row.showsTrackCaption)
    }

    /// Where a failed run stopped, as text.
    @ViewBuilder
    private var trackCaption: some View {
        if row.showsTrackCaption {
            Text(verbatim: row.trackLabel)
                .font(WorkbenchTypography.metadata)
                .foregroundStyle(WorkbenchColor.muted)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    @ViewBuilder
    private var inlineLog: some View {
        if row.showsInlineLog, let logPath = row.logPath {
            Button("View log") { viewLog(logPath) }
                .buttonStyle(.borderless)
                .controlSize(.small)
        }
    }

    @ViewBuilder
    private var nameText: some View {
        let name = Text(verbatim: row.name).foregroundStyle(WorkbenchColor.ink)
        Group {
            if let quantization = row.quantization {
                Text("\(name)\(Text(verbatim: " · " + quantization).foregroundStyle(WorkbenchColor.muted))")
            } else {
                name
            }
        }
        .font(WorkbenchTypography.emphasis)
        .lineLimit(2)
        .truncationMode(.middle)
        .fixedSize(horizontal: false, vertical: true)
        .help(row.name)
    }

    private var time: some View {
        Text(verbatim: row.relativeTime)
            .font(WorkbenchTypography.secondaryTabular)
            .foregroundStyle(WorkbenchColor.muted)
            .lineLimit(1)
            .help("Started " + row.createdText)
    }

    // MARK: Message and details

    @ViewBuilder
    private var message: some View {
        switch row.line {
        case .failure(let text)?:
            FailureNotice(error: text, details: .whenDifferent)
        case .note(let text)?:
            Text(verbatim: text)
                .font(WorkbenchTypography.secondary)
                .foregroundStyle(WorkbenchColor.muted)
                .lineLimit(2)
                .help(text)
        case nil:
            EmptyView()
        }
    }

    private var disclosure: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
                ActivityFactLine(label: "Started", value: row.createdText)
                ActivityFactLine(label: "Updated", value: row.updatedText)
                if let agentState = row.agentState { ActivityFactLine(label: "Agent state", value: agentState) }
                if let logPath = row.logPath { ActivityPathLine(label: "Log path", value: logPath) }
                ForEach(row.recordedMessages, id: \.self) { ActivityFactLine(label: "Message", value: $0) }
            }
            .padding(.top, WorkbenchSpacing.xxs)
        } label: {
            Text("Timing and log")
                .font(WorkbenchTypography.metadata)
                .foregroundStyle(WorkbenchColor.muted)
        }
    }

    // MARK: Actions

    private var hasMenuItems: Bool {
        !row.overflow.isEmpty || (row.logPath != nil && !row.showsInlineLog) || row.source != nil || !row.isActive
    }

    private var actions: some View {
        HStack(spacing: WorkbenchSpacing.xs) {
            if let primary = row.primary {
                Button(primary.title) { perform(primary) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .fixedSize()
            }
            if hasMenuItems { overflowMenu }
        }
    }

    private var overflowMenu: some View {
        Menu {
            ForEach(Array(row.overflow.enumerated()), id: \.offset) { _, action in
                Button(action.title) { perform(action) }
            }
            if let logPath = row.logPath, !row.showsInlineLog { Button("View log") { viewLog(logPath) } }
            if let source = row.source { Button("Copy source path") { copySource(source) } }
            if !row.isActive {
                Divider()
                Button("Dismiss", action: dismiss)
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: WorkbenchSize.Activity.overflow)
        .help("More actions")
        .accessibilityLabel("More actions for \(row.name)")
    }
}

// MARK: - Server row

struct ActivityServerRowView: View {
    enum Style {
        /// State, name, port, started and menu on one line.
        case wide
        /// State and name, then port and started.
        case twoLine
        /// State, name and port on one line; the rest is in the details.
        case oneLine
    }

    let row: ActivityServerRow
    let style: Style
    @Binding var isExpanded: Bool
    let viewLog: (String) -> Void

    private var stateColor: Color {
        row.isRunning ? WorkbenchColor.accent : WorkbenchColor.muted
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
                if let pid = row.pid { ActivityPathLine(label: "PID", value: pid) }
                if let receipt = row.receipt { ActivityPathLine(label: "Receipt", value: receipt) }
                if let started = row.startedAbsolute ?? row.startedText { ActivityFactLine(label: "Started", value: started) }
                if let logPath = row.logPath { ActivityPathLine(label: "Log path", value: logPath) }
            }
            .padding(.top, WorkbenchSpacing.xxs)
        } label: {
            switch style {
            case .wide: wideLabel
            case .twoLine: twoLineLabel
            case .oneLine: oneLineLabel
            }
        }
    }

    private var oneLineLabel: some View {
        HStack(alignment: .center, spacing: WorkbenchSpacing.sm) {
            stateWord.frame(width: WorkbenchSize.Activity.stateWord, alignment: .leading)
            name.frame(minWidth: WorkbenchSize.Activity.serverNameMinimum, maxWidth: .infinity, alignment: .leading)
            endpoint
            menu
        }
    }

    private var wideLabel: some View {
        HStack(alignment: .center, spacing: WorkbenchSpacing.sm) {
            stateWord.frame(width: WorkbenchSize.Activity.stateWord, alignment: .leading)
            name.frame(minWidth: WorkbenchSize.Activity.serverNameMinimum, maxWidth: .infinity, alignment: .leading)
            endpoint.frame(width: WorkbenchSize.Activity.portColumn, alignment: .leading)
            Text(verbatim: row.startedText ?? "")
                .font(WorkbenchTypography.secondaryTabular)
                .foregroundStyle(WorkbenchColor.muted)
                .lineLimit(1)
                .frame(width: WorkbenchSize.Activity.timeColumn, alignment: .trailing)
            menu
        }
    }

    private var twoLineLabel: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
            HStack(spacing: WorkbenchSpacing.sm) {
                stateWord
                name
                Spacer(minLength: WorkbenchSpacing.xs)
                menu
            }
            HStack(spacing: WorkbenchSpacing.sm) {
                endpoint
                if let started = row.startedText {
                    Text(verbatim: "Started " + started)
                        .font(WorkbenchTypography.secondary)
                        .foregroundStyle(WorkbenchColor.muted)
                        .lineLimit(1)
                }
            }
        }
    }

    private var stateWord: some View {
        Text(row.stateWord)
            .font(WorkbenchTypography.emphasis)
            .foregroundStyle(stateColor)
            .lineLimit(1)
    }

    private var name: some View {
        Text(verbatim: row.name)
            .font(WorkbenchTypography.emphasis)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(row.identity)
    }

    private var endpoint: some View {
        Text(verbatim: row.endpoint)
            .font(WorkbenchTypography.compactValue)
            .textSelection(.enabled)
            .lineLimit(1)
    }

    @ViewBuilder
    private var menu: some View {
        if let logPath = row.logPath {
            Menu {
                Button("View log") { viewLog(logPath) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: WorkbenchSize.Activity.overflow)
            .help("More actions")
            .accessibilityLabel("More actions for \(row.name)")
        }
    }
}

// MARK: - Web queue

struct ActivityWebQueueView: View {
    let snapshot: WebConvertQueue.Snapshot
    let isCompact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
            SectionTitle(text: "Web Queue")
            WorkbenchSurface {
                VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
                    if let problem = snapshot.problem {
                        Text(problem + " The web UI preserves it as a numbered .corrupt file.")
                            .font(WorkbenchTypography.secondary)
                            .foregroundStyle(WorkbenchColor.muted)
                    } else {
                        Text("Queued by the web UI. Read-only here; it drains while the web server runs.")
                            .font(WorkbenchTypography.secondary)
                            .foregroundStyle(WorkbenchColor.muted)
                    }
                    ActivityPathLine(label: "Queue file", value: snapshot.path)
                    ForEach(snapshot.items) { item in
                        Divider()
                        itemRow(item)
                    }
                }
            }
        }
    }

    private func itemRow(_ item: WebQueueItem) -> some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
            HStack(alignment: .firstTextBaseline, spacing: WorkbenchSpacing.sm) {
                Text(WorkbenchStatus(rawValue: item.state.rawValue).label)
                    .font(WorkbenchTypography.emphasis)
                    .foregroundStyle(item.state == .failed ? WorkbenchColor.failure : WorkbenchColor.ink)
                    .frame(width: isCompact ? nil : WorkbenchSize.Activity.stateWord, alignment: .leading)
                Text(verbatim: item.label)
                    .font(WorkbenchTypography.emphasis)
                    .lineLimit(isCompact ? 2 : 1)
                    .truncationMode(.middle)
                    .help(item.label)
                Spacer(minLength: WorkbenchSpacing.xs)
                if !isCompact { kindText(item) }
            }
            if isCompact { kindText(item) }
            ActivityPathLine(label: "Source", value: item.path ?? item.repo ?? "—")
            if let out = item.out { ActivityPathLine(label: "Output", value: out) }
            if let failure = item.failure {
                FailureNotice(error: failure.message, details: .whenDifferent)
                Text(failure.remediation)
                    .font(WorkbenchTypography.secondary)
                    .foregroundStyle(WorkbenchColor.muted)
                    .lineLimit(2)
                    .help(failure.remediation)
            }
        }
    }

    private func kindText(_ item: WebQueueItem) -> some View {
        Text(verbatim: (item.kind == .gguf ? "GGUF" : "HF cache") + " · q" + String(item.qBits))
            .font(WorkbenchTypography.secondary)
            .foregroundStyle(WorkbenchColor.muted)
            .lineLimit(1)
    }
}
