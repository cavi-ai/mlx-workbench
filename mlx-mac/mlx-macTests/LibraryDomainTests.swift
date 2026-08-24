import Foundation
import XCTest

@testable import mlx_workbench

final class LibraryDomainTests: XCTestCase {
    func testUseCaseRawValuesAndIdentifiers() {
        XCTAssertEqual(UseCase.allCases.map(\.rawValue), ["coding", "general_chat", "reasoning", "vision"])
        XCTAssertEqual(UseCase.allCases.map(\.id), UseCase.allCases.map(\.rawValue))
        XCTAssertEqual(UseCase.generalChat.title, "General Chat")
    }

    func testCatalogRecordDecodesSnakeCaseAndPreservesMissingOptionalMetadata() throws {
        let json = """
        {
          "repo_identity": "mlx-community/Llama-3.2-3B-Instruct",
          "revision": "abc123",
          "updated_at": 0,
          "roles": ["general_chat", "reasoning"],
          "formats": ["gguf", "mlx"],
          "source_url": "https://example.com/catalog.json"
        }
        """

        let decoder = JSONDecoder()
        let record = try decoder.decode(CatalogRecord.self, from: Data(json.utf8))

        XCTAssertEqual(record.repoIdentity, "mlx-community/Llama-3.2-3B-Instruct")
        XCTAssertEqual(record.revision, "abc123")
        XCTAssertEqual(record.roles, [.generalChat, .reasoning])
        XCTAssertEqual(record.formats, ["gguf", "mlx"])
        XCTAssertEqual(record.estimatedMemoryBytes, nil)
    }

    func testCatalogRecordDecodesWithoutRolesAndKeepsUnknownMetadataIgnored() throws {
        let json = """
        {
          "repo_identity": "mlx-community/Qwen2.5-7B-Instruct",
          "revision": "def456",
          "updated_at": 0,
          "formats": ["mlx"],
          "source_url": "https://example.com/catalog.json",
          "unknown_field": "preserved by decoder tolerance"
        }
        """

        let decoder = JSONDecoder()
        let record = try decoder.decode(CatalogRecord.self, from: Data(json.utf8))

        XCTAssertEqual(record.repoIdentity, "mlx-community/Qwen2.5-7B-Instruct")
        XCTAssertNil(record.roles)
        XCTAssertEqual(record.formats, ["mlx"])
    }

    func testHardwareProfileFallsBackForUnknownValues() {
        let profile = HardwareProfile(chip: nil, model: nil, memoryBytes: nil, macOSVersion: nil)

        XCTAssertEqual(profile.chip, nil)
        XCTAssertEqual(profile.model, nil)
        XCTAssertEqual(profile.memoryBytes, nil)
        XCTAssertEqual(profile.macOSVersion, nil)
        XCTAssertEqual(profile.summary, "Unknown chip · Unknown model · Unknown memory · macOS Unknown macOS")
    }

    func testWorkspaceProfileCodableRoundTrip() throws {
        let profile = WorkspaceProfile(
            name: "Default Chat",
            useCase: .generalChat,
            modelIdentity: "mlx-community/Llama-3.2-3B-Instruct",
            modelPath: "/Models/Llama-3.2-3B-Instruct.gguf",
            runtime: "mlx-agent",
            generationDefaults: .init(temperature: 0.2, topP: 0.9, maxTokens: 512, seed: 42),
            savedAt: Date(timeIntervalSinceReferenceDate: 1234)
        )

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let data = try encoder.encode(profile)
        let decoded = try decoder.decode(WorkspaceProfile.self, from: data)

        XCTAssertEqual(decoded, profile)
    }

    func testModelReadinessRawValues() {
        XCTAssertEqual(ModelReadiness.allCases.map(\.rawValue), [
            "ready",
            "needs_conversion",
            "needs_runtime",
            "incomplete_cache",
            "unsupported",
            "duplicate",
            "quarantined",
        ])
        XCTAssertEqual(ModelReadiness.ready.id, "ready")
    }
}
