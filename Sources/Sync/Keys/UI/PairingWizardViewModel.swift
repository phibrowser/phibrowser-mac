// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Combine
import Foundation

/// The wizard's pages as the step bar names them. `.method` chooses merge or "use your account's data";
/// `.confirm` is the latter's confirmation page, which its status and error pages keep marked.
enum PairingWizardStep: Equatable { case method, profiles, spaces, confirm }

/// Retry destinations from error. No backToConfirm: resume describes a recomputable destination (reload,
/// retained step-2 selections, or the replace sequence) rather than remembering the source page.
enum ErrorResume: Equatable {
    /// At least one of the two loads failed in start(); Retry reruns start().
    case reload
    /// Submission failed on step-2 Space decisions. Retry returns to spaces with both steps' selections
    /// intact; the user presses Finish again, and idempotency makes replay safe.
    case backToSpaces
    /// "Use your account's data" stopped part-way. Retry runs the replace sequence again; every step of it
    /// is idempotent, so it picks up where it stopped.
    case resumeReplace
}

enum PairingWizardPhase: Equatable {
    case loading
    case profiles(locals: [PairingLocal], remotes: [RemoteProfile])
    case spaces(SpacePairingModel.Input)
    /// D7 / R-D7-1 confirmation after step 2 and before submission. Carries computed differences, not
    /// selections; spaceSelections remains the sole mutable state, so Back restores nothing. Empty arrays are
    /// invalid because Finish skips confirmation without differences.
    case confirmOverwrite([SpaceOverwriteDiff])
    /// The sync method step: merge, or replace this Mac's data with the account's.
    case method(PairingDataSummary)
    /// Confirmation of "use your account's data", naming the extra local Profiles it deletes.
    case confirmReplaceLocal(ReplaceLocalReview)
    /// The replace sequence is running (its own status page, so switches over phases stay exhaustive).
    case replacingLocal
    case submitting
    case done
    case error(message: String, resume: ErrorResume)
}

/// Centralized wizard strings shared by KeyLayerViewModel's two R12 replacements. Each English key uses the
/// same catalog entry/comment to avoid conflicting generated comments.
enum PairingWizardStrings {
    static let profileLoadFailed = NSLocalizedString("sync.pairing.error.profileLoadFailed",
        value: "Couldn’t load your account’s profiles. Check your connection and retry.",
        comment: "Sync setup - error shown when the account's profiles could not be loaded")
    static let profileDecisionFailed = NSLocalizedString("sync.pairing.error.profileApplyFailed",
        value: "Couldn’t apply one of your profile choices. Check your connection and retry.",
        comment: "Sync setup - error shown when one profile match could not be applied")
    static let previewUnavailable = NSLocalizedString("sync.pairing.error.syncUnavailable",
        value: "Sync isn’t available right now, so your account’s Spaces couldn’t be loaded.",
        comment: "Sync setup - error shown when sync is unavailable so the account's Spaces cannot be loaded")
    static let previewFailed = NSLocalizedString("sync.pairing.error.spaceLoadFailed",
        value: "Couldn’t load your account’s Spaces. Check your connection and retry.",
        comment: "Sync setup - error shown when the account's Spaces could not be loaded")
    static let previewTruncated = NSLocalizedString("sync.pairing.error.spaceLoadIncomplete",
        value: "Couldn’t load all of your account’s Spaces. Check your connection and retry.",
        comment: "Sync setup - error shown when only part of the account's Spaces could be loaded")
    static let previewTimedOut = NSLocalizedString("sync.pairing.error.spaceLoadTimedOut",
        value: "Couldn’t load your account’s Spaces in time. Check your connection and retry.",
        comment: "Sync setup - error shown when the account's Spaces did not load in time")
    static let applyFailed = NSLocalizedString("sync.pairing.error.applyFailed",
        value: "Couldn’t finish setting up sync. Nothing was lost — check your connection and retry.",
        comment: "Sync setup - error shown when the chosen matches could not be applied")
    static let replaceLocalFailed = NSLocalizedString("sync.pairing.error.replaceLocalFailed",
        value: "Couldn’t finish replacing this Mac’s data. Retry picks up where it stopped — nothing else changes until it’s done.",
        comment: "Sync setup - error shown when removing this Mac's data before downloading the account's data stopped part-way")
}

/// Result.Failure must conform to Error; String does not. Wrap the message that will be rendered.
private struct PairingWizardLoadFailure: Error { let message: String }

/// One-shot gate between preview and deadline: the first finisher resumes the continuation; the second is a
/// no-op.
///
/// Do not use withTaskGroup: groups await every child, but PhiSyncEngine.serialized runs an unstructured Task
/// that does not inherit cancellation, awaits a nonthrowing task.value, and runPreview checks isStopped rather
/// than Task.isCancelled. cancelAll would not stop that work, so the deadline would change the result without
/// changing when loading ends.
///
/// The abandoned preview safely finishes in the engine queue: §4.3 forbids persistence, and its own
/// previewDeadlineMs budget eventually stops it.
private final class PreviewRace: @unchecked Sendable {
    typealias Outcome = Result<PhiAccountSpacePreview, PhiSpacePreviewError>?

    private let lock = NSLock()
    private var continuation: CheckedContinuation<Outcome, Never>?

    init(_ continuation: CheckedContinuation<Outcome, Never>) {
        self.continuation = continuation
    }

    /// nil means the deadline won.
    func finish(_ outcome: Outcome) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: outcome)
    }
}

/// State machine for the two-step pairing wizard plus D7 confirmation (§5.2 / §5.5). Own a separate phase
/// enum; never write KeyLayerPhase (R-D6-11), whose second writer caused the modal to stick in working. Read
/// keyLayer.phase only for pairingProfiles payload after loading and freshly reloaded candidates after
/// applyPairingDecisions returns false.
@MainActor
final class PairingWizardViewModel: ObservableObject {
    @Published private(set) var phase: PairingWizardPhase = .loading
    @Published private(set) var step: PairingWizardStep = .profiles
    /// Which pages this load shows; nil until both loads succeed. See PairingFlowPlan.
    @Published private(set) var plan: PairingFlowPlan?

    /// The method the user picked on the sync method step. `.merge` unless the step shows and the user
    /// picks otherwise, or a replace that already started is resumed (`methodLocked`).
    @Published var selectedMethod: SyncMethod = .merge
    /// A replace already started (its resume marker exists): the method cannot change and the confirmation
    /// page offers no Back.
    @Published private(set) var methodLocked = false
    /// The confirmation page's content while "use your account's data" is selected past the method step.
    @Published private(set) var replaceReview: ReplaceLocalReview?

    /// The pages the step bar lists, in order. Empty while loading and when the wizard completes on its own.
    var visibleSteps: [PairingWizardStep] { plan?.steps(for: selectedMethod) ?? [] }

    /// Back from the Spaces page exists only when the Profiles page is shown.
    var canGoBackToProfiles: Bool { plan?.showsProfiles ?? true }

    /// The Spaces page offers Back when there is a page before it: Profiles, or the method step.
    var canGoBackFromSpaces: Bool { canGoBackToProfiles || plan?.showsMethod == true }

    /// The method step is shown and not locked, so the pages after it can return to it.
    var canGoBackToMethod: Bool { !methodLocked && plan?.showsMethod == true }

    /// The method step's primary button reads Finish (nothing follows a merge) rather than Continue.
    var methodStepFinishes: Bool { plan?.finishesAtMethodStep(for: selectedMethod) ?? false }

    /// "Use your account's data" is offered: the local data reset is wired for this load. Without it the
    /// method step is not shown and its second card is hidden, so Retry can never loop on a reset that
    /// cannot run.
    @Published private(set) var replaceAvailable = false

    /// The confirmation page's Replace is available: nothing is running, the reset is wired and the
    /// account's default Profile can be adopted.
    var canReplace: Bool {
        sessionActive && !isApplying && !isPreparing && replaceAvailable
            && replaceReview.map { !$0.defaultUnavailable } == true
    }

    /// Lift step-1 mutable state from ProfilePairingView into bindings (§5.3), allowing the footer to read
    /// allRowsDecided inputs and decisions after moving the primary button.
    @Published var profileSelections: [String: ProfilePairingModel.Choice] = [:]
    @Published var profileRemoteChoices: [String: ProfilePairingModel.RemoteChoice] = [:]
    /// Step 2's sole mutable state, retained through Back/Continue and error → Retry.
    @Published private(set) var spaceSelections: [String: SpacePairingModel.Assignment] = [:]

    /// Mirror submission state on this observed wizard VM. The view neither observes keyLayer.isSubmitting
    /// changes nor can rely on it after applyPairingDecisions clears it in defer. Footer logic must use this
    /// property, never restore cross-object reads (§6.5; PairingWizardView.actions).
    @Published private(set) var isApplying = false

    /// Created by the wizard (moved from AppModalPairingHost.present); this reference is read-only.
    let keyLayer: KeyLayerViewModel

    private let previewAccountSpaces: () async -> Result<PhiAccountSpacePreview, PhiSpacePreviewError>
    private let pairableLocalSpaces: () -> [PhiLocalSpace]
    private let themeDisplayName: (String) -> String?
    private let loadDeadline: Duration
    /// The local data reset bound to the controller, or nil when unavailable (docs/sync.md, "Replacing this
    /// Mac's data at pairing"). Read for the inventory on every load and used by `replaceLocal`.
    private let localReset: @MainActor (SyncKeyController) -> (any LocalPhiResetting)?
    /// `PairingFlowPlan.methodStepEnabled` unless a test pins it.
    private let methodStepEnabled: Bool

    /// Default shared with init and exactly equal to PhiSyncEngine.previewDeadlineMs; both deadlines must
    /// match (see loadAccountSpaces). Raising only one lets UI abandon a still-paging preview occupying the
    /// round queue. Expose a static value so tests can pin the default.
    ///
    /// nonisolated is required because default arguments evaluate in a nonisolated context, otherwise Swift 6
    /// rejects this MainActor type's default. Duration is an immutable Sendable value.
    nonisolated static let defaultLoadDeadline: Duration =
        .milliseconds(PhiSyncEngine.previewDeadlineMs)

    /// Generation for start(). reloadAllowed deliberately permits restarting loading, so overlapping loads are
    /// normal: reloadPresented calls start directly, bypassing retry's error guard. Without generation checks,
    /// a canceled first profile load could overwrite a healthy second load with error, or an older preview
    /// could reset completed user choices and return to profiles.
    ///
    /// As with KeyLayerViewModel.runPairingLoad cancellation checks, every write after either await must first
    /// confirm this is the newest load.
    private var loadGeneration = 0
    private var sessionActive = false
    var shouldCompleteNewAccount = false
    @Published private(set) var isPreparing = false
    private let gate: ProfilePairingGate
    private var enrollmentGeneration: UUID?

    var canSubmit: Bool {
        sessionActive && !isApplying && !isPreparing && profileRowsDecided && spaceModel.allRowsDecided
    }

    @discardableResult
    func leaveWithoutApplying() -> Bool {
        guard !isApplying else { return false }
        sessionActive = false
        loadGeneration += 1
        keyLayer.cancelPairingLoad()
        profileSelections = [:]
        profileRemoteChoices = [:]
        spaceSelections = [:]
        identitySpaceSelections = [:]
        mappedProfileUuids = [:]
        explicitSpaceChoices = []
        loadedLocals = []
        loadedRemotes = []
        profileDecisions = []
        plan = nil
        resetMethodState()
        spacesInput = SpacePairingModel.Input(locals: [], accountSpaces: [], localProfileNames: [:], accountProfileNames: [:])
        return true
    }

    /// The sync method step's state, discarded by every load and by leaving. The resume marker is not
    /// touched: a replace that already started resumes on the next load.
    private func resetMethodState() {
        selectedMethod = .merge
        methodLocked = false
        replaceReview = nil
        methodSummary = nil
        localInventory = nil
        lockedDeleteProfileIds = []
        replaceExpectedExtraIds = []
        replaceAvailable = false
    }

    private func sessionIsCurrent(_ controller: SyncKeyController) -> Bool {
        sessionActive && !controller.isRetired && enrollmentGeneration == gate.enrollmentGeneration
    }

    private var previewSkippedEntityCount = 0
    /// Tombstone tag hashes from the latest preview; account Profiles deleted on another device
    /// are not offered (docs/sync.md, "Profile entity").
    private var previewDeletedProfileTagHashes: Set<String> = []
    /// Account names from the latest preview's live Profile entities, by uuid (see `liveRemotes`).
    private var previewProfileNames: [String: String] = [:]
    /// The account's bookmark, pinned tab and URL rule counts from the latest preview; nil when the
    /// preview could not count a kind.
    private var previewItemCounts: (bookmarks: Int?, pinnedTabs: Int?, urlRules: Int?) = (nil, nil, nil)
    private var loadedLocals: [PairingLocal] = []
    private var loadedRemotes: [RemoteProfile] = []
    private var profileDecisions: [PairingDecision] = []
    private var mappedProfileUuids: [String: String] = [:]
    private var identitySpaceSelections: [String: SpacePairingModel.Assignment] = [:]
    private var explicitSpaceChoices: Set<String> = []
    private var spacesInput = SpacePairingModel.Input(locals: [], accountSpaces: [],
                                                      localProfileNames: [:],
                                                      accountProfileNames: [:])
    /// The method step's counts, kept for Back.
    private var methodSummary: PairingDataSummary?
    /// The local reset's inventory from the latest load; nil when it could not be read.
    private var localInventory: LocalPhiInventory?
    /// The Profiles a started replace deletes (from its resume marker), used while `methodLocked`.
    private var lockedDeleteProfileIds: Set<String> = []
    /// The extra local Profiles the confirmation page was built from, minus those already registered by a
    /// replace attempt. The replace preflight compares the account's current extras against this set.
    private var replaceExpectedExtraIds: Set<String> = []

    init(keyLayer: KeyLayerViewModel,
         previewAccountSpaces: @escaping () async -> Result<PhiAccountSpacePreview, PhiSpacePreviewError>,
         pairableLocalSpaces: @escaping () -> [PhiLocalSpace],
         themeDisplayName: @escaping (String) -> String?,
         loadDeadline: Duration = PairingWizardViewModel.defaultLoadDeadline,
         gate: ProfilePairingGate? = nil,
         localReset: @escaping @MainActor (SyncKeyController) -> (any LocalPhiResetting)? = { _ in nil },
         methodStepEnabled: Bool = PairingFlowPlan.methodStepEnabled) {
        self.gate = gate ?? .shared
        self.keyLayer = keyLayer
        self.previewAccountSpaces = previewAccountSpaces
        self.pairableLocalSpaces = pairableLocalSpaces
        self.themeDisplayName = themeDisplayName
        self.loadDeadline = loadDeadline
        self.localReset = localReset
        self.methodStepEnabled = methodStepEnabled
    }

    // MARK: - Derived models

    var profileModel: ProfilePairingModel {
        ProfilePairingModel(locals: loadedLocals, remotes: loadedRemotes,
                            selections: profileSelections, remoteChoices: profileRemoteChoices)
    }

    var spaceModel: SpacePairingModel {
        SpacePairingModel(input: spacesInput, selections: spaceSelections)
    }

    /// Step-1 enablement exactly reuses KeyLayerViewModel.allRowsDecided.
    var profileRowsDecided: Bool {
        let live = profileModel
        return keyLayer.allRowsDecided(remotes: loadedRemotes,
                                       claimedRemoteUuids: live.claimedRemoteUuids,
                                       createLocalUuids: live.createLocalUuids)
    }

    // MARK: - Sole host entry point

    func start(controller: SyncKeyController) async {
        guard !isApplying, !controller.isRetired else { return }
        sessionActive = true
        enrollmentGeneration = gate.enrollmentGeneration
        profileSelections = [:]
        profileRemoteChoices = [:]
        spaceSelections = [:]
        identitySpaceSelections = [:]
        mappedProfileUuids = [:]
        explicitSpaceChoices = []
        profileDecisions = []
        previewSkippedEntityCount = 0
        previewDeletedProfileTagHashes = []
        previewProfileNames = [:]
        previewItemCounts = (nil, nil, nil)
        plan = nil
        resetMethodState()
        loadGeneration += 1
        let generation = loadGeneration
        phase = .loading
        // Start independent loads concurrently, but require both before profiles: step 2 needs account data,
        // and discovering its absence after step-1 decisions would waste the user's work.
        async let profileLoad: Void = keyLayer.startPairing(controller: controller)
        async let spaceLoad = loadAccountSpaces()
        await profileLoad

        // First action after each await: confirm the newest generation before writing anything (see
        // loadGeneration).
        guard generation == loadGeneration, sessionIsCurrent(controller) else {
            AppLogInfo("[phi-sync] pairing wizard: a superseded load finished; dropping its result")
            return
        }

        // Report profile failure immediately instead of waiting up to 120 s for a preview that cannot make
        // this page succeed. Leaving scope still cancels/awaits async-let spaceLoad, so the Task may live
        // until preview ends, but Published phase already shows error and callers do not await start's result.
        // Preview cancellation cannot stop its work (see PreviewRace); abandoning it is safe because §4.3
        // forbids persistence.
        guard case .pairingProfiles(let locals, let accountRemotes) = keyLayer.phase else {
            let message: String
            if case .error(let existing) = keyLayer.phase { message = existing }
            else { message = PairingWizardStrings.profileLoadFailed }
            phase = .error(message: message, resume: .reload)
            return
        }

        let spaces = await spaceLoad
        guard generation == loadGeneration, sessionIsCurrent(controller) else {
            AppLogInfo("[phi-sync] pairing wizard: a superseded load finished; dropping its result")
            return
        }
        switch spaces {
        case .failure(let failure):
            phase = .error(message: failure.message, resume: .reload)
        case .success(let preview):
            let accountSpaces = preview.spaces
            previewSkippedEntityCount = preview.skippedEntityCount
            previewDeletedProfileTagHashes = preview.deletedProfileTagHashes
            previewProfileNames = preview.profileNames
            previewItemCounts = (preview.bookmarkCount, preview.pinnedTabCount, preview.urlRuleCount)
            let remotes = liveRemotes(accountRemotes)
            loadedLocals = locals
            loadedRemotes = remotes
            reseedProfileSelections(locals: locals, remotes: remotes)
            spacesInput = makeSpacesInput(accountSpaces: accountSpaces, remotes: remotes,
                                          controller: controller)
            seedSpaceSelections(controller: controller)
            step = .profiles
            let plan = makePlan(locals: locals, remotes: remotes, accountSpaces: accountSpaces,
                                controller: controller)
            self.plan = plan
            if let marker = controller.pairingLocalResetMarker() {
                // A replace already started on this device key: resume it rather than offer a merge, which
                // would union the leftovers of a partial reset into the account.
                resumeReplace(deleting: marker.deleteProfileIds, controller: controller)
            } else if plan.showsMethod {
                // Includes a method-only plan, which does not complete on its own.
                let summary = methodSummary ?? makeSummary(controller: controller)
                step = .method
                phase = .method(summary)
                logStep()
            } else if plan.showsProfiles {
                phase = .profiles(locals: locals, remotes: remotes)
                logStep()
            } else {
                // The hidden Profiles page stands for its automatic decisions: every readable account Profile
                // nobody claimed is created on this Mac (docs/sync.md, "Pairing page plan").
                profileRemoteChoices = PairingFlowPlan.autoRemoteChoices(
                    locals: locals, remotes: remotes, selections: profileSelections)
                if plan.autoCompletes {
                    await submitWithoutSpacesPage(controller: controller)
                } else {
                    continueToSpaces()      // Logs the step.
                    if step != .spaces { revealProfilesPage() }
                }
            }
        }
    }

    // MARK: - Sync method step

    /// The method step's primary action. Merge enters the merge pages the plan shows (or finishes when there
    /// are none); "use your account's data" opens its confirmation page. Nothing is written here.
    func continueFromMethod(controller: SyncKeyController) async {
        guard case .method = phase, sessionActive, !isPreparing, !isApplying else { return }
        switch selectedMethod {
        case .useAccount:
            showReplaceReview(controller: controller)
        case .merge:
            guard let plan else { return }
            if plan.showsProfiles {
                step = .profiles
                phase = .profiles(locals: loadedLocals, remotes: loadedRemotes)
                logStep()
                return
            }
            // The hidden Profiles page stands for its automatic decisions (docs/sync.md, "Pairing page plan").
            profileRemoteChoices = PairingFlowPlan.autoRemoteChoices(
                locals: loadedLocals, remotes: loadedRemotes, selections: profileSelections)
            if plan.showsSpaces {
                continueToSpaces()      // Logs the step.
                if step != .spaces { revealProfilesPage() }
            } else {
                await submitWithoutSpacesPage(controller: controller)
            }
        }
    }

    /// Back to the method step from the first merge page or the confirmation page. Selections made on the
    /// later pages stay. Refused while locked to a started replace.
    func backToMethod() {
        guard !isPreparing, !isApplying, canGoBackToMethod, let methodSummary else { return }
        step = .method
        phase = .method(methodSummary)
        logStep()
    }

    // MARK: - Step 1

    /// Continue only validates, freezes decisions and moves to spaces. No network, mapping writes or
    /// enrollment changes.
    func continueToSpaces() {
        guard canLeaveProfiles else { return }
        freezeProfileDecisions()
        step = .spaces
        phase = .spaces(spacesInput)
        logStep()
    }

    /// Continue's preconditions: decided rows, no submission in progress.
    private var canLeaveProfiles: Bool {
        sessionActive && !isPreparing && !isApplying && profileRowsDecided
    }

    /// Freezes the Profile decisions and recomputes Space suggestions from them, without changing the page.
    private func freezeProfileDecisions() {
        profileDecisions = profileModel.decisions()
        var profileMappings = mappedProfileUuids
        for decision in profileDecisions {
            if case .adopt(let localId, let remoteUuid) = decision { profileMappings[localId] = remoteUuid }
        }
        var base = identitySpaceSelections
        for id in explicitSpaceChoices { base[id] = spaceSelections[id] }
        spaceSelections = SpacePairingModel(input: spacesInput, selections: base)
            .suggestingSameNames(profileMappings: profileMappings, excluding: explicitSpaceChoices)
    }

    /// The Profiles page's primary action: Continue to the Spaces page, or Finish when that page is hidden.
    func continueFromProfiles(controller: SyncKeyController) async {
        guard plan?.showsSpaces == false else { continueToSpaces(); return }
        guard canLeaveProfiles else { return }
        await submitWithoutSpacesPage(controller: controller)
    }

    func backToProfiles() {
        guard !isPreparing, !isApplying else { return }
        // A hidden Profiles page is never navigated to: Back from the Spaces page then returns to the method
        // step when it shows, and is not offered otherwise (canGoBackFromSpaces).
        guard canGoBackToProfiles else { backToMethod(); return }
        step = .profiles
        phase = .profiles(locals: loadedLocals, remotes: loadedRemotes)
        logStep()
    }

    // MARK: - Step 2

    /// The only two mutators. D7 adds none: Back changes phase to spaces while selections remain intact.
    func assign(_ assignment: SpacePairingModel.Assignment?, to localSpaceId: String) {
        guard !isPreparing, !isApplying else { return }
        explicitSpaceChoices.insert(localSpaceId)
        var updated = spaceSelections
        if let assignment { updated[localSpaceId] = assignment }
        else { updated.removeValue(forKey: localSpaceId) }
        spaceSelections = updated
    }

    func addAllAsNew() {
        guard !isPreparing, !isApplying else { return }
        explicitSpaceChoices.formUnion(spaceModel.rows.filter { spaceModel.assignment(for: $0) == nil }.map(\.spaceId))
        spaceSelections = spaceModel.addAllAsNew()
    }

    // MARK: - Finish / confirmation / submission

    /// Step-2 Finish computes D7 differences locally before submitting. If any exist, show confirmation
    /// without writing anything.
    func finish(controller: SyncKeyController) async {
        guard canSubmit, sessionIsCurrent(controller) else { return }
        let diffs = SpaceOverwriteDiff.diffs(decisions: spaceModel.decisions(),
                                             locals: spacesInput.locals,
                                             accountSpaces: spacesInput.accountSpaces,
                                             themeDisplayName: themeDisplayName)
        // §9.1 item 3: log even empty diffs before the guard, the only trace of whether Finish showed
        // confirmation. R12 permits just two counts, no names, field names or old/new values.
        AppLogInfo("[phi-sync] pairing wizard overwrite: spaces=\(diffs.count) "
                   + "fields=\(diffs.reduce(0) { $0 + $1.changes.count })")
        guard diffs.isEmpty else { phase = .confirmOverwrite(diffs); return }
        await applyDecisions(controller: controller)
    }

    /// Confirmation exits. Back restores nothing because spaceSelections was never changed.
    func backFromConfirmation() {
        guard !isPreparing, !isApplying else { return }
        // Never to a hidden Spaces page: the previous shown page instead (Profiles, else the method step).
        guard plan?.showsSpaces == false else { phase = .spaces(spacesInput); return }
        backToProfiles()
    }

    func applyConfirmedOverwrite(controller: SyncKeyController) async {
        await applyDecisions(controller: controller)
    }

    /// Two Retry paths (§6.5), selected solely by resume.
    func retry(controller: SyncKeyController) async {
        guard case .error(_, let resume) = phase else { return }
        switch resume {
        case .reload:
            await start(controller: controller)
        case .backToSpaces:
            // Do not rerun start here: it clears spacesInput and step-2 assignments. Idempotent mapping writes
            // do not preserve user selections.
            guard plan?.showsSpaces != false else {
                // No Spaces page to return to: submit the same decisions again behind the status page.
                await submitWithoutSpacesPage(controller: controller)
                return
            }
            phase = .spaces(spacesInput)
        case .resumeReplace:
            await replaceLocal(controller: controller)
        }
    }

    /// The unchanged R-D6-3 submission sequence shared by no-diff Finish and confirmation Apply; no second
    /// application path is permitted.
    private func applyDecisions(controller: SyncKeyController) async {
        // Reject reentrant submission: both Task-based entry points can overlap on a double-click. Idempotency
        // requires sequential replay; concurrent createLocal/addAsNew could create a second profile/UUID.
        guard canSubmit, sessionIsCurrent(controller) else {
            AppLogInfo("[phi-sync] pairing wizard: a submit is already applying; ignoring the second one")
            return
        }
        isPreparing = true
        let valid = await validateCurrentReview(controller: controller)
        isPreparing = false
        guard valid, sessionIsCurrent(controller) else { return }
        phase = .submitting
        isApplying = true
        defer { isApplying = false }
        var spaceMaps = 0
        var spaceMints = 0

        // 1. Profile decisions.
        guard await keyLayer.applyPairingDecisions(profileDecisions, controller: controller) else {
            step = .profiles
            // Use the sole payload source: failed applyPairingDecisions reloads candidates via startPairing
            // into keyLayer.phase. This second phase read still never writes it.
            if case .pairingProfiles(let locals, let reloaded) = keyLayer.phase {
                let remotes = liveRemotes(reloaded)
                loadedLocals = locals
                loadedRemotes = remotes
                reseedProfileSelections(locals: locals, remotes: remotes)
                plan = plan?.revealingProfiles()
                phase = .profiles(locals: locals, remotes: remotes)
            } else {
                // Candidate reload also failed; Retry must rerun both loads.
                phase = .error(message: PairingWizardStrings.profileLoadFailed, resume: .reload)
            }
            logApplied(spaceMaps: spaceMaps, spaceMints: spaceMints, ok: false)
            return
        }

        guard sessionIsCurrent(controller) else { return }

        // Successful Profile decisions remove their rows from the next candidate load.
        // Advance that expected snapshot now: a later Space persistence failure must
        // not mistake our own confirmed progress for an external account change.
        loadedLocals = []
        loadedRemotes.removeAll { $0.name != nil }
        let mappedProfiles = makeSpacesInput(accountSpaces: spacesInput.accountSpaces,
                                             remotes: loadedRemotes, controller: controller)
        // Name lookup changes after adoption/creation. Keep both reviewed Space
        // snapshots unchanged so edits during Profile writes still require review.
        spacesInput = SpacePairingModel.Input(locals: spacesInput.locals,
            accountSpaces: spacesInput.accountSpaces,
            localProfileNames: mappedProfiles.localProfileNames,
            accountProfileNames: mappedProfiles.accountProfileNames)

        // 2. Space decisions write sync.spaceGlobalUuids mappings, not sync.phiSpaces state. The tables are
        // disjoint and the Space gate remains closed until step 3, so the engine cannot snapshot these
        // mappings concurrently. This permits direct main-actor writes without engine round scheduling (§5.6).
        do {
            guard pairableLocalSpaces() == spacesInput.locals else {
                throw SpaceSyncMappingError.alreadyMapped
            }
            for decision in spaceModel.decisions() {
                if try apply(decision, controller: controller) { spaceMints += 1 }
                else { spaceMaps += 1 }
            }
        } catch {
            // Stay on step 2; §5.1 idempotency makes retry safe.
            phase = .error(message: PairingWizardStrings.applyFailed, resume: .backToSpaces)
            logApplied(spaceMaps: spaceMaps, spaceMints: spaceMints, ok: false)
            return
        }

        // 3. Open the gate only after both Profile and Space mapping tables are fully written.
        do {
            guard sessionIsCurrent(controller), controller.localProfiles().allSatisfy({
                controller.profileKeys.mappedGlobalUuid(forProfileId: $0.profileId) != nil
            }) else { throw SyncPairingPersistenceError.writeFailed }
            try gate.completeEnrollment(verifiedDeviceKeyID: controller.manager.deviceKeyProviderForTesting.deviceKeyId())
        } catch {
            phase = .error(message: PairingWizardStrings.applyFailed, resume: .backToSpaces)
            return
        }
        // 4.
        await controller.resolveMappings()
        guard sessionIsCurrent(controller) else { return }
        phase = .done
        logApplied(spaceMaps: spaceMaps, spaceMints: spaceMints, ok: true)
    }

    // MARK: - Replacing this Mac's data

    /// "Use your account's data" (docs/sync.md, "Sync method and replacing this Mac's data"), inside the
    /// same single submission as a merge (R-D6-3): Profile decisions, then the durable resume marker, then
    /// the local reset, then enrollment. Every step is idempotent, so Retry reruns the whole sequence and
    /// picks up where it stopped. Never writes keyLayer.phase (R-D6-11).
    func replaceLocal(controller: SyncKeyController) async {
        // 0. Reject reentrant submission (a double-click) the same way applyDecisions does.
        guard canReplace, sessionIsCurrent(controller) else {
            AppLogInfo("[phi-sync] pairing wizard: a replace is already running or unavailable; ignoring")
            return
        }
        guard let reset = localReset(controller) else {
            AppLogWarn("[phi-sync] pairing wizard replace: the local data reset is unavailable")
            phase = .error(message: PairingWizardStrings.replaceLocalFailed, resume: .resumeReplace)
            return
        }
        let deleting = replaceDeleteProfileIds

        // 1. Account-side preflight, with the progress indicator in the footer.
        isPreparing = true
        let valid = await validateReview(for: .useAccount, deleting: deleting, controller: controller)
        isPreparing = false
        guard valid, sessionIsCurrent(controller) else { return }

        // 2.
        step = .confirm
        phase = .replacingLocal
        isApplying = true
        defer { isApplying = false }

        // 3. Profile decisions (network), before anything local is removed. Profiles being deleted get none;
        // a failure here has lost nothing.
        let decisions = PairingFlowPlan.replaceDecisions(locals: loadedLocals, remotes: loadedRemotes,
                                                         deleting: deleting)
        guard await keyLayer.applyPairingDecisions(decisions, controller: controller) else {
            guard sessionIsCurrent(controller) else { return }
            phase = .error(message: PairingWizardStrings.applyFailed, resume: .resumeReplace)
            logReplaced(decisions: decisions.count, deleting: deleting.count, stage: "profiles", ok: false)
            return
        }
        guard sessionIsCurrent(controller) else { return }
        // Successful decisions change the next candidate load. Advance the snapshot after the profile
        // decisions so the Retry preflight does not mistake this progress for an account change.
        await advanceReplaceSnapshot(deleting: deleting, controller: controller)
        guard sessionIsCurrent(controller) else { return }

        // 4. The durable intent, before anything local is removed: from here on, setup resumes this replace.
        do {
            try controller.savePairingLocalResetMarker(deleteProfileIds: deleting)
        } catch {
            AppLogWarn("[phi-sync] pairing wizard replace: the resume marker was not saved")
            phase = .error(message: PairingWizardStrings.applyFailed, resume: .resumeReplace)
            logReplaced(decisions: decisions.count, deleting: deleting.count, stage: "marker", ok: false)
            return
        }
        methodLocked = true
        lockedDeleteProfileIds = deleting

        // 5. The local reset.
        do {
            try await reset.clear(LocalResetRequest(deleteProfileIds: deleting))
        } catch {
            AppLogWarn("[phi-sync] pairing wizard replace: the local reset stopped "
                       + "(\(PhiSyncLog.describe(error)))")
            phase = .error(message: PairingWizardStrings.replaceLocalFailed, resume: .resumeReplace)
            logReplaced(decisions: decisions.count, deleting: deleting.count, stage: "clear", ok: false)
            return
        }
        guard sessionIsCurrent(controller) else { return }

        // From here on the reset has run, so "Nothing was lost" no longer holds: every failure below reports
        // the replace as unfinished, and Retry resumes it.
        // 6. No Space mappings: the default Space keeps its constant identity, and it must be the only
        // pairable Space left. Anything else means the reset did not finish.
        guard pairableLocalSpaces().allSatisfy({ $0.spaceId == LocalStore.defaultSpaceId }) else {
            AppLogWarn("[phi-sync] pairing wizard replace: Spaces other than the default remain")
            phase = .error(message: PairingWizardStrings.replaceLocalFailed, resume: .resumeReplace)
            logReplaced(decisions: decisions.count, deleting: deleting.count, stage: "verify", ok: false)
            return
        }

        // 7. Open the gate only once every remaining local Profile is mapped. Completion clears the marker.
        do {
            guard sessionIsCurrent(controller), controller.localProfiles().allSatisfy({
                controller.profileKeys.mappedGlobalUuid(forProfileId: $0.profileId) != nil
            }) else { throw SyncPairingPersistenceError.writeFailed }
            try gate.completeEnrollment(verifiedDeviceKeyID: controller.manager.deviceKeyProviderForTesting.deviceKeyId())
        } catch {
            phase = .error(message: PairingWizardStrings.replaceLocalFailed, resume: .resumeReplace)
            logReplaced(decisions: decisions.count, deleting: deleting.count, stage: "enrollment", ok: false)
            return
        }
        await controller.resolveMappings()
        guard sessionIsCurrent(controller) else { return }
        phase = .done
        logReplaced(decisions: decisions.count, deleting: deleting.count, stage: "done", ok: true)
    }

    /// Advances the replace's review snapshot after its Profile decisions succeed, by reloading the
    /// candidates as the merge path does: the account side keeps listing readable Profiles (the ones just
    /// registered included), so predicting the next load is not reliable. A failed reload falls back to the
    /// prediction and never fails the replace.
    private func advanceReplaceSnapshot(deleting: Set<String>, controller: SyncKeyController) async {
        let generation = loadGeneration
        let freshKeys = KeyLayerViewModel(manager: controller.manager)
        await freshKeys.startPairing(controller: controller)
        guard generation == loadGeneration, sessionIsCurrent(controller) else { return }
        let reloaded: Bool
        if case .pairingProfiles(let locals, let remotes) = freshKeys.phase {
            let live = liveRemotes(remotes)
            loadedLocals = locals
            loadedRemotes = live
            replaceExpectedExtraIds = Set(PairingFlowPlan.extraLocals(locals: locals, remotes: live)
                .map(\.profileId)).subtracting(deleting)
            reloaded = true
        } else {
            loadedLocals.removeAll { !deleting.contains($0.profileId) }
            loadedRemotes.removeAll { $0.name != nil }
            replaceExpectedExtraIds = []
            reloaded = false
        }
        AppLogInfo("[phi-sync] pairing wizard replace: snapshot reload ok=\(reloaded)")
    }

    /// The local Profiles the replace deletes: every extra local Profile the confirmation page lists, or the
    /// started replace's own list (its resume marker) while locked.
    private var replaceDeleteProfileIds: Set<String> {
        if methodLocked { return lockedDeleteProfileIds }
        return Set(replaceReview?.extraLocals.map(\.profileId) ?? [])
    }

    /// Lands on the confirmation page of a replace that already started: the method is locked, and the
    /// Profiles it deletes come from its resume marker.
    private func resumeReplace(deleting deleteProfileIds: Set<String>, controller: SyncKeyController) {
        selectedMethod = .useAccount
        methodLocked = true
        lockedDeleteProfileIds = deleteProfileIds
        AppLogInfo("[phi-sync] pairing wizard: resuming a started replace "
                   + "deleting=\(deleteProfileIds.count)")
        showReplaceReview(controller: controller)
    }

    private func showReplaceReview(controller: SyncKeyController) {
        let review = makeReplaceReview(controller: controller)
        replaceReview = review
        // Every extra local Profile, not only the listed ones: on a locked page the list is the marker's.
        replaceExpectedExtraIds = Set(PairingFlowPlan.extraLocals(locals: loadedLocals, remotes: loadedRemotes)
            .map(\.profileId))
        step = .confirm
        phase = .confirmReplaceLocal(review)
        logStep()
    }

    private func makeReplaceReview(controller: SyncKeyController) -> ReplaceLocalReview {
        let inventory = localInventory
        let removedSpaces = inventory?.nonDefaultSpaceIds.count
            ?? spacesInput.locals.filter { $0.spaceId != LocalStore.defaultSpaceId }.count
        // A started replace deletes exactly its marker's Profiles; a Profile created after the marker was
        // written is kept and registered, so it is not listed.
        let deleting = methodLocked
            ? loadedLocals.filter { !$0.isDefault && lockedDeleteProfileIds.contains($0.profileId) }
            : PairingFlowPlan.extraLocals(locals: loadedLocals, remotes: loadedRemotes)
        return ReplaceLocalReview(
            removed: PairingDataSummary.Counts(profiles: deleting.count, spaces: removedSpaces,
                                               bookmarks: inventory?.bookmarks,
                                               pinnedTabs: inventory?.pinnedTabs,
                                               urlRules: inventory?.urlRules),
            downloaded: makeSummary(controller: controller).account,
            extraLocals: deleting,
            defaultUnavailable: PairingFlowPlan.defaultNeedsChoice(locals: loadedLocals, remotes: loadedRemotes))
    }

    /// Both sides' counts for the method step. This Mac: every local Profile, every pairable Space (the
    /// default included) and the reset's inventory. The account: its unclaimed Profiles plus the local ones
    /// already mapped to it, its Spaces plus the default Space the preview leaves out, and the preview's
    /// bookmark, pinned tab and URL rule counts (nil, so named only, when the preview could not count them).
    private func makeSummary(controller: SyncKeyController) -> PairingDataSummary {
        let localProfileCount = controller.localProfiles().count
        let inventory = localInventory
        return PairingDataSummary(
            local: PairingDataSummary.Counts(profiles: localProfileCount, spaces: spacesInput.locals.count,
                                             bookmarks: inventory?.bookmarks,
                                             pinnedTabs: inventory?.pinnedTabs,
                                             urlRules: inventory?.urlRules),
            account: PairingDataSummary.Counts(
                profiles: loadedRemotes.count + max(0, localProfileCount - loadedLocals.count),
                spaces: spacesInput.accountSpaces.count + 1,
                bookmarks: previewItemCounts.bookmarks, pinnedTabs: previewItemCounts.pinnedTabs,
                urlRules: previewItemCounts.urlRules))
    }

    /// The reset's inventory, or nil when the reset is unavailable or its counts cannot be read.
    private func readInventory(controller: SyncKeyController) -> LocalPhiInventory? {
        guard let reset = localReset(controller) else { return nil }
        do {
            return try reset.inventory(deleting: [])
        } catch {
            AppLogWarn("[phi-sync] pairing wizard: the local inventory could not be read "
                       + "(\(PhiSyncLog.describe(error)))")
            return nil
        }
    }

    /// Return true only when this call mints a new UUID on first addAsNew application; claims and
    /// already-satisfied replays return false, preserving §9.1 metadata counts.
    ///
    /// Idempotency (§5.1): alreadyMapped succeeds only if the existing mapping matches the desired decision;
    /// otherwise expose a hard error, including changed choices after partial success. existing compares the
    /// selected UUID; addAsNew checks whether its UUID belongs to the account list.
    private func apply(_ decision: (localSpaceId: String, assignment: SpacePairingModel.Assignment),
                       controller: SyncKeyController) throws -> Bool {
        switch decision.assignment {
        case .existing(let syncUuid):
            // Missing from readable choices does not prove absent if preview skipped any
            // entity. Only a complete readable scan can authorize replacing the exact old
            // mapping; validation and persistence must leave it intact on failure.
            var replacedUuid: String?
            if previewSkippedEntityCount == 0,
               let current = controller.syncUuid(forSpaceId: decision.localSpaceId), current != syncUuid,
               !spacesInput.accountSpaces.contains(where: { $0.syncUuid == current }) {
                replacedUuid = current
            }
            do {
                try controller.mapSpace(decision.localSpaceId, toSyncUuid: syncUuid, replacing: replacedUuid)
            } catch SpaceSyncMappingError.alreadyMapped {
                guard controller.syncUuid(forSpaceId: decision.localSpaceId) == syncUuid else {
                    // R12: log mismatch only, never UUIDs.
                    AppLogError("[phi-sync] pairing wizard: an existing Space mapping disagrees with the choice (expected != actual)")
                    throw SpaceSyncMappingError.alreadyMapped
                }
            }
            return false
        case .addAsNew:
            // ensureSpaceMapped only prevents a second UUID; it does not enforce addAsNew intent. After
            // partial application, a user might switch an existing-account choice to addAsNew to retain local
            // fields. Silently retaining the account mapping would skip D7 confirmation, then A1 baseline-free
            // adoption would overwrite those fields.
            //
            // Explicitly distinguish: absent mapping → mint; mapped UUID absent from the account list →
            // previously minted locally, done; mapped UUID present in the account list → hard mismatch, never
            // silently execute a revoked decision.
            if let existing = controller.syncUuid(forSpaceId: decision.localSpaceId) {
                guard !spacesInput.accountSpaces.contains(where: { $0.syncUuid == existing }) else {
                    // R12: log only that the row remains bound to an account Space, never its UUID.
                    AppLogError("[phi-sync] pairing wizard: an \"add as new\" row is still bound to an account Space (expected != actual)")
                    throw SpaceSyncMappingError.alreadyMapped
                }
                return false            // Already minted locally; no new identity.
            }
            _ = try controller.ensureSpaceMapped(spaceId: decision.localSpaceId)
            return true
        }
    }

    /// A review authorizes only the values the user saw. Changed data returns to fresh
    /// choices before any mapping write, including when the prior page had no differences.
    func validateCurrentReview(controller: SyncKeyController) async -> Bool {
        await validateReview(for: .merge, controller: controller)
    }

    /// The submission preflight of either method: both loads again, compared with what the user reviewed.
    ///
    /// - Merge compares everything, local Spaces included, and returns to the Profiles page on a change.
    /// - "Use your account's data" compares only the account side (account Profiles, account Spaces, the
    ///   preview's skipped count) and the set of extra local Profiles, minus those it deletes. Local Spaces are
    ///   not compared: they are what it removes, and after a partial reset a Retry would otherwise never match.
    ///   A change returns to the confirmation page with fresh data.
    private func validateReview(for method: SyncMethod, deleting deleteProfileIds: Set<String> = [],
                                controller: SyncKeyController) async -> Bool {
        let generation = loadGeneration
        let freshKeys = KeyLayerViewModel(manager: controller.manager)
        async let profileLoad: Void = freshKeys.startPairing(controller: controller)
        async let spaceLoad = loadAccountSpaces()
        await profileLoad
        let result = await spaceLoad
        guard generation == loadGeneration, sessionIsCurrent(controller) else { return false }
        guard case .pairingProfiles(let locals, let reloaded) = freshKeys.phase,
              case .success(let spaces) = result else {
            phase = .error(message: PairingWizardStrings.previewFailed,
                           resume: method == .merge ? .reload : .resumeReplace)
            return false
        }
        previewDeletedProfileTagHashes = spaces.deletedProfileTagHashes
        previewProfileNames = spaces.profileNames
        // Informational only: deliberately not part of the account-side comparison below.
        previewItemCounts = (spaces.bookmarkCount, spaces.pinnedTabCount, spaces.urlRuleCount)
        let remotes = liveRemotes(reloaded)
        let fresh = makeSpacesInput(accountSpaces: spaces.spaces, remotes: remotes, controller: controller)
        if method == .useAccount {
            let freshExtras = Set(PairingFlowPlan.extraLocals(locals: locals, remotes: remotes).map(\.profileId))
            guard remotes == loadedRemotes, fresh.accountSpaces == spacesInput.accountSpaces,
                  spaces.skippedEntityCount == previewSkippedEntityCount,
                  freshExtras.subtracting(deleteProfileIds)
                    == replaceExpectedExtraIds.subtracting(deleteProfileIds) else {
                previewSkippedEntityCount = spaces.skippedEntityCount
                loadedLocals = locals
                loadedRemotes = remotes
                reseedProfileSelections(locals: locals, remotes: remotes)
                spacesInput = fresh
                seedSpaceSelections(controller: controller)
                profileDecisions = []
                plan = makePlan(locals: locals, remotes: remotes, accountSpaces: spaces.spaces,
                                controller: controller)
                // §9.1: booleans only.
                AppLogInfo("[phi-sync] pairing wizard replace: the account changed; review again "
                           + "locked=\(methodLocked)")
                showReplaceReview(controller: controller)
                return false
            }
            return true
        }
        guard locals == loadedLocals, remotes == loadedRemotes, fresh == spacesInput,
              spaces.skippedEntityCount == previewSkippedEntityCount else {
            previewSkippedEntityCount = spaces.skippedEntityCount
            loadedLocals = locals
            loadedRemotes = remotes
            reseedProfileSelections(locals: locals, remotes: remotes)
            spacesInput = fresh
            seedSpaceSelections(controller: controller)
            profileDecisions = []
            // Changed data is reviewed from the Profiles page, even when the fresh plan would hide it.
            plan = makePlan(locals: locals, remotes: remotes, accountSpaces: spaces.spaces,
                            controller: controller).revealingProfiles()
            step = .profiles
            phase = .profiles(locals: locals, remotes: remotes)
            return false
        }
        return true
    }

    // MARK: - Loading helpers

    /// The account Profiles minus those whose Profile entity the latest preview saw tombstoned,
    /// named from their live entity when the preview read one: the registry envelope keeps the
    /// registration-time name, so a Profile renamed on another device would otherwise be offered
    /// under its old name (rejoin after "Remove from sync", 2026-10-12).
    private func liveRemotes(_ remotes: [RemoteProfile]) -> [RemoteProfile] {
        remotes.compactMap { remote in
            guard !previewDeletedProfileTagHashes.contains(
                PhiSyncEntity.clientTagHash(for: PhiSyncEntity.profileClientTag(remote.uuid))) else { return nil }
            guard let name = previewProfileNames[remote.uuid] else { return remote }
            // Only the name comes from the entity; the default flag lives in the
            // envelope and must survive, or the default-profile rule reads the
            // renamed Profile as legacy and offers it to any local.
            return RemoteProfile(uuid: remote.uuid, name: name, isDefault: remote.isDefault)
        }
    }

    private func seedSpaceSelections(controller: SyncKeyController) {
        spaceSelections = [:]
        explicitSpaceChoices = []
        mappedProfileUuids = [:]
        for summary in spacesInput.accountSpaces {
            if let localId = controller.localProfileId(forGlobalUuid: summary.profileUuid) {
                mappedProfileUuids[localId] = summary.profileUuid
            }
        }
        for local in spacesInput.locals where local.spaceId != LocalStore.defaultSpaceId {
            guard let uuid = controller.syncUuid(forSpaceId: local.spaceId) else { continue }
            spaceSelections[local.spaceId] = spacesInput.accountSpaces.contains { $0.syncUuid == uuid }
                ? .existing(syncUuid: uuid) : .addAsNew
        }
        identitySpaceSelections = spaceSelections
    }

    private func reseedProfileSelections(locals: [PairingLocal], remotes: [RemoteProfile]) {
        profileSelections = ProfilePairingModel.initialSelections(locals: locals, remotes: remotes)
        profileRemoteChoices = [:]
    }

    /// §5.2 name resolution: decrypted registration name from unclaimed remotes → local display name of a
    /// mapped account Profile → no name, rendered as an em dash without affecting predicates. Together the two
    /// sources cover account Profiles without early step-1 submission.
    private func makeSpacesInput(accountSpaces: [PhiAccountSpaceSummary],
                                 remotes: [RemoteProfile],
                                 controller: SyncKeyController) -> SpacePairingModel.Input {
        var localNames: [String: String] = [:]
        for profile in controller.localProfiles() {
            localNames[profile.profileId] = profile.displayName
        }
        var accountNames: [String: String] = [:]
        for remote in remotes where remote.name != nil {
            accountNames[remote.uuid] = remote.name
        }
        for summary in accountSpaces where accountNames[summary.profileUuid] == nil {
            if let localId = controller.localProfileId(forGlobalUuid: summary.profileUuid),
               let name = localNames[localId] {
                accountNames[summary.profileUuid] = name
            }
        }
        return SpacePairingModel.Input(locals: pairableLocalSpaces(),
                                       accountSpaces: accountSpaces,
                                       localProfileNames: localNames,
                                       accountProfileNames: accountNames)
    }

    /// Centralize §4.5 deadline and §4.6 error mapping. A paginated preview with per-request URLSession
    /// defaults of 60 s could otherwise stall for minutes. R12 logs detailed errors only.
    ///
    /// Two equal deadlines have separate duties: UI returns promptly regardless of underlying work;
    /// PhiSyncEngine.previewDeadlineMs stops further pages and releases the round queue. Either alone is
    /// insufficient: UI cannot free the engine, and engine paging checks cannot shorten an in-flight request.
    /// M3-3 §5.8 raised both from 45 to 120 s because counting Spaces now traverses bookmarks/pins across the
    /// account; loading copy states that wait.
    private func loadAccountSpaces() async -> Result<PhiAccountSpacePreview, PairingWizardLoadFailure> {
        let preview = previewAccountSpaces
        let deadline = loadDeadline
        // Both racers are unstructured tasks using the one-shot PreviewRace gate. The deadline returns
        // immediately without waiting for an uncancelable child, unlike a task group.
        let outcome: Result<PhiAccountSpacePreview, PhiSpacePreviewError>? =
            await withCheckedContinuation { continuation in
                let race = PreviewRace(continuation)
                Task { race.finish(await preview()) }
                Task {
                    try? await Task.sleep(for: deadline)
                    race.finish(nil)    // The deadline won.
                }
            }
        guard let outcome else {
            AppLogWarn("[phi-sync] pairing wizard: the account Space preview exceeded its deadline")
            return .failure(PairingWizardLoadFailure(message: PairingWizardStrings.previewTimedOut))
        }
        switch outcome {
        case .success(let summaries):
            return .success(summaries)
        case .failure(let error):
            AppLogWarn("[phi-sync] pairing wizard: space preview failed code=\(Self.code(for: error))")
            switch error {
            case .engineUnavailable, .retired:
                return .failure(PairingWizardLoadFailure(message: PairingWizardStrings.previewUnavailable))
            case .timedOut:
                // Use the same timeout message for the engine deadline and wizard deadline; users experience
                // the same outcome.
                return .failure(PairingWizardLoadFailure(message: PairingWizardStrings.previewTimedOut))
            case .truncated:
                return .failure(PairingWizardLoadFailure(message: PairingWizardStrings.previewTruncated))
            case .transport:
                return .failure(PairingWizardLoadFailure(message:
                    error == .transport("not_my_birthday")
                        ? SyncReconfigurationStrings.returnToSettings : PairingWizardStrings.previewFailed))
            }
        }
    }

    /// R12: log only these fixed codes, never interpolated error descriptions.
    private static func code(for error: PhiSpacePreviewError) -> String {
        switch error {
        case .engineUnavailable: return "engine_unavailable"
        case .retired: return "retired"
        case .timedOut: return "timed_out"
        case .truncated: return "truncated"
        case .transport(let detail): return "transport:\(detail)"
        }
    }

    // MARK: - Page plan

    private func makePlan(locals: [PairingLocal], remotes: [RemoteProfile],
                          accountSpaces: [PhiAccountSpaceSummary],
                          controller: SyncKeyController) -> PairingFlowPlan {
        let previewComplete = previewSkippedEntityCount == 0
        replaceAvailable = localReset(controller) != nil
        localInventory = readInventory(controller: controller)
        let facts = PairingFlowFacts(
            isBrandNewAccount: PairingFlowPlan.isBrandNewAccount(
                createdByThisFlow: shouldCompleteNewAccount, previewComplete: previewComplete,
                remotes: remotes, accountSpaces: accountSpaces),
            previewComplete: previewComplete,
            // An unreadable inventory is unknown, which counts as data.
            localHasReplaceableData: PairingFlowPlan.localHasReplaceableData(
                localProfileIds: controller.localProfiles().map(\.profileId),
                localSpaces: spacesInput.locals,
                ownedItemsPresent: PairingFlowPlan.ownedItemsPresent(localInventory)),
            profilesNeedDecision: PairingFlowPlan.profilesNeedDecision(locals: locals, remotes: remotes),
            profilesHaveRows: PairingFlowPlan.profilesHaveRows(locals: locals, remotes: remotes),
            spacesNeedDecision: PairingFlowPlan.spacesNeedDecision(spacesInput))
        let plan = PairingFlowPlan.make(facts, methodStepEnabled: methodStepEnabled && replaceAvailable)
        // The method step's counts follow every refresh of the inventory and the loaded candidates.
        methodSummary = makeSummary(controller: controller)
        // §9.1: booleans only.
        AppLogInfo("[phi-sync] pairing wizard plan: method=\(plan.showsMethod) "
                   + "profiles=\(plan.showsProfiles) spaces=\(plan.showsSpaces) "
                   + "auto=\(plan.autoCompletes) new_account=\(facts.isBrandNewAccount) "
                   + "complete=\(previewComplete) inventory=\(localInventory != nil)")
        return plan
    }

    /// Submits with the Spaces page hidden: the plan auto-completes, or the Profiles page was the last page.
    /// The status page shows from the start, including during the preflight in applyDecisions, which runs
    /// unchanged: every submission re-reads the account before writing anything.
    private func submitWithoutSpacesPage(controller: SyncKeyController) async {
        if step != .spaces {
            // Freezes the Profile decisions (auto or chosen) the same way Continue does, without publishing a
            // Spaces page that is not part of the plan.
            guard canLeaveProfiles else { revealProfilesPage(); return }
            freezeProfileDecisions()
            step = .spaces
        }
        // Brand-new account only: its hidden Space rows are added as new. Otherwise there are no rows.
        addAllAsNew()
        phase = .submitting
        logStep()
        await finish(controller: controller)
        // finish and its preflight return without changing the page only when they refuse: a superseded or
        // busy session. Never leave a status page up with nothing running behind it.
        guard phase == .submitting, !isApplying, !isPreparing else { return }
        // §9.1: booleans only.
        AppLogInfo("[phi-sync] pairing wizard: finish refused, revealing profiles "
                   + "current=\(sessionIsCurrent(controller))")
        revealProfilesPage()
    }

    /// Fallback to the Profiles page when a hidden page's automatic decisions could not be used.
    private func revealProfilesPage() {
        plan = plan?.revealingProfiles()
        step = .profiles
        phase = .profiles(locals: loadedLocals, remotes: loadedRemotes)
        logStep()
    }

    // MARK: - §9.1 logs (counts and booleans only)

    private func logStep() {
        let undecided: Int
        switch step {
        case .method, .confirm:
            undecided = 0
        case .profiles:
            let live = profileModel
            undecided = loadedRemotes.filter {
                $0.name != nil && !live.claimedRemoteUuids.contains($0.uuid)
                    && !live.createLocalUuids.contains($0.uuid)
            }.count
        case .spaces:
            undecided = spaceModel.rows.count - spaceModel.decisions().count
        }
        AppLogInfo("[phi-sync] pairing wizard: step=\(Self.logName(for: step)) "
                   + "locals=\(spacesInput.locals.count) "
                   + "account_spaces=\(spacesInput.accountSpaces.count) undecided=\(undecided)")
    }

    private static func logName(for step: PairingWizardStep) -> String {
        switch step {
        case .method: return "method"
        case .profiles: return "profiles"
        case .spaces: return "spaces"
        case .confirm: return "confirm"
        }
    }

    private func logReplaced(decisions: Int, deleting: Int, stage: String, ok: Bool) {
        AppLogInfo("[phi-sync] pairing wizard replaced: profile_decisions=\(decisions) "
                   + "profiles_deleted=\(deleting) stage=\(stage) ok=\(ok)")
    }

    private func logApplied(spaceMaps: Int, spaceMints: Int, ok: Bool) {
        AppLogInfo("[phi-sync] pairing wizard applied: "
                   + "profile_decisions=\(profileDecisions.count) space_maps=\(spaceMaps) "
                   + "space_mints=\(spaceMints) ok=\(ok)")
    }
}
