// Copyright 2026 Phinomenon Inc.
import Foundation

struct SyncPairingRecord: Codable, Equatable {
    let version: Int
    let deviceKeyID: String
    let paired: Bool
}

struct SyncPairingLegacyEvidence {
    let authorizedDeviceVerified: Bool
    let freshAccountMappingsVerified: Bool
    let explicitlyPending: Bool
    let spaceSectionEnabled: Bool
    let hasDrainedFullReplay: Bool
    let profileMappingsValid: Bool
    let spaceMappingsValid: Bool

    var provesCompletion: Bool {
        authorizedDeviceVerified && freshAccountMappingsVerified && !explicitlyPending
            && spaceSectionEnabled && hasDrainedFullReplay && profileMappingsValid && spaceMappingsValid
    }
}

enum SyncPairingEligibility {
    static func isPaired(record: SyncPairingRecord?, deviceKeyID: String) -> Bool {
        guard let record, !deviceKeyID.isEmpty else { return false }
        return record.version == 1 && record.deviceKeyID == deviceKeyID && record.paired
    }
}

enum SyncPairingPersistenceError: Error { case writeFailed }

/// A value owned by ProfilePairingGate. Writes target the account captured at configuration,
/// never whichever account happens to be active when a delayed operation finishes.
struct SyncPairingEnrollment {
    private var deviceKeyID = ""
    private var record: SyncPairingRecord?
    private var saveRecord: ((Data) -> Bool)?

    var isPaired: Bool { SyncPairingEligibility.isPaired(record: record, deviceKeyID: deviceKeyID) }

    mutating func configure(deviceKeyID: String, recordData: Data?,
                            saveRecord: @escaping (Data) -> Bool,
                            legacyEvidence: SyncPairingLegacyEvidence? = nil) throws {
        self = SyncPairingEnrollment()
        self.deviceKeyID = deviceKeyID
        self.saveRecord = saveRecord
        if let recordData {
            record = try? JSONDecoder().decode(SyncPairingRecord.self, from: recordData)
        } else if legacyEvidence?.provesCompletion == true {
            try setPaired(true)
        }
    }

    mutating func setPaired(_ paired: Bool, verifiedDeviceKeyID: String? = nil) throws {
        if let verifiedDeviceKeyID { deviceKeyID = verifiedDeviceKeyID }
        // Revocation or invalid legacy state must stop this process even if disk writes fail.
        if !paired { record = nil }
        guard !deviceKeyID.isEmpty, let saveRecord else { throw SyncPairingPersistenceError.writeFailed }
        let candidate = SyncPairingRecord(version: 1, deviceKeyID: deviceKeyID, paired: paired)
        guard saveRecord(try JSONEncoder().encode(candidate)) else {
            throw SyncPairingPersistenceError.writeFailed
        }
        record = candidate
    }
}

extension Notification.Name {
    static let phiSyncPairingStateDidChange = Notification.Name("phiSyncPairingStateDidChange")
}
