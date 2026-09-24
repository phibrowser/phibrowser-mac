import Foundation

@main
struct PairingTests {
    @MainActor static func main() async throws {
        try await testCandidatesAfterServerReset()
        try await testRegistrationAfterServerReset()
        try await testPreviewAfterServerReset()
        try await testPreviewCompleteness()
        let lifetime = EngineStopSignal(paired: true)
        let oldRound = lifetime.revision
        precondition(!lifetime.blocksData(revision: oldRound))
        lifetime.setPaired(false)
        precondition(lifetime.blocksData(revision: oldRound))
        lifetime.setPaired(true)
        precondition(lifetime.blocksData(revision: oldRound), "Old rounds cannot resume after re-enrollment")
        precondition(!lifetime.blocksData(revision: lifetime.revision))
        lifetime.stop()
        precondition(lifetime.blocksData(revision: lifetime.revision))
        var confirmationRecord: Data?
        var confirmation = SyncPairingEnrollment()
        try confirmation.configure(deviceKeyID: "confirmation", recordData: nil,
                                   saveRecord: { confirmationRecord = $0; return true })
        try confirmation.setRecoveryConfirmationRequired(true)
        try confirmation.setPaired(false)
        try confirmation.configure(deviceKeyID: "confirmation", recordData: confirmationRecord,
                                   saveRecord: { confirmationRecord = $0; return true })
        precondition(confirmation.requiresRecoveryConfirmation && !confirmation.isPaired)
        do {
            try confirmation.setPaired(true)
            preconditionFailure("Pairing cannot bypass recovery confirmation after restart")
        } catch SyncPairingPersistenceError.recoveryConfirmationRequired {}
        try confirmation.configure(deviceKeyID: "confirmation", recordData: confirmationRecord, saveRecord: { _ in false })
        do {
            try confirmation.setRecoveryConfirmationRequired(false)
            preconditionFailure("Failed persistence cannot confirm recovery")
        } catch SyncPairingPersistenceError.writeFailed {}
        precondition(confirmation.requiresRecoveryConfirmation)
        try confirmation.configure(deviceKeyID: "confirmation", recordData: confirmationRecord,
                                   saveRecord: { confirmationRecord = $0; return true })
        try confirmation.setRecoveryConfirmationRequired(false)
        try confirmation.setPaired(true)
        precondition(confirmation.isPaired)
        print("PASS persisted recovery confirmation: restart, enrollment bypass, failed writes, confirmed pairing")
        let gate = ProfilePairingGate()
        var completedRecord: Data?
        try gate.configureEnrollment(deviceKeyID: "replay", recordData: nil,
                                     saveRecord: { completedRecord = $0; return true })
        try gate.completeEnrollment()
        let replayToken = gate.spaceReplayToken
        precondition(replayToken != nil)
        try gate.configureEnrollment(deviceKeyID: "replay", recordData: completedRecord,
                                     saveRecord: { _ in true })
        precondition(gate.isPaired && gate.spaceReplayToken == replayToken,
                     "Completion must restore replay after a crash before activation")
        try gate.beginEnrollment()
        precondition(gate.spaceReplayToken == nil)
        let host = RecordingHost()
        gate.modalHost = host
        gate.handleMappingsDidResolve(needsPairing: true, needsPairingActionable: true)
        for _ in 0..<4 { gate.handleAutoCreateDidRun(["outcome": "unchanged", "created": 0]) }
        precondition(host.presents == 0, "Background resolution forced pairing open")
        let readiness = KeyReadinessFixture()
        precondition(readiness.profileSyncInfo(forProfileId: "local") == nil, "Unpaired device exposed resolved keys")
        readiness.paired = true
        precondition(readiness.profileSyncInfo(forProfileId: "local")?.uuid == "remote")
        let verified = SyncPairingLegacyEvidence(authorizedDeviceVerified: true,
            freshAccountMappingsVerified: true, explicitlyPending: false,
            spaceSectionEnabled: true, hasDrainedFullReplay: true,
            profileMappingsValid: true, spaceMappingsValid: true)
        let paired = SyncPairingRecord(version: 1, deviceKeyID: "a", paired: true)
        let bytes = try JSONEncoder().encode(paired)
        precondition(SyncPairingEligibility.isPaired(record: paired, deviceKeyID: "a"))
        precondition(!SyncPairingEligibility.isPaired(record: paired, deviceKeyID: "b"))
        precondition(!SyncPairingEligibility.isPaired(record: nil, deviceKeyID: "a"))
        var writes = 0
        var enrollment = SyncPairingEnrollment()
        try enrollment.configure(deviceKeyID: "a", recordData: bytes,
            saveRecord: { _ in writes += 1; return true })
        precondition(enrollment.isPaired && writes == 0)
        for bad in [Data("broken".utf8), try JSONEncoder().encode(
            SyncPairingRecord(version: 2, deviceKeyID: "a", paired: true)),
            try JSONEncoder().encode(SyncPairingRecord(version: 1, deviceKeyID: "b", paired: true))] {
            try enrollment.configure(deviceKeyID: "a", recordData: bad,
                saveRecord: { _ in writes += 1; return true }, legacyEvidence: verified)
            precondition(!enrollment.isPaired && writes == 0)
        }
        try enrollment.configure(deviceKeyID: "a", recordData: nil,
            saveRecord: { _ in writes += 1; return true }, legacyEvidence: verified)
        precondition(enrollment.isPaired && writes == 1)
        precondition(enrollment.spaceReplayToken == nil, "Legacy migration must not demand a replay")
        try enrollment.setPaired(false)
        precondition(!enrollment.isPaired && writes == 2)
        try enrollment.configure(deviceKeyID: "a", recordData: nil, saveRecord: { _ in false })
        do {
            try enrollment.setPaired(true)
            preconditionFailure("Rejected persistence must throw")
        } catch SyncPairingPersistenceError.writeFailed {}
        precondition(!enrollment.isPaired)
        try enrollment.configure(deviceKeyID: "a", recordData: bytes, saveRecord: { _ in false })
        do {
            try enrollment.setPaired(false)
            preconditionFailure("Rejected unpair persistence must throw")
        } catch SyncPairingPersistenceError.writeFailed {}
        precondition(!enrollment.isPaired, "Invalidated enrollment must fail closed even if persistence fails")
        var rotatedRecord: Data?
        try enrollment.configure(deviceKeyID: "old", recordData: nil,
            saveRecord: { rotatedRecord = $0; return true })
        try enrollment.setPaired(true, verifiedDeviceKeyID: "new")
        try enrollment.configure(deviceKeyID: "new", recordData: rotatedRecord, saveRecord: { _ in true })
        precondition(enrollment.isPaired, "Completion must persist the verified post-registration identity")
        for index in 0..<7 {
            var flags = [true, true, false, true, true, true, true]
            flags[index].toggle()
            let evidence = SyncPairingLegacyEvidence(authorizedDeviceVerified: flags[0],
                freshAccountMappingsVerified: flags[1], explicitlyPending: flags[2],
                spaceSectionEnabled: flags[3], hasDrainedFullReplay: flags[4],
                profileMappingsValid: flags[5], spaceMappingsValid: flags[6])
            try enrollment.configure(deviceKeyID: "a", recordData: nil,
                saveRecord: { _ in preconditionFailure("Insufficient evidence must not migrate") },
                legacyEvidence: evidence)
            precondition(!enrollment.isPaired)
        }
        print("PASS pairing: device binding, invalid records, migration predicates, durable writes, withdrawn and re-enabled in-flight generations")
    }
}
