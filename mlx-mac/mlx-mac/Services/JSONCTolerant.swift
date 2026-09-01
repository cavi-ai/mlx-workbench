import Foundation

// MARK: - JSONCTolerant
//
// Comment- and trailing-comma-tolerant JSONC parsing for validation and
// structured edits, plus canonical serialization. The scanner keeps string
// contents intact: `//` or a trailing comma *inside a string* is never
// touched.

enum JSONCTolerant {
    enum ParseError: LocalizedError {
        case invalidJSON(String)

        var errorDescription: String? {
            switch self {
            case .invalidJSON(let detail):
                return "The config file could not be parsed: \(detail)"
            }
        }
    }

    /// Parse JSONC text into a dictionary. Comments and trailing commas are
    /// tolerated; anything else invalid throws.
    static func parse(_ text: String) throws -> [String: Any] {
        let cleaned = strip(text)
        guard let data = cleaned.data(using: .utf8) else {
            throw ParseError.invalidJSON("not valid UTF-8")
        }
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ParseError.invalidJSON("top level is not an object")
            }
            return object
        } catch let error as ParseError {
            throw error
        } catch {
            throw ParseError.invalidJSON(error.localizedDescription)
        }
    }

    /// Canonical JSON serialization (sorted keys, pretty printed). Valid JSON
    /// is valid JSONC, so this is safe to write back to `.jsonc` files.
    static func serialize(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        guard var text = String(data: data, encoding: .utf8) else {
            throw ParseError.invalidJSON("serialization produced non-UTF-8 output")
        }
        if !text.hasSuffix("\n") { text += "\n" }
        return text
    }

    /// Remove `//` and `/* */` comments and trailing commas, preserving
    /// string literals byte-for-byte.
    static func strip(_ text: String) -> String {
        var output = ""
        output.reserveCapacity(text.count)
        let characters = Array(text)
        var index = 0
        var inString = false

        func nextSignificant(from start: Int) -> Character? {
            var cursor = start
            while cursor < characters.count {
                let c = characters[cursor]
                if c == " " || c == "\t" || c == "\n" || c == "\r" {
                    cursor += 1
                } else {
                    return c
                }
            }
            return nil
        }

        while index < characters.count {
            let c = characters[index]
            if inString {
                output.append(c)
                if c == "\\", index + 1 < characters.count {
                    output.append(characters[index + 1])
                    index += 2
                    continue
                }
                if c == "\"" { inString = false }
                index += 1
                continue
            }
            if c == "\"" {
                inString = true
                output.append(c)
                index += 1
                continue
            }
            if c == "/", index + 1 < characters.count, characters[index + 1] == "/" {
                while index < characters.count, characters[index] != "\n" { index += 1 }
                continue
            }
            if c == "/", index + 1 < characters.count, characters[index + 1] == "*" {
                index += 2
                while index + 1 < characters.count, !(characters[index] == "*" && characters[index + 1] == "/") {
                    index += 1
                }
                index += 2
                continue
            }
            if c == ",", let next = nextSignificant(from: index + 1), next == "}" || next == "]" {
                index += 1
                continue
            }
            output.append(c)
            index += 1
        }
        return output
    }
}
