import AppKit
import SwiftUI

extension ComparisonViewLogic {
    static func showsImageInspection(_ run: ComparisonRun) -> Bool {
        run.effectiveMode.outputKind == .image && run.state == .completed
    }

    static func imageClips(for run: ComparisonRun, store: ComparisonOutputStore, promptID: String) -> [OutputClip] {
        outputClips(for: run, store: store, promptID: promptID, kind: .image)
    }
}

struct ImageInspectionSelection: Identifiable {
    let promptID: String
    let modelPath: String?
    var id: String { promptID + "|" + (modelPath ?? "") }
}

/// Shared position in image coordinates; each canvas clamps to its own aspect ratio.
/// Zoom is relative to fit, so differently sized outputs can be inspected together.
struct ImageInspectionViewport: Equatable {
    private(set) var zoom: CGFloat = 1
    private(set) var center: CGPoint = .zero

    mutating func reset() { self = Self() }

    mutating func setZoom(_ value: CGFloat) {
        guard value.isFinite else { return }
        zoom = min(max(value, 1), 8)
        if zoom == 1 { center = .zero }
    }

    func fittedSize(image: CGSize, canvas: CGSize) -> CGSize {
        guard [image.width, image.height, canvas.width, canvas.height].allSatisfy({ $0.isFinite && $0 > 0 }) else { return .zero }
        let scale = min(canvas.width / image.width, canvas.height / image.height)
        return CGSize(width: image.width * scale, height: image.height * scale)
    }

    func offset(image: CGSize, canvas: CGSize) -> CGSize {
        let fit = fittedSize(image: image, canvas: canvas)
        guard fit != .zero else { return .zero }
        let width = fit.width * zoom, height = fit.height * zoom
        let xLimit = max(0, (width - canvas.width) / 2), yLimit = max(0, (height - canvas.height) / 2)
        return CGSize(width: min(max(center.x * width, -xLimit), xLimit),
                      height: min(max(center.y * height, -yLimit), yLimit))
    }

    mutating func pan(by translation: CGSize, image: CGSize, canvas: CGSize) {
        let fit = fittedSize(image: image, canvas: canvas)
        guard fit != .zero, translation.width.isFinite, translation.height.isFinite else { return }
        let current = offset(image: image, canvas: canvas)
        let width = fit.width * zoom, height = fit.height * zoom
        let xLimit = max(0, (width - canvas.width) / 2), yLimit = max(0, (height - canvas.height) / 2)
        center = CGPoint(x: min(max(current.width + translation.width, -xLimit), xLimit) / width,
                         y: min(max(current.height + translation.height, -yLimit), yLimit) / height)
    }
}

struct ImageComparisonSheet: View {
    let run: ComparisonRun
    let store: ComparisonOutputStore
    let name: (String) -> String
    let onReview: (String, Int?) -> Void
    let reviewError: String?
    @Environment(\.dismiss) private var dismiss
    @State private var promptID: String
    @State private var leftPath: String?
    @State private var rightPath: String?
    @State private var viewport = ImageInspectionViewport()

    init(run: ComparisonRun, store: ComparisonOutputStore, selection: ImageInspectionSelection,
         name: @escaping (String) -> String, onReview: @escaping (String, Int?) -> Void, reviewError: String? = nil) {
        self.run = run; self.store = store; self.name = name; self.onReview = onReview
        self.reviewError = reviewError
        let clips = ComparisonViewLogic.imageClips(for: run, store: store, promptID: selection.promptID)
        let left = clips.first(where: { $0.modelPath == selection.modelPath })?.modelPath ?? clips.first?.modelPath
        _promptID = State(initialValue: selection.promptID)
        _leftPath = State(initialValue: left)
        _rightPath = State(initialValue: clips.first(where: { $0.modelPath != left })?.modelPath)
    }

    private var clips: [ComparisonViewLogic.OutputClip] {
        ComparisonViewLogic.imageClips(for: run, store: store, promptID: promptID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
            HStack {
                Label("Image comparison", systemImage: "square.split.2x1").font(WorkbenchTypography.cardTitle)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if ComparisonViewLogic.rows(for: run).count > 1 {
                Picker("Prompt", selection: $promptID) {
                    ForEach(ComparisonViewLogic.rows(for: run)) { entry in
                        Text(entry.text).lineLimit(1).tag(entry.id)
                    }
                }
            } else if let entry = ComparisonViewLogic.rows(for: run).first {
                Text(entry.text).font(WorkbenchTypography.secondary).lineLimit(2).textSelection(.enabled)
            }
            HStack(spacing: WorkbenchSpacing.md) {
                lane("A", path: $leftPath, excluding: rightPath)
                lane("B", path: $rightPath, excluding: leftPath)
            }
            if let reviewError { ErrorBanner(text: reviewError) }
            HStack(spacing: WorkbenchSpacing.sm) {
                Label("Linked zoom", systemImage: "link").font(WorkbenchTypography.secondary)
                Button { viewport.setZoom(viewport.zoom - 0.5) } label: { Image(systemName: "minus.magnifyingglass") }
                    .disabled(viewport.zoom == 1).accessibilityLabel("Zoom out")
                Slider(value: Binding(get: { viewport.zoom }, set: { viewport.setZoom($0) }), in: 1...8)
                    .frame(maxWidth: 240).accessibilityLabel("Linked image zoom")
                Button { viewport.setZoom(viewport.zoom + 0.5) } label: { Image(systemName: "plus.magnifyingglass") }
                    .disabled(viewport.zoom == 8).accessibilityLabel("Zoom in")
                Text(String(format: "%.0f%%", viewport.zoom * 100))
                    .font(WorkbenchTypography.secondaryTabular).frame(width: 48, alignment: .trailing)
                Button("Reset") { viewport.reset() }
                Spacer()
                Text("Drag or use arrow keys to pan")
                    .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
            }
            .controlSize(.small)
        }
        .padding(WorkbenchSpacing.pageInset)
        .frame(minWidth: 760, idealWidth: 1000, minHeight: 620, idealHeight: 720)
        .background(WorkbenchColor.canvas)
        .onChange(of: promptID) { _, _ in
            viewport.reset()
            if !clips.contains(where: { $0.modelPath == leftPath }) { leftPath = clips.first?.modelPath }
            if !clips.contains(where: { $0.modelPath == rightPath }) || leftPath == rightPath {
                rightPath = clips.first(where: { $0.modelPath != leftPath })?.modelPath
            }
        }
    }

    private func lane(_ title: String, path: Binding<String?>, excluding: String?) -> some View {
        let clip = clips.first(where: { $0.modelPath == path.wrappedValue })
        return VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
            HStack(spacing: WorkbenchSpacing.sm) {
                Text(title).font(WorkbenchTypography.emphasis).foregroundStyle(WorkbenchColor.accent)
                Picker("Model \(title)", selection: path) {
                    Text("Choose model…").tag(String?.none)
                    ForEach(clips.filter { $0.modelPath != excluding }) { candidate in
                        Text(name(candidate.modelPath)).tag(String?.some(candidate.modelPath))
                    }
                }.labelsHidden().frame(maxWidth: .infinity)
            }
            if let clip {
                TaskQualityRating(run: run, modelPath: clip.modelPath, modelName: name(clip.modelPath), store: store, onReview: onReview)
                LinkedInspectionImage(url: clip.url, label: "Image \(title) from \(name(clip.modelPath))", viewport: $viewport)
                    .id(clip.url)
            } else {
                Text("No available output for this prompt.")
                    .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(WorkbenchColor.surface)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Both panes read the same viewport; a drag in either writes normalized image coordinates.
private struct LinkedInspectionImage: View {
    let url: URL
    let label: String
    @Binding var viewport: ImageInspectionViewport
    @State private var image: NSImage?
    @State private var loaded = false
    @State private var dragOrigin: ImageInspectionViewport?

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                WorkbenchColor.surface
                if let image {
                    let fit = viewport.fittedSize(image: image.size, canvas: geometry.size)
                    let offset = viewport.offset(image: image.size, canvas: geometry.size)
                    Image(nsImage: image).resizable()
                        .frame(width: fit.width * viewport.zoom, height: fit.height * viewport.zoom)
                        .offset(offset)
                } else if loaded {
                    Text("Image unavailable").font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
                } else { ProgressView() }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
            .contentShape(Rectangle())
            .gesture(DragGesture().onChanged { value in
                guard let image else { return }
                if dragOrigin == nil { dragOrigin = viewport }
                var next = dragOrigin ?? viewport
                next.pan(by: value.translation, image: image.size, canvas: geometry.size)
                viewport = next
            }.onEnded { _ in dragOrigin = nil })
            .focusable()
            .onMoveCommand { direction in
                guard let image else { return }
                let step: CGFloat = 40
                let translation: CGSize
                switch direction {
                case .left: translation = CGSize(width: step, height: 0)
                case .right: translation = CGSize(width: -step, height: 0)
                case .up: translation = CGSize(width: 0, height: step)
                case .down: translation = CGSize(width: 0, height: -step)
                @unknown default: return
                }
                viewport.pan(by: translation, image: image.size, canvas: geometry.size)
            }
            .accessibilityLabel(label)
            .accessibilityValue(String(format: "%.0f percent zoom", viewport.zoom * 100))
        }
        .clipShape(RoundedRectangle(cornerRadius: WorkbenchRadius.control, style: .continuous))
        .task(id: url) {
            image = nil; loaded = false
            let decoded = await MediaImageLoader.load(url)
            guard !Task.isCancelled else { return }
            image = decoded; loaded = true
        }
    }
}
