import Foundation

// MARK: - RuntimeInstaller
//
// Guided runtime setup ("click a button, it handles it"): runs the repo's
// `make install` — submodule check + .venv (Python 3.12) + convert/serve
// packages — with a live log tail. Only available when the app is running
// from a checkout (WorkbenchPython.repoRoot()); installed builds keep the
// manual hint.

@MainActor
final class RuntimeInstaller: ObservableObject {
    enum State: Equatable {
        case idle
        case running
        case succeeded
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    /// Last lines of installer output, newest last. Capped so a long pip
    /// scroll can't grow memory unboundedly.
    @Published private(set) var logTail: [String] = []

    private static let maxTailLines = 200

    /// The repo checkout the installer would operate on, if discoverable.
    var repoRoot: URL? { WorkbenchPython.repoRoot() }

    var canInstall: Bool {
        repoRoot != nil && state != .running
    }

    var summary: String {
        switch state {
        case .idle: return "Not started"
        case .running: return "Installing…"
        case .succeeded: return "Install finished"
        case .failed(let reason): return "Install failed: \(reason)"
        }
    }

    func install() async {
        guard let repoRoot, state != .running else { return }
        state = .running
        logTail = []

        do {
            try await Self.runMakeInstall(repoRoot: repoRoot) { [weak self] line in
                guard let self else { return }
                Task { @MainActor in
                    self.logTail.append(line)
                    if self.logTail.count > Self.maxTailLines {
                        self.logTail.removeFirst(self.logTail.count - Self.maxTailLines)
                    }
                }
            }
            state = .succeeded
        } catch {
            state = .failed(AppHost.render(error))
        }
    }

    /// Runs `make install` in the repo root, streaming combined output
    /// line-by-line. Throws on non-zero exit with the last lines as context.
    nonisolated static func runMakeInstall(
        repoRoot: URL,
        onLine: @escaping @Sendable (String) -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/make")
            process.arguments = ["install"]
            process.currentDirectoryURL = repoRoot

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            let buffer = LineBuffer(onLine: onLine)
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                buffer.append(data)
            }

            process.terminationHandler = { process in
                pipe.fileHandleForReading.readabilityHandler = nil
                buffer.finish()
                if process.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: InstallError.exited(Int(process.terminationStatus)))
                }
            }

            do {
                try process.run()
            } catch {
                pipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(throwing: error)
            }
        }
    }

    enum InstallError: LocalizedError {
        case exited(Int)

        var errorDescription: String? {
            switch self {
            case .exited(let code): return "make install exited with status \(code)."
            }
        }
    }

    /// Thread-safe accumulator that splits streamed bytes into lines.
    private final class LineBuffer: @unchecked Sendable {
        private var pending = Data()
        private let lock = NSLock()
        private let onLine: @Sendable (String) -> Void

        init(onLine: @escaping @Sendable (String) -> Void) {
            self.onLine = onLine
        }

        func append(_ data: Data) {
            lock.lock()
            pending.append(data)
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = pending.prefix(upTo: newline)
                pending = pending.suffix(from: pending.index(after: newline))
                emit(line)
            }
            lock.unlock()
        }

        func finish() {
            lock.lock()
            if !pending.isEmpty {
                let rest = pending
                pending = Data()
                emit(rest)
            }
            lock.unlock()
        }

        private func emit(_ data: Data.SubSequence) {
            let line = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { return }
            onLine(line)
        }
    }
}
