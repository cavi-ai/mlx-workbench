import Foundation

/// A rejected inference setting, worded for inline form feedback.
struct InferenceSettingError: LocalizedError, Equatable {
    let message: String
    var errorDescription: String? { message }
}

/// A whole-number engine setting. Blank text selects the engine default.
struct IntegerSetting: Sendable {
    let title: String
    let range: ClosedRange<Int>
    var multiple: Int? = nil
    var unit = ""

    func value(_ text: String) throws -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        guard let number = Int(trimmed) else { throw rangeError }
        try check(number)
        return number
    }

    func check(_ value: Int) throws {
        guard range.contains(value) else { throw rangeError }
        if let multiple, value % multiple != 0 {
            throw InferenceSettingError(message: "\(title) must be a multiple of \(multiple)\(unit).")
        }
    }

    func accepts(_ value: Int) -> Bool { (try? check(value)) != nil }

    private var rangeError: InferenceSettingError {
        InferenceSettingError(message: "\(title) must be a whole number from \(range.lowerBound) to \(range.upperBound).")
    }
}

/// A finite decimal engine setting. Blank text selects the engine default.
struct NumberSetting: Sendable {
    let title: String
    let range: ClosedRange<Double>
    var excludesLowerBound = false
    var unit = ""

    func value(_ text: String) throws -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        guard let number = Double(trimmed) else { throw rangeError }
        try check(number)
        return number
    }

    func check(_ value: Double) throws {
        guard value.isFinite, range.contains(value), !(excludesLowerBound && value == range.lowerBound) else { throw rangeError }
    }

    func accepts(_ value: Double) -> Bool { (try? check(value)) != nil }

    private var rangeError: InferenceSettingError {
        let lower = Self.text(range.lowerBound), upper = Self.text(range.upperBound)
        return InferenceSettingError(message: excludesLowerBound
            ? "\(title) must be greater than \(lower) and at most \(upper)\(unit)."
            : "\(title) must be a number from \(lower) to \(upper)\(unit).")
    }

    private static func text(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }
}

/// Text the engine accepts: 1 to `limit` Unicode scalars, with tabs and newlines allowed.
struct TextSetting: Sendable {
    let title: String
    let limit: Int

    func check(_ text: String) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.unicodeScalars.count <= limit,
              !text.unicodeScalars.contains(where: { $0.value < 32 && $0 != "\n" && $0 != "\t" }) else {
            throw InferenceSettingError(message: "\(title) must contain text, at most \(limit) characters, without control characters.")
        }
    }

    func accepts(_ text: String) -> Bool { (try? check(text)) != nil }
}

/// Engine plan rules (mlx-agent generate, video, describe, speak and music) shared by
/// Library task drafts and Compare prompt drafts. Model-specific video alignment, frame
/// grouping and area caps remain the engine's authority.
enum InferenceSettings {
    static let seed = IntegerSetting(title: "Seed", range: 0...4_294_967_295)

    enum ImageGeneration {
        static let prompt = TextSetting(title: "Prompt", limit: 2000)
        static let size = IntegerSetting(title: "Image size", range: 256...2048, multiple: 16, unit: " pixels")
        static let width = IntegerSetting(title: "Width", range: 256...2048, multiple: 16, unit: " pixels")
        static let height = IntegerSetting(title: "Height", range: 256...2048, multiple: 16, unit: " pixels")
        static let steps = IntegerSetting(title: "Steps", range: 1...100)
    }

    enum VideoGeneration {
        static let prompt = TextSetting(title: "Prompt", limit: 2000)
        static let width = IntegerSetting(title: "Width", range: 64...1920)
        static let height = IntegerSetting(title: "Height", range: 64...1920)
        static let frames = IntegerSetting(title: "Frames", range: 1...241)
        static let fps = IntegerSetting(title: "Frame rate", range: 1...60)
        static let steps = IntegerSetting(title: "Steps", range: 1...100)
    }

    /// Image and video understanding.
    enum Understanding {
        static let prompt = TextSetting(title: "Question", limit: 4000)
        static let maxTokens = IntegerSetting(title: "Token limit", range: 1...4096)
        static let temperature = NumberSetting(title: "Temperature", range: 0...2)
        static let maxPixels = IntegerSetting(title: "Pixel limit", range: 1...100_000_000)
        static let videoFPS = NumberSetting(title: "Frame rate", range: 0.1...8)
    }

    enum Speech {
        static let text = TextSetting(title: "Text", limit: 2000)
        static let speed = NumberSetting(title: "Speed", range: 0.5...2)
    }

    enum Music {
        static let caption = TextSetting(title: "Caption", limit: 2000)
        static let lyrics = TextSetting(title: "Lyrics", limit: 10000)
        static let duration = NumberSetting(title: "Duration", range: 0...360, excludesLowerBound: true, unit: " seconds")
        static let steps = IntegerSetting(title: "Steps", range: 1...30)
    }

    /// The first rejected setting's message, or nil when every check passes.
    static func problem(_ checks: () throws -> Void) -> String? {
        do { try checks(); return nil } catch { return error.localizedDescription }
    }
}
