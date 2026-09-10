import Foundation
import XCTest

@testable import mlx_workbench

/// Parity cases mirroring tests/test_quarantine.py plus ledger ordering —
/// the Swift port must refuse and record exactly like the Python original.
final class QuarantineParityTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 1_000_000_000)

    // MARK: - Guard parity

    func testRejectsTraversalOutOfARoot() throws {
        let root = try makeRoot()
        let models = root.appendingPathComponent("models")
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        let secret = root.appendingPathComponent("secret.gguf")
        try Data("x".utf8).write(to: secret)

        XCTAssertThrowsError(
            try Quarantine.guardPath(models.appendingPathComponent("../secret.gguf").path, roots: [models.path])
        ) { error in
            guard case QuarantineError.outsideRoots = error else {
                return XCTFail("expected outsideRoots, got \(error)")
            }
        }
    }

    func testRejectsSiblingDirectoryThatSharesRootPrefix() throws {
        // /models2 must not pass a guard for /models.
        let base = try makeRoot()
        let models = base.appendingPathComponent("models")
        let sibling = base.appendingPathComponent("models2")
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        let file = sibling.appendingPathComponent("model.gguf")
        try Data("x".utf8).write(to: file)

        XCTAssertThrowsError(try Quarantine.guardPath(file.path, roots: [models.path])) { error in
            guard case QuarantineError.outsideRoots = error else {
                return XCTFail("expected outsideRoots, got \(error)")
            }
        }
    }

    func testAcceptsUppercaseGGUFSuffix() throws {
        let root = try makeRoot()
        let file = root.appendingPathComponent("MODEL.GGUF")
        try Data("x".utf8).write(to: file)

        XCTAssertEqual(try Quarantine.guardPath(file.path, roots: [root.path]), Quarantine.resolve(file.path))
    }

    func testRejectsDirectoryNamedLikeAGGUf() throws {
        let root = try makeRoot()
        let directory = root.appendingPathComponent("bundle.gguf")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        XCTAssertThrowsError(try Quarantine.guardPath(directory.path, roots: [root.path])) { error in
            guard case QuarantineError.notFound = error else {
                return XCTFail("expected notFound, got \(error)")
            }
        }
    }

    // MARK: - Ledger ordering and limits

    func testLedgerListsNewestFirst() throws {
        let root = try makeRoot()
        let quarantineDir = try makeRoot()
        let first = root.appendingPathComponent("a.gguf")
        let second = root.appendingPathComponent("b.gguf")
        try Data("a".utf8).write(to: first)
        try Data("b".utf8).write(to: second)

        let earlier = now
        let later = now.addingTimeInterval(60)
        try Quarantine.move(target: first.path, roots: [root.path], quarantineDir: quarantineDir.path, now: earlier)
        try Quarantine.move(target: second.path, roots: [root.path], quarantineDir: quarantineDir.path, now: later)

        let records = Quarantine.ledger(quarantineDir: quarantineDir.path)
        XCTAssertEqual(records.count, 2)
        XCTAssertTrue(records[0].from.hasSuffix("b.gguf"))
        XCTAssertTrue(records[1].from.hasSuffix("a.gguf"))
    }

    func testLedgerRespectsLimit() throws {
        let root = try makeRoot()
        let quarantineDir = try makeRoot()
        for index in 0..<3 {
            let file = root.appendingPathComponent("m\(index).gguf")
            try Data("x".utf8).write(to: file)
            try Quarantine.move(
                target: file.path, roots: [root.path],
                quarantineDir: quarantineDir.path, now: now.addingTimeInterval(TimeInterval(index))
            )
        }

        let records = Quarantine.ledger(quarantineDir: quarantineDir.path, limit: 2)
        XCTAssertEqual(records.count, 2)
        XCTAssertTrue(records[0].from.hasSuffix("m2.gguf"))
        XCTAssertTrue(records[1].from.hasSuffix("m1.gguf"))
    }

    func testEmptyLedgerForMissingDirectory() throws {
        let missing = try makeRoot().appendingPathComponent("nothing")
        XCTAssertEqual(Quarantine.ledger(quarantineDir: missing.path), [])
    }

    // MARK: - Restore (put back)

    func testRestoreMovesTheFileBackToItsOrigin() throws {
        let root = try makeRoot()
        let quarantineDir = try makeRoot()
        let file = root.appendingPathComponent("wanted.gguf")
        try Data("weights".utf8).write(to: file)

        let record = try Quarantine.move(target: file.path, roots: [root.path], quarantineDir: quarantineDir.path, now: now)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))

        try Quarantine.restore(record)

        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(try Data(contentsOf: file), Data("weights".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: record.to))
    }

    func testRestoreRefusesWhenTheOriginalLocationIsTaken() throws {
        let root = try makeRoot()
        let quarantineDir = try makeRoot()
        let file = root.appendingPathComponent("wanted.gguf")
        try Data("weights".utf8).write(to: file)
        let record = try Quarantine.move(target: file.path, roots: [root.path], quarantineDir: quarantineDir.path, now: now)
        // Someone re-downloaded a file at the original path since the move.
        try Data("new download".utf8).write(to: file)

        XCTAssertThrowsError(try Quarantine.restore(record)) { error in
            guard case QuarantineError.restoreBlocked = error else {
                return XCTFail("expected restoreBlocked, got \(error)")
            }
        }
        // Neither copy is touched.
        XCTAssertEqual(try Data(contentsOf: file), Data("new download".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: record.to))
    }

    func testRestoreRefusesWhenTheQuarantinedFileIsGone() throws {
        let record = QuarantineRecord(
            movedAt: "2026-09-10T00:00:00Z",
            from: "/tmp/never-was.gguf",
            to: "/tmp/also-gone.gguf",
            bytes: 1
        )

        XCTAssertThrowsError(try Quarantine.restore(record)) { error in
            guard case QuarantineError.notFound = error else {
                return XCTFail("expected notFound, got \(error)")
            }
        }
    }

    // MARK: - Helpers

    private func makeRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlx-workbench-quarantine-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
