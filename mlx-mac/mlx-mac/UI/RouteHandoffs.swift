import Foundation

/// A kind of cross-tab request and the value it carries.
struct HandoffKind<Value: Equatable> {
    fileprivate let name: String
}

extension HandoffKind where Value == LibraryRevealRequest { static var revealModel: Self { Self(name: "revealModel") } }
extension HandoffKind where Value == ModelRuntimeRecoveryRequest { static var recoverModelRuntime: Self { Self(name: "recoverModelRuntime") } }
extension HandoffKind where Value == HostedModelsRequest { static var openHostedModels: Self { Self(name: "openHostedModels") } }
extension HandoffKind where Value == ClientWiringRequest { static var wireClient: Self { Self(name: "wireClient") } }
extension HandoffKind where Value == ClientSetupRequest { static var clientSetup: Self { Self(name: "clientSetup") } }
extension HandoffKind where Value == FamilyComparisonRequest { static var compareFamily: Self { Self(name: "compareFamily") } }
extension HandoffKind where Value == ComparisonModelRequest { static var compareModel: Self { Self(name: "compareModel") } }
extension HandoffKind where Value == ServingProfileComparisonSetup { static var compareServingProfiles: Self { Self(name: "compareServingProfiles") } }
extension HandoffKind where Value == WorkflowReportImportRequest { static var importWorkflowReport: Self { Self(name: "importWorkflowReport") } }

/// Opens Library's Hosted models source, optionally selecting one saved connection.
struct HostedModelsRequest: Equatable {
    var host: ModelHost? = nil
}

/// Opens Compare's workflow report review; importing still requires review.
struct WorkflowReportImportRequest: Equatable {
    let id = UUID()
}

struct ClientSetupRequest: Equatable {
    let id = UUID()
}

/// Pending cross-tab requests, at most one per kind. A sender posts a request before selecting the
/// destination route; that route reads it while active and finishes it once applied or rejected.
/// A request the route cannot apply yet stays pending, and finishing one never clears a newer one.
struct RouteHandoffs {
    private var pending: [String: Any] = [:]

    subscript<Value>(kind: HandoffKind<Value>) -> Value? { pending[kind.name] as? Value }

    mutating func send<Value>(_ value: Value, as kind: HandoffKind<Value>) {
        pending[kind.name] = value
    }

    mutating func finish<Value>(_ value: Value, as kind: HandoffKind<Value>) {
        if self[kind] == value { pending[kind.name] = nil }
    }

    /// Reads and finishes in one step, for requests applied as soon as their route is active.
    mutating func take<Value>(_ kind: HandoffKind<Value>) -> Value? {
        defer { pending[kind.name] = nil }
        return self[kind]
    }
}
