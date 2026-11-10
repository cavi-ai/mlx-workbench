import Foundation

enum AudioGenerationPurpose: String, CaseIterable, Identifiable, Sendable {
    case music, soundEffects, ambience
    var id: String { rawValue }
    var label: String {
        switch self {
        case .music: return "Music"
        case .soundEffects: return "Sound effects"
        case .ambience: return "Ambience"
        }
    }
    private var prefix: String {
        switch self {
        case .music: return ""
        case .soundEffects: return "Sound effects only. No music, instruments, melody, rhythm, vocals or speech. "
        case .ambience: return "Environmental ambience only. No music, instruments, melody, rhythm, vocals or speech. "
        }
    }
    func caption(_ description: String) -> String { prefix + description }
    static func restore(_ caption: String) -> (Self, String) {
        for purpose in [Self.soundEffects, .ambience] where caption.hasPrefix(purpose.prefix) {
            return (purpose, String(caption.dropFirst(purpose.prefix.count)))
        }
        return (.music, caption)
    }
}

struct LocalAudioEndpoint: Codable, Equatable, Sendable {
    let model: String
    let port: Int
    let kind: String
    let receiptsDirectory: String
    var runtime = "tasks"
    var baseURL: String

    enum CodingKeys: String, CodingKey {
        case model, port, kind, runtime
        case baseURL = "base_url"
        case receiptsDirectory = "receipts_dir"
    }

    init(model: String, port: Int, kind: String, receiptsDirectory: String) {
        self.model = model
        self.port = port
        self.kind = kind
        self.receiptsDirectory = receiptsDirectory
        baseURL = "http://127.0.0.1:\(port)"
    }

    func validate() throws {
        guard (1...65535).contains(port), baseURL == "http://127.0.0.1:\(port)", runtime == "tasks",
              ["music_generation", "sound_effects"].contains(kind) else { throw LocalAudioRoutingError.invalidEndpoint }
        for path in [model, receiptsDirectory] {
            var directory: ObjCBool = false
            let url = URL(fileURLWithPath: path)
            guard path.hasPrefix("/"), url.resolvingSymlinksInPath().path == path,
                  FileManager.default.fileExists(atPath: path, isDirectory: &directory), directory.boolValue else {
                throw LocalAudioRoutingError.invalidEndpoint
            }
        }
    }
}

struct LocalAudioRouting: Codable, Equatable, Sendable {
    enum Source: String, Codable, CaseIterable, Sendable {
        case music, specific
        var label: String { self == .music ? "Use music model (experimental)" : "Specific served audio model" }
    }
    var id = "artist-brain"
    var source: Source = .music
    var endpoint: LocalAudioEndpoint?
}

enum LocalAudioRoutingError: LocalizedError {
    case invalidEndpoint
    var errorDescription: String? { "Choose an existing local music or sound-effects task endpoint." }
}

enum LocalAudioRoutingStore {
    static var defaultURL: URL { JSONStore<LocalAudioRouting>.defaultFileURL("local-audio-routing.json") }
    static func load(fileURL: URL = defaultURL) throws -> LocalAudioRouting {
        let records = try JSONStore<LocalAudioRouting>(fileURL: fileURL).load().filter { $0.id == "artist-brain" }
        guard records.count <= 1 else { throw LocalAudioRoutingError.invalidEndpoint }
        return records.first ?? LocalAudioRouting()
    }
    static func save(_ choice: LocalAudioRouting, fileURL: URL = defaultURL) throws {
        guard choice.id == "artist-brain" else { throw LocalAudioRoutingError.invalidEndpoint }
        if choice.source == .specific {
            guard let endpoint = choice.endpoint else { throw LocalAudioRoutingError.invalidEndpoint }
            try endpoint.validate()
        }
        try JSONStore<LocalAudioRouting>(fileURL: fileURL).upsert(choice, id: \.id)
    }
}
