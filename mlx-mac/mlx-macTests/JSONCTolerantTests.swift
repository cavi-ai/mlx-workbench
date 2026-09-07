import Foundation
import XCTest

@testable import mlx_workbench

/// JSONCTolerant backs cross-client config edits: comments and trailing
/// commas tolerated, string contents never touched.
final class JSONCTolerantTests: XCTestCase {
    func testStripsLineAndBlockComments() throws {
        let text = """
        {
          // a line comment
          "a": 1, /* a block comment */
          "b": 2
        }
        """
        let parsed = try JSONCTolerant.parse(text)
        XCTAssertEqual(parsed["a"] as? Int, 1)
        XCTAssertEqual(parsed["b"] as? Int, 2)
    }

    func testStripsTrailingCommasInObjectsAndArrays() throws {
        let text = """
        { "a": [1, 2,], "b": { "c": 3, }, }
        """
        let parsed = try JSONCTolerant.parse(text)
        XCTAssertEqual(parsed["a"] as? [Int], [1, 2])
        XCTAssertEqual((parsed["b"] as? [String: Int])?["c"], 3)
    }

    func testCommentAndCommaLookalikesInsideStringsSurvive() throws {
        let text = #"{ "url": "https://example.com//path", "note": "a, } b", "esc": "q\" // not a comment" }"#
        let parsed = try JSONCTolerant.parse(text)
        XCTAssertEqual(parsed["url"] as? String, "https://example.com//path")
        XCTAssertEqual(parsed["note"] as? String, "a, } b")
        XCTAssertEqual(parsed["esc"] as? String, "q\" // not a comment")
    }

    func testInvalidJSONThrows() {
        XCTAssertThrowsError(try JSONCTolerant.parse("{ \"a\": }")) { error in
            guard case JSONCTolerant.ParseError.invalidJSON = error else {
                return XCTFail("expected invalidJSON, got \(error)")
            }
        }
    }

    func testNonObjectTopLevelThrows() {
        XCTAssertThrowsError(try JSONCTolerant.parse("[1, 2, 3]"))
    }

    func testSerializeIsSortedNewlineTerminatedAndRoundTrips() throws {
        let text = #"{ "b": 2, "a": [1, 2,], }"#
        let parsed = try JSONCTolerant.parse(text)

        let serialized = try JSONCTolerant.serialize(parsed)
        XCTAssertTrue(serialized.hasSuffix("\n"))
        XCTAssertLessThan(
            serialized.range(of: "\"a\"")!.lowerBound,
            serialized.range(of: "\"b\"")!.lowerBound
        )

        let reparsed = try JSONCTolerant.parse(serialized)
        XCTAssertEqual(reparsed["a"] as? [Int], [1, 2])
        XCTAssertEqual(reparsed["b"] as? Int, 2)
    }
}
