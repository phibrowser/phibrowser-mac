// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

enum TimeMachineRollbackPolicyLoaderError: Error, LocalizedError {
    case missingPolicyURL
    case invalidPolicy(String)

    var errorDescription: String? {
        switch self {
        case .missingPolicyURL:
            return "Time Machine rollback policy URL is unavailable."
        case .invalidPolicy(let detail):
            return "Invalid Time Machine rollback policy: \(detail)"
        }
    }
}

struct TimeMachineRollbackPolicyLoader {
    private let policyURLProvider: () -> URL?
    private let fileManager: FileManager

    init(
        policyURLProvider: @escaping () -> URL? = {
            Bundle.main.url(forResource: "TimeMachineRollbackPolicy", withExtension: "json")
        },
        fileManager: FileManager = .default
    ) {
        self.policyURLProvider = policyURLProvider
        self.fileManager = fileManager
    }

    func loadPolicy() throws -> TimeMachineRollbackPolicy? {
        guard let url = policyURLProvider() else {
            return nil
        }
        guard fileManager.fileExists(atPath: url.path) else {
            return nil
        }

        let data = try Data(contentsOf: url)
        let policy = try JSONDecoder().decode(TimeMachineRollbackPolicy.self, from: data)
        try validate(policy)
        return policy
    }

    private func validate(_ policy: TimeMachineRollbackPolicy) throws {
        guard policy.backupTriggerBuild > 0 else {
            throw TimeMachineRollbackPolicyLoaderError.invalidPolicy("backupTriggerBuild must be positive.")
        }
        guard policy.rollbackBuild > 0 else {
            throw TimeMachineRollbackPolicyLoaderError.invalidPolicy("rollbackBuild must be positive.")
        }
        guard !policy.rollbackVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TimeMachineRollbackPolicyLoaderError.invalidPolicy("rollbackVersion must not be empty.")
        }
        guard !policy.rollbackPackageSHA256.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TimeMachineRollbackPolicyLoaderError.invalidPolicy("rollbackPackageSHA256 must not be empty.")
        }
        if let rollbackAppBundleName = policy.rollbackAppBundleName,
           !TimeMachineAppBundleName.isValid(rollbackAppBundleName) {
            throw TimeMachineRollbackPolicyLoaderError.invalidPolicy(
                "rollbackAppBundleName must be a top-level .app bundle name."
            )
        }
    }
}
