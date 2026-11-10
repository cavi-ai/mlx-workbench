import AppKit
import CryptoKit
import Darwin
import Foundation
import ImageIO

/// Immutable, content-addressed copies of explicitly chosen chat images. No model files live here.
actor UseImageStore {
    let root: URL
    init(root: URL = WorkbenchStatePaths.applicationSupport().appendingPathComponent("use-inputs", isDirectory: true)) { self.root = root }

    func importImage(_ url: URL) throws -> UseImage {
        let data = try read(url.resolvingSymlinksInPath(), maximum: 8_388_608)
        guard !data.isEmpty, data.count <= 8_388_608,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source) as String?, ["public.png", "public.jpeg"].contains(type),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
              let height = properties[kCGImagePropertyPixelHeight as String] as? Int,
              width > 0, height > 0, width <= 40_000_000 / height else { throw UseSessionError.image }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let image = UseImage(sha256: hash, name: url.lastPathComponent,
                             mimeType: type == "public.png" ? "image/png" : "image/jpeg", bytes: data.count)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try checkRoot()
        let target = root.appendingPathComponent(image.filename)
        if FileManager.default.fileExists(atPath: target.path) { _ = try bytes(image) }
        else {
            try data.write(to: target, options: [.withoutOverwriting])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        }
        return image
    }
    func dataURL(_ image: UseImage) throws -> String { "data:" + image.mimeType + ";base64," + (try bytes(image)).base64EncodedString() }
    func bytes(_ image: UseImage) throws -> Data {
        guard image.sha256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
              ["image/png", "image/jpeg"].contains(image.mimeType), (1...8_388_608).contains(image.bytes) else { throw UseSessionError.image }
        try checkRoot()
        let path = root.appendingPathComponent(image.filename)
        let info = try path.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
        guard info.isSymbolicLink != true, info.isRegularFile == true, info.fileSize == image.bytes else { throw UseSessionError.image }
        let data = try read(path, maximum: image.bytes)
        guard data.count == image.bytes, SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == image.sha256 else { throw UseSessionError.image }
        return data
    }
    func trashIfUnused(_ image: UseImage, retainedHashes: Set<String>) throws {
        guard !retainedHashes.contains(image.sha256) else { return }
        _ = try bytes(image)
        try FileManager.default.trashItem(at: root.appendingPathComponent(image.filename), resultingItemURL: nil)
    }
    private func read(_ path: URL, maximum: Int) throws -> Data {
        let descriptor = open(path.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw UseSessionError.image }
        let input = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? input.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else { throw UseSessionError.image }
        let data = try input.read(upToCount: maximum + 1) ?? Data()
        guard data.count <= maximum else { throw UseSessionError.image }
        return data
    }
    private func checkRoot() throws {
        var path = URL(fileURLWithPath: "/")
        for component in root.pathComponents.dropFirst() {
            path.appendPathComponent(component)
            if try path.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true { throw UseSessionError.image }
        }
    }
}
