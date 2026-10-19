// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

/// How this Mac joins an account that already holds data.
enum SyncMethod: Equatable {
    /// Keep this Mac's data and combine it with the account's (the Profile and Space matching pages).
    case merge
    /// Replace this Mac's Phi data with the account's.
    case useAccount
}

/// Everything the wizard's page plan depends on, computed once per load by `PairingWizardViewModel` from the
/// loaded candidates and the Space preview. Pure values only, so `PairingFlowPlan.make` stays a total function
/// that tests can drive with a table.
struct PairingFlowFacts: Equatable {
    /// This flow created the account, and the account has no Profiles and no Spaces yet.
    var isBrandNewAccount: Bool
    /// The Space preview read every entity (`skippedEntityCount == 0`).
    var previewComplete: Bool
    /// This Mac holds Phi data that "use the account's data" would remove.
    var localHasReplaceableData: Bool
    /// The Profiles page has a choice the user must make.
    var profilesNeedDecision: Bool
    /// The Profiles page would list anything: an unmapped local Profile or a readable unclaimed account
    /// Profile. Only consulted when the preview is incomplete.
    var profilesHaveRows: Bool
    /// The Spaces page has at least one row to decide.
    var spacesNeedDecision: Bool
}

/// Which wizard pages show for one load, replacing the separate skip conditions that used to live in
/// `PairingWizardViewModel.start`. A page shows only when it asks the user something; when no page shows,
/// the wizard completes on its own behind the status page (see docs/sync.md, "Pairing page plan").
struct PairingFlowPlan: Equatable {
    /// The "sync method" step (merge or use the account's data) is not built yet: while false, the plan never
    /// shows it, whatever the facts say.
    static let methodStepEnabled = false

    let showsMethod: Bool
    let showsProfiles: Bool
    let showsSpaces: Bool

    /// Nothing to ask: the wizard applies its automatic decisions and finishes without showing a page.
    var autoCompletes: Bool { !showsMethod && !showsProfiles && !showsSpaces }

    /// - Parameter methodStepEnabled: injectable so tests can cover the enabled planner before the step ships.
    static func make(_ facts: PairingFlowFacts,
                     methodStepEnabled: Bool = PairingFlowPlan.methodStepEnabled) -> PairingFlowPlan {
        // A brand-new account has nothing to match against: every local Profile registers and every local
        // Space is added as new.
        guard !facts.isBrandNewAccount else {
            return PairingFlowPlan(showsMethod: false, showsProfiles: false, showsSpaces: false)
        }
        // An incomplete preview never completes on its own, and never decides Profiles automatically: it shows
        // the Profiles page whenever that page has rows, and otherwise at least the Spaces page.
        let incomplete = !facts.previewComplete
        return PairingFlowPlan(
            showsMethod: methodStepEnabled && facts.localHasReplaceableData,
            showsProfiles: facts.profilesNeedDecision || (incomplete && facts.profilesHaveRows),
            showsSpaces: facts.spacesNeedDecision || (incomplete && !facts.profilesHaveRows))
    }

    /// The pages the step bar lists for a method, in order.
    func steps(for method: SyncMethod) -> [PairingWizardStep] {
        switch method {
        case .merge:
            var steps: [PairingWizardStep] = []
            if showsMethod { steps.append(.method) }
            if showsProfiles { steps.append(.profiles) }
            if showsSpaces { steps.append(.spaces) }
            return steps
        case .useAccount:
            return [.method, .confirm]
        }
    }

    /// The same plan with the Profiles page shown. Used when the wizard has to put the Profiles page in front
    /// of the user after all: a submission found changed or failed Profile candidates.
    func revealingProfiles() -> PairingFlowPlan {
        PairingFlowPlan(showsMethod: showsMethod, showsProfiles: true, showsSpaces: showsSpaces)
    }

    // MARK: - Predicates

    static func isBrandNewAccount(createdByThisFlow: Bool, previewComplete: Bool,
                                  remotes: [RemoteProfile], accountSpaces: [PhiAccountSpaceSummary]) -> Bool {
        createdByThisFlow && previewComplete && remotes.isEmpty && accountSpaces.isEmpty
    }

    /// Whether the Profiles page asks anything. `locals` are this Mac's unmapped Profiles and `remotes` the
    /// account's unclaimed live ones, as the wizard loaded them.
    static func profilesNeedDecision(locals: [PairingLocal], remotes: [RemoteProfile]) -> Bool {
        // A non-default local Profile can match, register, or be assigned: always the user's call.
        if locals.contains(where: { !$0.isDefault }) { return true }
        let model = ProfilePairingModel(locals: locals, remotes: remotes,
                                        selections: ProfilePairingModel.initialSelections(locals: locals,
                                                                                          remotes: remotes),
                                        remoteChoices: [:])
        // The local Default with no readable account default, beside any account Profile: it either gets a
        // real picker over legacy Profiles, or the account default may be one whose envelope does not open
        // yet. Registering automatically could mint a second account default, so the user sees the page
        // (Finish later stays available while the unreadable envelope is retried).
        if locals.contains(where: \.isDefault), model.fixedDefaultRemote == nil, !remotes.isEmpty {
            return true
        }
        // Defensive: a readable unclaimed Profile that cannot be created here needs an explicit assignment.
        return model.unclaimedRemotes.contains { $0.name != nil && !model.offersCreateLocal(for: $0) }
    }

    static func profilesHaveRows(locals: [PairingLocal], remotes: [RemoteProfile]) -> Bool {
        !locals.isEmpty || remotes.contains { $0.name != nil }
    }

    /// The decisions the hidden Profiles page stands for: every readable account Profile nobody claimed is
    /// created on this Mac. The authoritative account default is never offered "create", so it is skipped.
    static func autoRemoteChoices(locals: [PairingLocal], remotes: [RemoteProfile],
                                  selections: [String: ProfilePairingModel.Choice])
    -> [String: ProfilePairingModel.RemoteChoice] {
        let model = ProfilePairingModel(locals: locals, remotes: remotes, selections: selections,
                                        remoteChoices: [:])
        var choices: [String: ProfilePairingModel.RemoteChoice] = [:]
        for remote in model.unclaimedRemotes where remote.name != nil && model.offersCreateLocal(for: remote) {
            choices[remote.uuid] = .createLocal
        }
        return choices
    }

    /// The Spaces page has a row for every non-default local Space.
    static func spacesNeedDecision(_ input: SpacePairingModel.Input) -> Bool {
        !SpacePairingModel(input: input, selections: [:]).rows.isEmpty
    }

    /// Whether this Mac holds Phi data beyond what a fresh install seeds (the default Space, the Default
    /// Profile and empty bookmark roots).
    ///
    /// - Parameters:
    ///   - localProfileIds: every user-assignable local Profile, mapped or not (the agent fallback Profile is
    ///     never in this list).
    ///   - localSpaces: the pairable local Spaces (agent and Incognito Spaces are never in this list).
    ///   - ownedItemsPresent: whether any bookmark, pinned tab or URL rule exists. nil means unknown: the
    ///     inventory is not available or could not be read. Unknown counts as data, because emptiness cannot
    ///     be proven; this only matters once the method step is enabled.
    static func localHasReplaceableData(localProfileIds: [String], localSpaces: [PhiLocalSpace],
                                        ownedItemsPresent: Bool?) -> Bool {
        localProfileIds.contains { $0 != LocalStore.defaultProfileId }
            || localSpaces.contains { $0.spaceId != LocalStore.defaultSpaceId }
            || (ownedItemsPresent ?? true)
    }
}
