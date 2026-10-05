import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - ComparisonMediaFixtures
//
// Built-in prompt sets for the media comparison modes. The input files are
// not bundled: each is generated deterministically at run time into the run's
// `inputs/` folder (CoreGraphics PNGs, an AVAssetWriter MP4, and the system
// voice for speech), so the repository carries no binary assets.

enum ComparisonMediaFixtures {
    static let visionSet = PromptSet(
        id: "builtin-vision",
        name: "Vision basics",
        useCase: nil,
        prompts: [
            PromptEntry(
                id: "vision-red-circle",
                text: "What shape is in this image, and what color is it?",
                maxTokens: 96,
                inputKind: .image,
                builtinInput: "red-circle",
                expectedKeywords: ["red", "circle"]
            ),
            PromptEntry(
                id: "vision-blue-squares",
                text: "How many squares are in this image, and what color are they?",
                maxTokens: 96,
                inputKind: .image,
                builtinInput: "blue-squares",
                expectedKeywords: ["three|3", "blue"]
            ),
            PromptEntry(
                id: "vision-green-triangle",
                text: "What shape is in this image, and what color is it?",
                maxTokens: 96,
                inputKind: .image,
                builtinInput: "green-triangle",
                expectedKeywords: ["triangle", "green"]
            ),
        ],
        origin: .builtin,
        mode: .vision
    )

    static let videoUnderstandingSet = PromptSet(
        id: "builtin-video-understanding",
        name: "Video basics",
        useCase: nil,
        prompts: [
            PromptEntry(
                id: "video-red-square",
                text: "What moves in this video and in which direction?",
                maxTokens: 128,
                inputKind: .video,
                builtinInput: "red-square-right",
                expectedKeywords: ["red", "right"]
            ),
        ],
        origin: .builtin,
        mode: .videoUnderstanding
    )

    /// Each sentence is spoken by the system voice; the sentence is also the reference for word error rate.
    static let speechToTextSet = PromptSet(
        id: "builtin-speech-to-text",
        name: "Spoken sentences",
        useCase: nil,
        prompts: [
            PromptEntry(
                id: "stt-fox",
                text: "The quick brown fox jumps over the lazy dog.",
                inputKind: .audio,
                builtinInput: "speech"
            ),
            PromptEntry(
                id: "stt-store",
                text: "Please call Stella and ask her to bring these things from the store.",
                inputKind: .audio,
                builtinInput: "speech"
            ),
            PromptEntry(
                id: "stt-weather",
                text: "The weather tomorrow will be sunny with a light breeze from the west.",
                inputKind: .audio,
                builtinInput: "speech"
            ),
        ],
        origin: .builtin,
        mode: .speechToText
    )

    static let textToSpeechSet = PromptSet(
        id: "builtin-text-to-speech",
        name: "Spoken output",
        useCase: nil,
        prompts: [
            PromptEntry(id: "tts-short", text: "Hello, this is a test of the speech model."),
            PromptEntry(
                id: "tts-long",
                text: "The library opens at nine every morning, and on quiet days you can hear the clock ticking while the first few visitors choose their books."
            ),
        ],
        origin: .builtin,
        mode: .textToSpeech
    )

    static let imageGenerationSet = PromptSet(
        id: "builtin-image-generation",
        name: "Image prompts",
        useCase: nil,
        prompts: [
            PromptEntry(
                id: "image-fox",
                text: "A red fox sitting in a snowy forest at dawn, soft light.",
                media: MediaParameters(size: 512, steps: 20, seed: 42)
            ),
            PromptEntry(
                id: "image-sailboat",
                text: "A small wooden sailboat on a calm blue lake under a clear sky.",
                media: MediaParameters(size: 512, steps: 20, seed: 42)
            ),
        ],
        origin: .builtin,
        mode: .imageGeneration
    )

    /// A small clip (about 33 s per variant): width and height are multiples of 16, frames are 4n+1,
    /// and fps stays unset so the model's own default applies.
    static let videoGenerationParameters = MediaParameters(width: 416, height: 240, steps: 30, seed: 42, frames: 17)

    static let videoGenerationSet = PromptSet(
        id: "builtin-video-generation",
        name: "Video prompt",
        useCase: nil,
        prompts: [
            PromptEntry(
                id: "video-ball",
                text: "A red ball bouncing on a wooden floor",
                media: videoGenerationParameters
            ),
        ],
        origin: .builtin,
        mode: .videoGeneration
    )

    static let all: [PromptSet] = [
        visionSet, videoUnderstandingSet, speechToTextSet, textToSpeechSet, imageGenerationSet, videoGenerationSet,
    ]

    // MARK: Generators

    enum FixtureError: LocalizedError {
        case unknownInput(String)
        case imageWriteFailed
        case videoWriteFailed(String)

        var errorDescription: String? {
            switch self {
            case .unknownInput(let id): return "Unknown built-in input \(id)."
            case .imageWriteFailed: return "The built-in image could not be written."
            case .videoWriteFailed(let message): return "The built-in video could not be written: \(message)"
            }
        }
    }

    static let imageEdge = 256
    static let videoFramesPerSecond = 10
    static let videoSeconds = 3

    /// Writes the built-in input an entry names into `directory` as `<prompt-id>.<ext>` and returns it.
    static func generateInput(
        for entry: PromptEntry,
        into directory: URL,
        synthesizeSpeech: (String, URL) async throws -> URL = { phrase, directory in
            try await SpeechClipSynthesizer.make(phrase: phrase, directory: directory)
        }
    ) async throws -> URL {
        guard let builtin = entry.builtinInput else { throw FixtureError.unknownInput("(none)") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stem = ComparisonOutputStore.safeComponent(entry.id)
        switch builtin {
        case "red-circle", "blue-squares", "green-triangle":
            let url = directory.appendingPathComponent("\(stem).png")
            try writeImage(named: builtin, to: url)
            return url
        case "red-square-right":
            let url = directory.appendingPathComponent("\(stem).mp4")
            try await writeMovingSquareVideo(to: url)
            return url
        case "speech":
            let url = directory.appendingPathComponent("\(stem).wav")
            let made = try await synthesizeSpeech(entry.text, directory)
            if made != url {
                try? FileManager.default.removeItem(at: url)
                try FileManager.default.moveItem(at: made, to: url)
            }
            return url
        default:
            throw FixtureError.unknownInput(builtin)
        }
    }

    // MARK: PNG

    private static func writeImage(named name: String, to url: URL) throws {
        let edge = imageEdge
        guard let context = CGContext(
            data: nil, width: edge, height: edge, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw FixtureError.imageWriteFailed }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: edge, height: edge))
        switch name {
        case "red-circle":
            context.setFillColor(CGColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 1))
            context.fillEllipse(in: CGRect(x: 56, y: 56, width: 144, height: 144))
        case "blue-squares":
            context.setFillColor(CGColor(red: 0.1, green: 0.2, blue: 0.9, alpha: 1))
            for index in 0..<3 {
                context.fill(CGRect(x: 20 + index * 80, y: 100, width: 56, height: 56))
            }
        default:
            context.setFillColor(CGColor(red: 0.1, green: 0.6, blue: 0.2, alpha: 1))
            context.beginPath()
            context.move(to: CGPoint(x: 128, y: 200))
            context.addLine(to: CGPoint(x: 52, y: 60))
            context.addLine(to: CGPoint(x: 204, y: 60))
            context.closePath()
            context.fillPath()
        }
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw FixtureError.imageWriteFailed }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw FixtureError.imageWriteFailed }
    }

    // MARK: MP4

    /// 3 seconds, 256x256, H.264: a red square moving from the left edge to the right edge on white.
    private static func writeMovingSquareVideo(to url: URL) async throws {
        try? FileManager.default.removeItem(at: url)
        let edge = imageEdge
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: edge,
            AVVideoHeightKey: edge,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: edge,
                kCVPixelBufferHeightKey as String: edge,
            ]
        )
        guard writer.canAdd(input) else { throw FixtureError.videoWriteFailed("input rejected") }
        writer.add(input)
        guard writer.startWriting() else {
            throw FixtureError.videoWriteFailed(writer.error?.localizedDescription ?? "start failed")
        }
        writer.startSession(atSourceTime: .zero)

        let frameCount = videoFramesPerSecond * videoSeconds
        let side = 48
        for frame in 0..<frameCount {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            let progress = Double(frame) / Double(frameCount - 1)
            let x = Int(progress * Double(edge - side))
            guard let pool = adaptor.pixelBufferPool else { throw FixtureError.videoWriteFailed("no pixel buffer pool") }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { throw FixtureError.videoWriteFailed("no pixel buffer") }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer),
               let context = CGContext(
                   data: base, width: edge, height: edge, bitsPerComponent: 8,
                   bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                   space: CGColorSpaceCreateDeviceRGB(),
                   bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
               ) {
                context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
                context.fill(CGRect(x: 0, y: 0, width: edge, height: edge))
                context.setFillColor(CGColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 1))
                context.fill(CGRect(x: x, y: (edge - side) / 2, width: side, height: side))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            let time = CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(videoFramesPerSecond))
            guard adaptor.append(buffer, withPresentationTime: time) else {
                throw FixtureError.videoWriteFailed(writer.error?.localizedDescription ?? "append failed")
            }
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: CMTimeValue(frameCount), timescale: CMTimeScale(videoFramesPerSecond)))
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw FixtureError.videoWriteFailed(writer.error?.localizedDescription ?? "status \(writer.status.rawValue)")
        }
    }
}
