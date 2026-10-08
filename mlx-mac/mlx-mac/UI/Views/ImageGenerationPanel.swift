import AppKit
import SwiftUI

/// Prompt → PNG for a converted image-generation model (Library inspector).
struct ImageGenerationPanel: View {
    @ObservedObject var coordinator: ImageGenerationCoordinator
    let modelPath: String

    @State private var prompt = ""
    @State private var size = 1024
    @State private var steps = 40
    @State private var seed = 42

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
            SectionTitle(text: "Generate")
            TextField("Describe the image", text: $prompt, axis: .vertical)
                .lineLimit(2...5)
                .textFieldStyle(.roundedBorder)
            HStack(spacing: WorkbenchSpacing.sm) {
                Picker("Size", selection: $size) {
                    ForEach(ImageRequest.sizes, id: \.self) { side in
                        Text("\(side) × \(side)").tag(side)
                    }
                }
                .frame(maxWidth: 180)
                Stepper("Steps \(steps)", value: $steps, in: 1...100)
                TextField("Seed", value: $seed, format: .number.grouping(.never))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 96)
            }
            HStack(spacing: WorkbenchSpacing.sm) {
                Button("Generate") {
                    let request = ImageRequest(prompt: prompt, size: size, steps: steps, seed: seed)
                    Task { await coordinator.generate(modelPath: modelPath, request: request) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(coordinator.isGenerating || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                progress
            }
            outcome
        }
    }

    @ViewBuilder
    private var progress: some View {
        if case let .generating(path, startedAt) = coordinator.state {
            ProgressView().controlSize(.small)
            TimelineView(.periodic(from: startedAt, by: 1)) { context in
                Text(path == modelPath
                     ? "Rendering… \(ConversionProgressReader.elapsedText(seconds: max(0, Int(context.date.timeIntervalSince(startedAt)))))"
                     : "Another model is rendering.")
                    .font(WorkbenchTypography.secondary)
                    .foregroundStyle(WorkbenchColor.muted)
                    .monospacedDigit()
            }
        }
    }

    @ViewBuilder
    private var outcome: some View {
        switch coordinator.state {
        case let .finished(path, result) where path == modelPath:
            if let image = NSImage(contentsOfFile: result.path) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 420)
                    .clipShape(RoundedRectangle(cornerRadius: WorkbenchRadius.control))
            }
            HStack(spacing: WorkbenchSpacing.sm) {
                Text(ImageGenerationPresentation.caption(result))
                    .font(WorkbenchTypography.secondary)
                    .foregroundStyle(WorkbenchColor.muted)
                Spacer(minLength: 0)
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: result.path)])
                }
                .controlSize(.small)
            }
        case let .failed(path, message) where path == modelPath:
            ErrorBanner(text: message)
        default:
            EmptyView()
        }
    }
}

enum ImageGenerationPresentation {
    static func caption(_ result: GenerationResult) -> String {
        var parts = ["\(result.width) × \(result.height)", "\(result.steps) steps", "seed \(result.seed)"]
        if let seconds = result.seconds { parts.append(String(format: "%.1f s", seconds)) }
        return parts.joined(separator: " · ")
    }
}
