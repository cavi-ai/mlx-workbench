import Foundation

// MARK: - WorkbenchStatePaths
//
// Default locations of the app's durable state. A hosted unit-test process
// resolves every one of them beneath a temporary root, never the user's
// Application Support, config, or XDG state directories.

enum WorkbenchStatePaths {
    private static let lock = NSLock()
    private static var testRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("mlx-workbench-tests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)

    /// Hosted unit tests run inside this app (TEST_HOST). xcodebuild sets
    /// `XCTestConfigurationFilePath` in that process; an app launched by
    /// XCUIApplication receives only its explicit launch environment.
    static func isHostedUnitTest(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment["XCTestConfigurationFilePath"] != nil
    }

    /// Stands in for the user's home in a hosted unit-test process; the test
    /// bundle replaces it before every test.
    static var hostedTestRoot: URL {
        get {
            lock.lock()
            defer { lock.unlock() }
            return testRoot
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            testRoot = newValue
        }
    }

    /// `<Application Support>/mlx-workbench`: JSON stores, receipts, and caches.
    static func applicationSupport(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL {
        let base: URL
        if isHostedUnitTest(environment) {
            base = hostedTestRoot.appendingPathComponent("Library/Application Support", isDirectory: true)
        } else if let url = try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) {
            base = url
        } else {
            base = URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        }
        return base.appendingPathComponent("mlx-workbench", isDirectory: true)
    }
}
