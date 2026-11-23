import XCTest
@testable import mlx_workbench

final class QuickConnectSnippetsTests: XCTestCase {

    // MARK: - Shell & Python Escaping

    func testShellQuoteEscapesSingleQuotesAndMetacharactersSafely() {
        let hostile = "org/model'; rm -rf /; $(whoami) `id` \"quote\""
        let quoted = QuickConnectSnippets.shellQuote(hostile)
        XCTAssertTrue(quoted.hasPrefix("'"))
        XCTAssertTrue(quoted.hasSuffix("'"))
        XCTAssertEqual(quoted, "'org/model'\\''; rm -rf /; $(whoami) `id` \"quote\"'")
    }

    func testCurlPayloadWithHostileModelIDProducesValidJSONAndSingleQuotedShellArg() throws {
        let hostileModel = "org/bad'$(touch /tmp/pwned)\"\nmodel"
        let target = QuickConnectTarget(
            baseURL: "http://127.0.0.1:8766/v1",
            modelID: hostileModel,
            requiresAPIKey: false,
            supportsChat: true,
            supportsResponses: true,
            supportsAnthropic: true
        )

        let chat = QuickConnectSnippets.curlChat(for: target)
        XCTAssertTrue(chat.contains("curl -sS 'http://127.0.0.1:8766/v1/chat/completions'"))
        XCTAssertFalse(chat.contains("Authorization"))

        let marker = "  -d '"
        let range = try XCTUnwrap(chat.range(of: marker))
        let tail = String(chat[range.upperBound...])
        XCTAssertTrue(tail.hasSuffix("'"))
        let shellInner = String(tail.dropLast())
        let jsonText = shellInner.replacingOccurrences(of: "'\\''", with: "'")
        let data = try XCTUnwrap(jsonText.data(using: .utf8))
        let decoded = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(decoded["model"] as? String, hostileModel)
    }

    func testPythonStringLiteralEscapesQuotesBackslashesAndNewlines() {
        let hostileModel = "org/model\", evil=os.system('id')\n#\"\\"
        let target = QuickConnectTarget(
            baseURL: "http://127.0.0.1:8766/v1",
            modelID: hostileModel,
            requiresAPIKey: true,
            supportsChat: true,
            supportsResponses: true,
            supportsAnthropic: true
        )

        let openai = QuickConnectSnippets.pythonOpenAI(for: target)
        let anthropic = QuickConnectSnippets.pythonAnthropic(for: target)

        let expectedLiteral = QuickConnectSnippets.pythonStringLiteral(hostileModel)
        XCTAssertFalse(expectedLiteral.contains("\n"))
        XCTAssertTrue(openai.contains("model=\(expectedLiteral),"))
        XCTAssertTrue(anthropic.contains("model=\(expectedLiteral),"))
    }

    // MARK: - Auth vs Unauth Placeholders & Secret-Free Guarantee

    func testUnauthenticatedEndpointOmitsAuthHeadersAndUsesLocalFallbackInPython() {
        let target = QuickConnectTarget(
            baseURL: "http://127.0.0.1:8766/v1",
            modelID: "mlx-community/Qwen2.5-7B-Instruct-4bit",
            requiresAPIKey: false,
            supportsChat: true,
            supportsResponses: true,
            supportsAnthropic: true
        )

        let chat = QuickConnectSnippets.curlChat(for: target)
        let responses = QuickConnectSnippets.curlResponses(for: target)
        let anthropicCurl = QuickConnectSnippets.curlAnthropic(for: target)
        let openaiPy = QuickConnectSnippets.pythonOpenAI(for: target)
        let anthropicPy = QuickConnectSnippets.pythonAnthropic(for: target)

        XCTAssertFalse(chat.contains("Authorization:"))
        XCTAssertFalse(responses.contains("Authorization:"))
        XCTAssertFalse(anthropicCurl.contains("x-api-key:"))
        XCTAssertTrue(anthropicCurl.contains("anthropic-version: 2023-06-01"))

        XCTAssertTrue(openaiPy.contains("api_key=os.environ.get(\"MLX_AGENT_API_KEY\", \"local\")"))
        XCTAssertTrue(anthropicPy.contains("api_key=os.environ.get(\"MLX_AGENT_API_KEY\", \"local\")"))
        XCTAssertTrue(anthropicPy.contains("base_url=\"http://127.0.0.1:8766\","))
        XCTAssertFalse(anthropicPy.contains("base_url=\"http://127.0.0.1:8766/v1\""))
    }

    func testAuthenticatedEndpointUsesEnvVarPlaceholderAndNeverEmbedsRawSecrets() {
        let fakeDigest = String(repeating: "a", count: 64)
        let settings = FrontDoorSettings(port: 8790, apiKeySHA256: fakeDigest)
        let target = QuickConnectTarget.frontDoor(settings: settings, modelID: "org/Llama-3.2-3B")

        XCTAssertTrue(target.requiresAPIKey)
        XCTAssertTrue(target.isFrontDoor)

        let all = QuickConnectSnippets.snippets(for: target)
        XCTAssertEqual(
            all.map(\.format),
            [.curlChat, .curlResponses, .curlAnthropic, .pythonOpenAI, .pythonAnthropic]
        )

        for item in all {
            XCTAssertFalse(item.code.contains(fakeDigest), "Digest must never appear in \(item.format)")
            XCTAssertTrue(item.code.contains("MLX_AGENT_API_KEY"), "Placeholder required in \(item.format)")
        }

        let chat = QuickConnectSnippets.curlChat(for: target)
        XCTAssertTrue(chat.contains("-H \"Authorization: Bearer ${MLX_AGENT_API_KEY}\""))

        let anthropicCurl = QuickConnectSnippets.curlAnthropic(for: target)
        XCTAssertTrue(anthropicCurl.contains("-H \"x-api-key: ${MLX_AGENT_API_KEY}\""))

        let openaiPy = QuickConnectSnippets.pythonOpenAI(for: target)
        XCTAssertTrue(openaiPy.contains("api_key=os.environ[\"MLX_AGENT_API_KEY\"]"))

        let anthropicPy = QuickConnectSnippets.pythonAnthropic(for: target)
        XCTAssertTrue(anthropicPy.contains("api_key=os.environ[\"MLX_AGENT_API_KEY\"]"))
    }

    // MARK: - Typed Embeddings Routes & Format Discovery

    func testTypedEmbeddingsRouteGeneratesEmbeddingsCurlAndOpenAIEmbeddingsPython() {
        let listener = FrontDoorListener(
            port: 8791,
            apiKeySHA256: String(repeating: "b", count: 64),
            routes: [FrontDoorRoute(id: "mlx-community/bge-small-en", taskKinds: ["embeddings"])]
        )
        let target = QuickConnectTarget.frontDoor(listener)
        XCTAssertNotNil(target)
        guard let target else { return }

        XCTAssertFalse(target.supportsChat)
        XCTAssertTrue(target.supportsEmbeddings)
        XCTAssertEqual(QuickConnectSnippets.availableFormats(for: target), [.curlEmbeddings, .pythonOpenAI])

        let curl = QuickConnectSnippets.curlEmbeddings(for: target)
        XCTAssertTrue(curl.contains("'http://127.0.0.1:8791/v1/embeddings'"))
        XCTAssertTrue(curl.contains("-H \"Authorization: Bearer ${MLX_AGENT_API_KEY}\""))

        let py = QuickConnectSnippets.pythonOpenAI(for: target)
        XCTAssertTrue(py.contains("client.embeddings.create("))
        XCTAssertFalse(py.contains("chat.completions.create("))
    }

    func testClientsEndpointRowExposesQuickConnectSnippetsForRunningServersOnly() {
        let running = ClientsEndpointRow(
            id: "srv-1",
            kind: .running,
            name: "Qwen",
            port: 8766,
            identity: "org/Qwen",
            isSelected: true,
            apiKeyRequired: true,
            supportsResponses: true,
            supportsAnthropic: true
        )
        XCTAssertNotNil(running.quickConnectTarget)
        XCTAssertEqual(
            running.quickConnectSnippets.map(\.format),
            [.curlChat, .curlResponses, .curlAnthropic, .pythonOpenAI, .pythonAnthropic]
        )

        let ghost = ClientsEndpointRow(
            id: "ghost-8800",
            kind: .ghost,
            name: "",
            port: 8800,
            identity: nil,
            isSelected: false
        )
        XCTAssertNil(ghost.quickConnectTarget)
        XCTAssertTrue(ghost.quickConnectSnippets.isEmpty)
    }

    func testURLNormalizationHandlesTrailingSlashesAndV1Suffix() {
        XCTAssertEqual(QuickConnectSnippets.normalizedV1BaseURL("http://127.0.0.1:8766"), "http://127.0.0.1:8766/v1")
        XCTAssertEqual(QuickConnectSnippets.normalizedV1BaseURL("http://127.0.0.1:8766/v1/"), "http://127.0.0.1:8766/v1")
        XCTAssertEqual(QuickConnectSnippets.normalizedRootBaseURL("http://127.0.0.1:8766/v1/"), "http://127.0.0.1:8766")
        XCTAssertEqual(QuickConnectSnippets.normalizedRootBaseURL("http://127.0.0.1:8766"), "http://127.0.0.1:8766")
    }
}
