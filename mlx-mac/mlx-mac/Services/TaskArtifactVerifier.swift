import CryptoKit
import ImageIO
import Darwin
import Foundation
import UniformTypeIdentifiers

struct VerifiedTaskArtifact: Sendable {
    let reference: TaskArtifactReference
    let url: URL
    let data: Data?
    let json: JSONValue?
    let request: TaskRequest?
}

enum TaskArtifactVerificationError: Error, LocalizedError {
    case invalidTaskID
    case invalidReference
    case outsideTask
    case unsafePath
    case unavailable
    case notRegularFile
    case changed
    case invalidRequest
    case invalidJSON
    case invalidImage

    var errorDescription: String? {
        switch self {
        case .invalidTaskID: "The artifact has no canonical task UUID."
        case .invalidReference: "The artifact reference is incomplete or invalid."
        case .outsideTask: "The artifact is outside this task’s artifact directory."
        case .unsafePath: "The artifact path contains a symbolic link."
        case .unavailable: "The task artifact is missing or cannot be read."
        case .notRegularFile: "Task artifacts must be regular files."
        case .changed: "The task artifact no longer matches its recorded size and digest."
        case .invalidRequest: "The saved task request does not match a supported task schema."
        case .invalidJSON: "The task result artifact is not valid JSON."
        case .invalidImage: "The task image artifact is not a decodable PNG."
        }
    }
}

enum TaskArtifactVerifier {
    private static let jsonDecodeLimit = 16 * 1024 * 1024

    static func verify(reference: TaskArtifactReference, taskID: String, root: URL) async throws -> VerifiedTaskArtifact {
        try await Task.detached(priority: .userInitiated) {
            try verifySynchronously(reference: reference, taskID: taskID, root: root)
        }.value
    }

    static func verifyPNG(reference: TaskArtifactReference, taskID: String, root: URL) async throws -> VerifiedTaskArtifact {
        let artifact = try await verify(reference: reference, taskID: taskID, root: root)
        guard artifact.url.pathExtension.lowercased() == "png",
              let source = CGImageSourceCreateWithURL(artifact.url as CFURL, nil),
              CGImageSourceGetType(source) as String? == "public.png",
              Self.hasDecodableImage(source) else {
            throw TaskArtifactVerificationError.invalidImage
        }
        return artifact
    }

    static func verifyImage(reference: TaskArtifactReference, taskID: String, root: URL) async throws -> VerifiedTaskArtifact {
        let artifact = try await verify(reference: reference, taskID: taskID, root: root)
        let extensionName = artifact.url.pathExtension.lowercased()
        guard ["png", "jpg", "jpeg", "webp"].contains(extensionName),
              let source = CGImageSourceCreateWithURL(artifact.url as CFURL, nil),
              let identifier = CGImageSourceGetType(source) as String?,
              UTType(identifier)?.conforms(to: .image) == true,
              Self.hasDecodableImage(source) else {
            throw TaskArtifactVerificationError.invalidImage
        }
        return artifact
    }

    private static func hasDecodableImage(_ source: CGImageSource) -> Bool {
        CGImageSourceGetCount(source) > 0
            && CGImageSourceCreateImageAtIndex(source, 0, nil).map { $0.width > 0 && $0.height > 0 } == true
    }

    private static func verifySynchronously(reference: TaskArtifactReference, taskID: String, root: URL) throws -> VerifiedTaskArtifact {
        guard let parsedID = UUID(uuidString: taskID), parsedID.uuidString.lowercased() == taskID else {
            throw TaskArtifactVerificationError.invalidTaskID
        }
        guard reference.bytes >= 0, reference.sha256.count == 64,
              reference.sha256.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789abcdef").contains($0) }),
              reference.path.hasPrefix("/"),
              !reference.path.unicodeScalars.contains(where: { $0.value < 0x20 }) else { throw TaskArtifactVerificationError.invalidReference }

        let standardizedRoot = root.standardizedFileURL
        let standardizedFile = URL(fileURLWithPath: reference.path).standardizedFileURL
        let expectedDirectory = standardizedRoot.appendingPathComponent("artifacts")
            .appendingPathComponent(taskID).standardizedFileURL.path
        guard standardizedRoot.path == root.path,
              standardizedFile.path == reference.path,
              standardizedFile.deletingLastPathComponent().path == expectedDirectory else {
            throw TaskArtifactVerificationError.outsideTask
        }

        let descriptor = try openWithoutSymlinks(standardizedFile.path)
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var fileInfo = stat()
        guard fstat(descriptor, &fileInfo) == 0 else { throw TaskArtifactVerificationError.unavailable }
        guard (fileInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else { throw TaskArtifactVerificationError.notRegularFile }
        guard fileInfo.st_size >= 0, fileInfo.st_size == off_t(reference.bytes) else { throw TaskArtifactVerificationError.changed }

        var hasher = SHA256()
        var byteCount = 0
        var jsonData = Data()
        let shouldDecodeJSON = standardizedFile.pathExtension.lowercased() == "json" && reference.bytes <= jsonDecodeLimit
        while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            byteCount += chunk.count
            hasher.update(data: chunk)
            if shouldDecodeJSON { jsonData.append(chunk) }
        }
        guard byteCount == reference.bytes,
              Data(hasher.finalize()).map({ String(format: "%02x", $0) }).joined() == reference.sha256 else {
            throw TaskArtifactVerificationError.changed
        }

        var request: TaskRequest?
        var json: JSONValue?
        if shouldDecodeJSON {
            do {
                let value = try JSONDecoder().decode(JSONValue.self, from: jsonData)
                json = value
                if standardizedFile.lastPathComponent == "request.json" {
                    guard let members = json?.objectValue,
                          Set(members.keys) == ["schema", "kind", "model_path", "parameters"] else {
                        throw TaskArtifactVerificationError.invalidRequest
                    }
                    let decoded = try JSONDecoder().decode(TaskRequest.self, from: jsonData)
                    try decoded.validate()
                    request = decoded
                }
            } catch {
                if standardizedFile.lastPathComponent == "request.json" { throw TaskArtifactVerificationError.invalidRequest }
                throw TaskArtifactVerificationError.invalidJSON
            }
        } else if standardizedFile.lastPathComponent == "request.json" {
            throw TaskArtifactVerificationError.invalidRequest
        }

        return VerifiedTaskArtifact(reference: reference, url: standardizedFile,
                                    data: shouldDecodeJSON ? jsonData : nil, json: json, request: request)
    }

    /// Opens each directory component with O_NOFOLLOW, then verifies the final descriptor.
    /// This prevents a symlink swap between path validation and reading the artifact.
    private static func openWithoutSymlinks(_ path: String) throws -> Int32 {
        let components = path.split(separator: "/").map(String.init)
        guard let filename = components.last else { throw TaskArtifactVerificationError.invalidReference }
        var directory = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directory >= 0 else { throw TaskArtifactVerificationError.unavailable }
        for component in components.dropLast() {
            let next = component.withCString { openat(directory, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
            close(directory)
            guard next >= 0 else {
                if errno == ELOOP { throw TaskArtifactVerificationError.unsafePath }
                throw TaskArtifactVerificationError.unavailable
            }
            directory = next
        }
        let file = filename.withCString { openat(directory, $0, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC) }
        close(directory)
        guard file >= 0 else {
            if errno == ELOOP { throw TaskArtifactVerificationError.unsafePath }
            throw TaskArtifactVerificationError.unavailable
        }
        return file
    }
}
