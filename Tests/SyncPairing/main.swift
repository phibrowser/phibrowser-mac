import Foundation

@main
struct PairingTests {
    @MainActor static func main() throws {
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
        let gate = ProfilePairingGate()
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
