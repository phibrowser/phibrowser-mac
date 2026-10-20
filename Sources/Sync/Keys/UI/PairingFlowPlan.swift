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
    /// Whether the "sync method" step (merge or use the account's data) can show. While false, the plan never
    /// shows it, whatever the facts say.
    static let methodStepEnabled = true

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

    /// Whether the method step's primary button finishes setup instead of continuing: merging, with no
    /// Profiles or Spaces page after it. "Use your account's data" always continues to its confirmation.
    func finishesAtMethodStep(for method: SyncMethod) -> Bool {
        method == .merge && steps(for: .merge) == [.method]
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
        if defaultNeedsChoice(locals: locals, remotes: remotes) { return true }
        // Defensive: a readable unclaimed Profile that cannot be created here needs an explicit assignment.
        return model.unclaimedRemotes.contains { $0.name != nil && !model.offersCreateLocal(for: $0) }
    }

    /// The local Default is unmapped, has no readable account default to be fixed to, and some account
    /// Profile exists (readable or not). Registering it automatically could mint a second account default.
    static func defaultNeedsChoice(locals: [PairingLocal], remotes: [RemoteProfile]) -> Bool {
        guard locals.contains(where: \.isDefault), !remotes.isEmpty else { return false }
        let model = ProfilePairingModel(locals: locals, remotes: remotes, selections: [:], remoteChoices: [:])
        return model.fixedDefaultRemote == nil
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
    ///     be proven.
    static func localHasReplaceableData(localProfileIds: [String], localSpaces: [PhiLocalSpace],
                                        ownedItemsPresent: Bool?) -> Bool {
        localProfileIds.contains { $0 != LocalStore.defaultProfileId }
            || localSpaces.contains { $0.spaceId != LocalStore.defaultSpaceId }
            || (ownedItemsPresent ?? true)
    }

    /// Whether the local reset's inventory holds any bookmark, folder, pinned tab or URL rule; nil when the
    /// inventory could not be read.
    static func ownedItemsPresent(_ inventory: LocalPhiInventory?) -> Bool? {
        inventory.map { $0.bookmarks + $0.bookmarkFolders + $0.pinnedTabs + $0.urlRules > 0 }
    }

    // MARK: - Replacing this Mac's data

    /// The unmapped local Profiles the account has no Profile for: non-default and not matched by name.
    /// "Use your account's data" deletes every one of them from this Mac; whoever wants to keep one merges.
    static func extraLocals(locals: [PairingLocal], remotes: [RemoteProfile]) -> [PairingLocal] {
        let initial = ProfilePairingModel.initialSelections(locals: locals, remotes: remotes)
        return locals.filter { !$0.isDefault && initial[$0.profileId] == .registerNew }
    }

    /// The Profile decisions of "use your account's data": the Default and same-name Profiles adopt their
    /// account match, every readable unclaimed account Profile is created on this Mac, and the Profiles
    /// being deleted get no decision (the local reset deletes them). A new replace deletes every extra
    /// Profile; a resumed one deletes only its marker's Profiles, so an extra Profile created after the
    /// marker was written registers instead.
    static func replaceDecisions(locals: [PairingLocal], remotes: [RemoteProfile],
                                 deleting deleteProfileIds: Set<String>) -> [PairingDecision] {
        let kept = locals.filter { !deleteProfileIds.contains($0.profileId) }
        let selections = ProfilePairingModel.initialSelections(locals: kept, remotes: remotes)
        let remoteChoices = autoRemoteChoices(locals: kept, remotes: remotes, selections: selections)
        return ProfilePairingModel(locals: kept, remotes: remotes, selections: selections,
                                   remoteChoices: remoteChoices).decisions()
    }
}

/// The confirmation page of "use your account's data": what leaves this Mac, including the local
/// Profiles it deletes, and what the account brings.
struct ReplaceLocalReview: Equatable {
    /// What the local reset removes. `profiles` is the number of `extraLocals`.
    var removed: PairingDataSummary.Counts
    /// What the first sync downloads from the account.
    var downloaded: PairingDataSummary.Counts
    /// The local Profiles the replace deletes, named in the "Removed from this Mac" card: every extra local
    /// Profile (see `PairingFlowPlan.extraLocals`), or, for a resumed replace, the marker's Profiles still
    /// on this Mac.
    var extraLocals: [PairingLocal]
    /// The local Default has no readable account default to adopt (see `PairingFlowPlan.defaultNeedsChoice`),
    /// so replacing cannot start: registering the Default could mint a second account default.
    var defaultUnavailable: Bool
}
