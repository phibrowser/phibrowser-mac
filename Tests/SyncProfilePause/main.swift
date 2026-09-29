import Foundation

@main
struct ProfilePauseTests {
    static func evaluate(_ syncable: [String], mappings: [String: String] = [:],
                         known: Set<String> = [], creating: Set<String> = [],
                         result: SyncProfileMappingPassResult? = nil) -> SyncProfileMappingPause {
        SyncProfileMappingPause.evaluate(syncableProfileIds: syncable, persistedMappings: mappings,
                                         knownUnmappedProfileIds: known,
                                         profileIdsBeingCreated: creating, lastPassResult: result)
    }

    static func main() {
        // Nothing to sync: no syncable Profile, whatever else is known.
        precondition(evaluate([]) == .notPaused)
        precondition(evaluate([], mappings: ["gone": "u"], known: ["gone"], result: .definitiveFailure) == .notPaused,
                     "Profiles outside the syncable list never pause")

        // All mapped, before and after a measured pass.
        let mapped = ["Default": "u1", "Profile 1": "u2"]
        precondition(evaluate(["Default", "Profile 1"], mappings: mapped) == .notPaused)
        precondition(evaluate(["Default", "Profile 1"], mappings: mapped, known: [], result: .measured) == .notPaused)
        precondition(evaluate(["Default"], mappings: mapped, known: [], result: .heldTransient) == .notPaused,
                     "A failed pass alone does not pause a device whose Profiles are all mapped")

        // One unmapped, no pass yet: the synchronous check pauses at once.
        let fresh = evaluate(["Default", "Profile 2"], mappings: mapped)
        precondition(fresh.isPaused && fresh.unmappedProfileIds == ["Profile 2"] && fresh.reason == .registering)

        // A persisted mapping the key layer knows to be absent on the server (its envelope is gone).
        let dead = evaluate(["Default", "Profile 1"], mappings: mapped, known: ["Profile 1"], result: .measured)
        precondition(dead.isPaused && dead.unmappedProfileIds == ["Profile 1"] && dead.reason == .registering)

        // A Profile the key layer is creating is ignored until its adopt has finished or failed.
        let creating = evaluate(["Default", "Created"], mappings: mapped, creating: ["Created"])
        precondition(creating == .notPaused)
        let creatingAfterPass = evaluate(["Default", "Created"], mappings: mapped, known: ["Created"],
                                         creating: ["Created"], result: .measured)
        precondition(creatingAfterPass == .notPaused,
                     "A pass that ran inside the creation must not pause for the Profile being created")
        // The same Profile after its adopt failed: no longer being created, still no mapping.
        let adoptFailed = evaluate(["Default", "Created"], mappings: mapped, known: ["Created"], result: .heldTransient)
        precondition(adoptFailed.isPaused && adoptFailed.unmappedProfileIds == ["Created"])

        // Each reason.
        precondition(evaluate(["New"], result: nil).reason == .registering)
        precondition(evaluate(["New"], known: ["New"], result: .measured).reason == .registering)
        precondition(evaluate(["New"], known: ["New"], result: .heldTransient).reason == .retrying)
        precondition(evaluate(["New"], known: ["New"], result: .definitiveFailure).reason == .needsAttention)

        // Sorted and stable ids.
        let many = evaluate(["b", "a", "c"], mappings: ["c": "u"])
        precondition(many.unmappedProfileIds == ["a", "b"])
        print("PASS profile pause: nothing to sync, all mapped, unmapped before any pass, dead mapping, creation ignored until its adopt ends, every reason")
    }
}
