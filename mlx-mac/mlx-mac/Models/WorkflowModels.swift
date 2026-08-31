import Foundation

enum ConversionWorkflowState: String, Codable, Equatable {
    case idle
    case inspectingSource
    case existingModelFound
    case previewingConversion
    case readyToConfirm
    case queued
    case running
    case completed
    case verifying
    case verified
    case verificationFailed
    case failed
}

/// Outcome handed back to the model workflow by the Conversion Quality Gate.
enum VerificationResolution: Equatable {
    case passed(summary: String)
    case failed(summary: String)
    /// Verification could not run (runtime missing, probe error); the model
    /// stays usable but unverified.
    case unavailable(reason: String)
    case keptAnyway
}

enum ServeWorkflowState: String, Codable, Equatable {
    case idle
    case previewing
    case readyToConfirm
    case running
    case stopped
    case failed
}

struct ConversionWorkflow: Codable, Equatable, Identifiable {
    let id: UUID
    let sourcePath: String
    let sourceModelKey: String?
    let sourceSignature: String?
    let outputPath: String
    let previewHash: String?
    let jobReceipt: String?
    let completedModelPath: String?
    let state: ConversionWorkflowState
    let serveState: ServeWorkflowState
    let message: String?
    let errorMessage: String?
    let createdAt: Date
    let updatedAt: Date
    let lastKnownAgentState: String?

    var persistenceIdentifier: String {
        id.uuidString
    }
}
