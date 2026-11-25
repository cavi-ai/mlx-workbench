import Foundation
import XCTest

@testable import mlx_workbench

final class MenuBarInsertionTests: XCTestCase {
    private var suiteName = ""
    private var defaults = UserDefaults.standard
    private var posts = 0
    private var observer: NSObjectProtocol?

    override func setUp() {
        super.setUp()
        suiteName = "MenuBarInsertionTests." + UUID().uuidString
        defaults = UserDefaults(suiteName: suiteName)!
        posts = 0
        observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: defaults, queue: nil
        ) { [weak self] _ in self?.posts += 1 }
    }

    override func tearDown() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func settle() { RunLoop.current.run(until: Date().addingTimeInterval(0.3)) }

    func testStoringTheCurrentValueWritesNothing() {
        defaults.set(false, forKey: WorkbenchMenuBarItem.storageKey)
        settle()
        posts = 0
        XCTAssertFalse(WorkbenchMenuBarItem.store(false, in: defaults))
        settle()
        XCTAssertEqual(posts, 0)
        XCTAssertEqual(defaults.object(forKey: WorkbenchMenuBarItem.storageKey) as? Bool, false)
    }

    func testStoringANewValuePersistsAndPostsOnce() {
        defaults.set(true, forKey: WorkbenchMenuBarItem.storageKey)
        settle()
        posts = 0
        XCTAssertTrue(WorkbenchMenuBarItem.store(false, in: defaults))
        settle()
        XCTAssertEqual(posts, 1)
        XCTAssertEqual(defaults.object(forKey: WorkbenchMenuBarItem.storageKey) as? Bool, false)
    }

    func testAnAbsentKeyReadsAsShown() {
        XCTAssertNil(defaults.object(forKey: WorkbenchMenuBarItem.storageKey))
        XCTAssertFalse(WorkbenchMenuBarItem.store(true, in: defaults))
        settle()
        XCTAssertEqual(posts, 0)
        XCTAssertNil(defaults.object(forKey: WorkbenchMenuBarItem.storageKey))
        XCTAssertTrue(WorkbenchMenuBarItem.store(false, in: defaults))
        XCTAssertEqual(defaults.object(forKey: WorkbenchMenuBarItem.storageKey) as? Bool, false)
    }
}
