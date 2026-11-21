import Foundation

/// Whether a served model may be stopped or unloaded.
///
/// History, active work, a busy host-memory operation, and an in-flight fleet
/// change are one answer. Callers do not restate the combination.
struct ServedModelChange: Equatable, Sendable {
    var historyLoaded: Bool
    var blockedByWork: Bool
    var hostMemoryBusy: Bool
    /// True while the endpoint fleet is applying a change.
    var endpointChanging: Bool
    /// Workbench-owned endpoints wait out `endpointChanging`. Discovered servers do not.
    var workbenchManaged: Bool

    var allowed: Bool {
        historyLoaded && !blockedByWork && !hostMemoryBusy && (!workbenchManaged || !endpointChanging)
    }
}
