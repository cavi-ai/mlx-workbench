import Darwin
import Foundation
import SystemConfiguration

enum NativeUITestEnvironment {
    private struct IsolationError: LocalizedError {
        let reason: String
        var errorDescription: String? {
            "Native UI tests require a macOS VM with this user's active Aqua console. \(reason) Run the tests inside the isolated VM after logging in to its desktop."
        }
    }

    static func requireIsolatedAquaSession() throws {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else {
            throw IsolationError(reason: "Cannot verify the hardware model.")
        }
        var model = [CChar](repeating: 0, count: size)
        let result = model.withUnsafeMutableBufferPointer { buffer in
            sysctlbyname("hw.model", buffer.baseAddress, &size, nil, 0)
        }
        guard result == 0, String(cString: model).hasPrefix("VirtualMac") else {
            throw IsolationError(reason: "The hardware model is not VirtualMac.")
        }

        var consoleUID: uid_t = 0
        guard let consoleUser = SCDynamicStoreCopyConsoleUser(nil, &consoleUID, nil),
              (consoleUser as String) != "loginwindow",
              getuid() != 0, consoleUID == getuid() else {
            throw IsolationError(reason: "The active console does not belong to the test user.")
        }

        let session = Process()
        let output = Pipe()
        session.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        session.arguments = ["managername"]
        session.standardOutput = output
        session.standardError = FileHandle.nullDevice
        do {
            try session.run()
        } catch {
            throw IsolationError(reason: "Cannot verify the Aqua session.")
        }
        session.waitUntilExit()
        let manager = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard session.terminationStatus == 0, manager == "Aqua" else {
            throw IsolationError(reason: "The test process is not in an Aqua session.")
        }
    }
}
