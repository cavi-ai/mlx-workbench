import CryptoKit
import Foundation

enum UseMode: String, Codable, Sendable, CaseIterable {
    case chat, tasks
    var title: String { self == .chat ? "Chat" : "Model task" }
    static func modes(for model: LibraryModel) -> [Self] {
        guard model.readiness == .ready, model.item.draft == nil, !model.item.isCompanion else { return [] }
        switch model.item.task?.type {
        case .textLLM: return [.chat]
        case .visionLanguage: return [.chat, .tasks]
        case .classification, .embedding, .meshGeneration, .musicGeneration, .speechToText,
             .textToSpeech, .imageGeneration, .videoGeneration: return [.tasks]
        default: return []
        }
    }
}

struct UseRequestDefaults: Codable, Equatable, Sendable {
    var maximumTokens = 1024
    var temperature = 0.7
    var systemPrompt = ""
    func validate() throws {
        guard (1...32768).contains(maximumTokens), temperature.isFinite, (0...2).contains(temperature),
              systemPrompt.utf8.count <= 8192 else { throw UseSessionError.settings }
    }
}

struct UseImage: Codable, Equatable, Identifiable, Sendable {
    let sha256: String
    let name: String
    let mimeType: String
    let bytes: Int
    var id: String { sha256 }
    var filename: String { sha256 + (mimeType == "image/png" ? ".png" : ".jpg") }
}

enum UseTurnState: String, Codable, Sendable {
    case sending, complete, limited, interrupted, failed, stoppedWaiting
    var title: String {
        switch self {
        case .sending: "Answering…"
        case .complete: "Answer complete"
        case .limited: "Response limit reached"
        case .interrupted: "Answer interrupted"
        case .failed: "Request failed"
        case .stoppedWaiting: "Stopped waiting"
        }
    }
    var suppliesContext: Bool { self == .complete || self == .limited }
    var canRetry: Bool { self == .interrupted || self == .failed || self == .stoppedWaiting }
}

struct UseTurn: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var createdAt = Date()
    let prompt: String
    let images: [UseImage]
    let endpoint: ServerInfo
    let settings: UseRequestDefaults
    var answer = ""
    var reasoning = ""
    var state: UseTurnState = .sending
    var notice: String?
    var retryOf: UUID?
}

struct UseSession: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var schema: Int = 1
    var title: String
    let modelPath: String
    let modelName: String
    var mode: UseMode
    var endpoint: ServerInfo?
    var settings = UseRequestDefaults()
    var draft = ""
    var draftImages: [UseImage] = []
    var turns: [UseTurn] = []
    var updatedAt = Date()
    var wasSending = false
    var imageHashes: Set<String> = []

    var allImages: [UseImage] { draftImages + turns.flatMap(\.images) }
    var summary: Self {
        var value = self
        value.imageHashes = Set(allImages.map(\.sha256))
        value.draft = ""; value.draftImages = []; value.turns = []
        return value
    }
    func validate() throws {
        guard schema == 1, modelPath.hasPrefix("/"), !title.isEmpty, title.count <= 200,
              draft.utf8.count <= 32768, turns.count <= 100, draftImages.count <= 4,
              turns.reduce(0, { $0 + $1.prompt.utf8.count + $1.answer.utf8.count + $1.reasoning.utf8.count }) <= 8_388_608,
              allImages.allSatisfy({ $0.sha256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil
                  && ["image/png", "image/jpeg"].contains($0.mimeType) && (1...8_388_608).contains($0.bytes) }),
              turns.allSatisfy({ $0.prompt.utf8.count <= 32768 && $0.images.count <= 4 }) else { throw UseSessionError.history }
        try settings.validate()
        for turn in turns { try turn.settings.validate() }
    }
    func markdown() -> String {
        var lines = ["# " + title, "", "Model: " + modelName, ""]
        for turn in turns {
            lines += ["## You", "", turn.prompt, ""]
            lines += turn.images.map { "Image: " + $0.name }
            lines += ["", "## " + modelName, "", turn.answer, "", "Status: " + turn.state.title,
                      "Server: " + turn.endpoint.modelIdentity + " · :" + String(turn.endpoint.port ?? 0), ""]
            if let notice = turn.notice { lines += [notice, ""] }
        }
        if !draft.isEmpty || !draftImages.isEmpty {
            lines += ["## Unsent draft", "", draft, ""] + draftImages.map { "Image: " + $0.name }
        }
        return lines.joined(separator: "\n")
    }
}

enum UseSessionError: LocalizedError {
    case settings, history, noEndpoint, changed, image, imageUnsupported, requestTooLarge, interrupted, busy, modelUnavailable
    var errorDescription: String? {
        switch self {
        case .busy: "Finish the current request or stop waiting before changing work sessions."
        case .modelUnavailable: "This model is unavailable. Choose a ready model in Library; recorded conversations and results remain available."
        case .settings: "Use a response limit of 1–32,768 tokens, temperature of 0–2 and system instructions of at most 8 KB."
        case .history: "This conversation exceeds the supported history limits or contains invalid saved data. Export it and start a new conversation."
        case .noEndpoint: "Select a running model server, or review a server start in Run."
        case .changed: "The selected server changed or stopped. Choose its current connection before sending. Your draft is retained."
        case .image: "Choose a PNG or JPEG image of at most 8 MB."
        case .imageUnsupported: "This server does not support image inputs. Select a vision server or start a text-only conversation."
        case .requestTooLarge: "This conversation is too large to send. Export it and start a new conversation."
        case .interrupted: "The response ended without confirmed completion. The partial answer is saved; try again only when you choose."
        }
    }
}

struct UseConnectionChoice: Identifiable {
    let server: ServerInfo
    let id: String
    init(_ server: ServerInfo) {
        self.server = server
        let fields = [server.receipt ?? "", server.path ?? "", String(server.port ?? 0), String(server.pid ?? 0),
                      server.processStartedAt ?? "", server.startedAt ?? "", server.apiKeySHA256 ?? ""]
        id = SHA256.hash(data: try! JSONEncoder().encode(fields)).map { String(format: "%02x", $0) }.joined()
    }
}
