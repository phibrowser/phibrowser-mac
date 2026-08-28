// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import SwiftUI

// MARK: - Migration Sources

/// A browser a Migration can be run from. Arc ships first; Dia and Zen become
/// further cases without the wizard learning anything about them — it knows a
/// source only through this type and the model the source hands back.
enum BrowserMigrationSourceKind: String, CaseIterable, Identifiable {
    case arc

    var id: String { rawValue }

    /// A product name, so not localized.
    var displayName: String {
        switch self {
        case .arc: return "Arc"
        }
    }

    /// The Chromium-side importer this source's data comes through.
    var browserType: BrowserType {
        switch self {
        case .arc: return .arc
        }
    }

    /// The source's Chromium user-data directory: its presence is what
    /// "installed" means, and its per-profile directories are where the Web
    /// Store extension list is read from.
    var userDataURL: URL {
        switch self {
        case .arc: return BrowserDataImporter.arcUserDataURL
        }
    }

    /// Every data type this source supports — Migration has no per-type
    /// toggles, so it always asks for all of them. What a browser supports is
    /// `ImportDataType`'s to say, not this enum's. Arc's bookmarks are the one
    /// subtraction: Phi parses its sidebar itself and writes each Space's tree
    /// Mac-side, the same strip the import window makes.
    var migrationDataTypes: [String] {
        let supported = ImportDataType.availableTypes(for: browserType)
        switch self {
        case .arc:
            return supported.filter { $0 != .bookmarks }.map(\.rawValue)
        }
    }

    /// A non-blocking notice shown before a run starts. Arc and Dia share one:
    /// the Chromium importer decrypts their cookies with a key it reads from
    /// their Keychain item, and builds a fresh decryptor — so asks again — for
    /// every Profile it imports into.
    var preflightHint: String {
        switch self {
        case .arc:
            return String(
                format: NSLocalizedString("app.browserMigration.preflight.keychain",
                    value: "macOS will ask to use %@'s encryption key so your cookies can come across. Choose “Always Allow”, or it asks again for every Profile.",
                    comment: "Browser migration wizard - warns that the OS Keychain prompt is coming before a run starts; %@ is the source browser's name"),
                displayName)
        }
    }

    /// A cheap presence check: the menu item validates this on every menu open,
    /// so it must not parse the source's data. That happens once, when the
    /// wizard opens.
    var isInstalled: Bool {
        FileManager.default.fileExists(atPath: userDataURL.path)
    }

    /// Every source alphabetically — which is also the order the phases ship
    /// in. Separate from `installed` so the ordering can be asserted without a
    /// real install of anything.
    static var allInDisplayOrder: [BrowserMigrationSourceKind] {
        allCases.sorted { $0.displayName < $1.displayName }
    }

    /// The sources present on this machine, in that same order.
    static var installed: [BrowserMigrationSourceKind] {
        allInDisplayOrder.filter(\.isInstalled)
    }

    /// Reads the whole source model. Nil when the source is installed but its
    /// own data cannot be read — a missing or malformed sidebar file.
    func loadSource() -> BrowserMigrationSource? {
        switch self {
        case .arc:
            return BrowserDataImporter().loadArcMigrationSource()?.migrationSource
        }
    }
}

// MARK: - Preview rows

/// One Space row of the preview.
struct BrowserMigrationPreviewSpaceRow: Equatable, Identifiable {
    let sourceSpaceID: String
    let name: String
    let colorHex: String
    let isTicked: Bool
    /// True when the source could not read this Space's own profile record, so
    /// it follows the default profile's Profile and has no tick of its own.
    let boundToDefaultProfile: Bool

    var id: String { sourceSpaceID }
}

/// One Profile row of the preview, with its Spaces beneath it.
struct BrowserMigrationPreviewProfileRow: Equatable, Identifiable {
    let sourceProfileKey: String
    /// The Profile's planned display name — suffixed against collisions —
    /// while it is ticked; the source's own name while it is not, because an
    /// unticked Profile is not in the plan and has no name to collide with.
    let displayName: String
    let isTicked: Bool
    /// Set when this source profile creates nothing whatever the user ticks.
    let skipReason: BrowserMigrationSkippedProfile.Reason?
    let spaces: [BrowserMigrationPreviewSpaceRow]

    var id: String { sourceProfileKey }
}

/// Joins the source model with the plan built from the current tick state into
/// what the preview draws. It decides nothing: every name, colour, order and
/// flag here is read off one or the other, so the wizard holds no mapping logic
/// of its own. The plan carries only what a run would create, so the rows the
/// user has unticked — which must stay on screen to be ticked back — come from
/// the source.
enum BrowserMigrationPreview {
    static func rows(
        source: BrowserMigrationSource,
        plan: BrowserMigrationPlan
    ) -> [BrowserMigrationPreviewProfileRow] {
        source.profileKeysInSourceOrder.map { key in
            let planned = plan.profiles.first { $0.sourceProfileKey == key }
            let skipped = plan.skippedProfiles.first { $0.sourceProfileKey == key }
            let displayName = planned?.displayName ?? skipped?.displayName
                ?? BrowserMigrationPlanner.resolvedDisplayName(
                    of: source.profiles.first { $0.key == key }?.displayName, key: key)
            let plannedSpaces = Dictionary(
                uniqueKeysWithValues: (planned?.spaces ?? []).map { ($0.sourceSpaceID, $0) })
            return BrowserMigrationPreviewProfileRow(
                sourceProfileKey: key,
                displayName: displayName,
                isTicked: planned != nil,
                skipReason: skipped?.reason,
                spaces: source.spaces(ofProfile: key).map { space in
                    let plannedSpace = plannedSpaces[space.id]
                    return BrowserMigrationPreviewSpaceRow(
                        sourceSpaceID: space.id,
                        name: plannedSpace?.name ?? space.name,
                        colorHex: plannedSpace?.colorHex
                            ?? BrowserMigrationSpaceTheme.resolved(
                                forSourceColorHex: space.colorHex).colorHex,
                        isTicked: plannedSpace != nil,
                        boundToDefaultProfile: plannedSpace?.boundToDefaultProfile
                            ?? source.bindsToDefaultProfile(space)
                    )
                }
            )
        }
    }
}

// MARK: - Wizard state

/// The wizard's state. It owns the tick state and re-derives the plan — and so
/// the preview — on every change to it.
@MainActor
final class BrowserMigrationWizardModel: ObservableObject {
    enum Step: Equatable {
        case pick
        case preview
        /// The run itself: live progress while it works, its report after.
        case run
    }

    /// Identifies the run being planned, and with it every pinned tab and pin
    /// lineage the plan names, so the same input plans the same way twice while
    /// the user is ticking rows.
    ///
    /// Re-rolled for each new preview: this model outlives a finished run —
    /// the window is a singleton that is closed, not released — and a second
    /// run that kept the first one's identifiers would write pinned rows
    /// carrying guids already on disk, which the store's scope migration traps
    /// on, under lineages that would merge the two runs into one.
    private(set) var operationID = UUID()
    let installedSources = BrowserMigrationSourceKind.installed

    @Published private(set) var step: Step = .pick
    @Published var pickedSource: BrowserMigrationSourceKind? {
        didSet { sourceUnreadable = false }
    }
    @Published private(set) var plan: BrowserMigrationPlan?
    @Published private(set) var rows: [BrowserMigrationPreviewProfileRow] = []
    /// Set when the picked source is installed but its data could not be read.
    @Published private(set) var sourceUnreadable = false

    private var source: BrowserMigrationSource?
    private var selection = BrowserMigrationSelection()

    init() {
        pickedSource = installedSources.first
        // A run outlives this window, so reopening the wizard returns to the
        // live progress or to the report of the run that just finished rather
        // than offering to start a second one.
        if !BrowserMigrationRunner.shared.isIdle {
            step = .run
        }
    }

    /// A run writes into the account's local store. Guest Mode is a bound
    /// account with a store of its own, so it passes; a session with no account
    /// at all cannot start one.
    var isAccountBound: Bool {
        AccountController.shared.localDataAccount != nil
    }

    var plannedProfileCount: Int { plan?.profiles.count ?? 0 }
    var plannedSpaceCount: Int {
        plan?.profiles.reduce(0) { $0 + $1.spaces.count } ?? 0
    }

    var canStart: Bool { isAccountBound && plannedProfileCount > 0 }

    /// Reads the picked source and opens the preview with everything ticked.
    func showPreview() {
        guard let pickedSource else { return }
        guard let source = pickedSource.loadSource() else {
            sourceUnreadable = true
            return
        }
        sourceUnreadable = false
        // A new prospective run, so a new identity for what it would create.
        operationID = UUID()
        self.source = source
        selection = .all(in: source)
        rebuild()
        step = .preview
    }

    func backToPick() {
        step = .pick
        source = nil
        plan = nil
        rows = []
    }

    func setProfile(_ key: String, ticked: Bool) {
        guard let source else { return }
        selection = selection.setting(profileKey: key, ticked: ticked, in: source)
        rebuild()
    }

    func setSpace(_ spaceID: String, ticked: Bool) {
        guard let source else { return }
        selection = selection.setting(spaceID: spaceID, ticked: ticked, in: source)
        rebuild()
    }

    /// Hands the plan to the process-level runner and follows it. The run
    /// belongs to the process from here on: closing this window does not
    /// interrupt it.
    func start() {
        // The plan's pinned owners were fanned out from the scope that was
        // active when the preview was built, while the store stamps each row
        // with the one active when the write runs — so a scope changed in
        // between would write a Profile's entries once per Space, or only into
        // its first Space. Replan so the two agree. A scope changed *during* a
        // run is ticket 09's: it gates that setting on a migration being in
        // flight, which is a restriction rather than a repair.
        if let plan, plan.pinnedTabScope != currentPinnedTabScope { rebuild() }
        guard canStart, let plan, let pickedSource else { return }
        guard BrowserMigrationRunner.shared.start(plan: plan, source: pickedSource) else {
            return
        }
        step = .run
    }

    /// The scope a plan's pinned owners are fanned out from. Read again at
    /// start, because it belongs to the store rather than to this window and
    /// can move while the preview is open.
    private var currentPinnedTabScope: PinnedTabScope {
        AccountController.shared.localDataAccount?.localStorage.pinnedTabScope() ?? .profile
    }

    private func rebuild() {
        guard let source else { return }
        let plan = BrowserMigrationPlanner.plan(
            source: source,
            existingProfileDisplayNames: ProfileManager.shared.profiles.map(\.displayName),
            pinnedTabScope: currentPinnedTabScope,
            selection: selection,
            operationID: operationID
        )
        self.plan = plan
        rows = BrowserMigrationPreview.rows(source: source, plan: plan)
    }
}

// MARK: - Wizard view

struct BrowserMigrationWizardView: View {
    /// Fixed, and larger than the import window's 500x700. The window takes its
    /// size from here rather than the other way round: a hosting controller
    /// sizes its window from the view's fitting size, so a view that asks to
    /// fill grows the window instead of being bounded by it.
    static let windowSize = CGSize(width: 640, height: 720)

    @StateObject private var model: BrowserMigrationWizardModel
    /// The run is the process's, not this window's, so the view observes it
    /// where it lives rather than owning it.
    @ObservedObject private var runner = BrowserMigrationRunner.shared
    private let onClose: () -> Void

    init(model: BrowserMigrationWizardModel, onClose: @escaping () -> Void) {
        _model = StateObject(wrappedValue: model)
        self.onClose = onClose
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(NSLocalizedString("app.browserMigration.title", value: "Migrate to Phi",
                comment: "Browser migration wizard - window heading"))
                .font(.system(size: 24, weight: .semibold))
            switch model.step {
            case .pick:
                pickStep
            case .preview:
                previewStep
            case .run:
                runStep
            }
        }
        .padding(24)
        .frame(
            width: Self.windowSize.width,
            height: Self.windowSize.height,
            alignment: .topLeading)
    }

    // MARK: Pick

    private var pickStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(NSLocalizedString("app.browserMigration.pick.subtitle",
                value: "Choose the browser to migrate from. Phi recreates its Profiles and Spaces — it never changes what you already have.",
                comment: "Browser migration wizard - explanation above the source list"))
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Picker("", selection: $model.pickedSource) {
                ForEach(model.installedSources) { source in
                    Text(source.displayName)
                        .tag(BrowserMigrationSourceKind?.some(source))
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()

            if model.sourceUnreadable {
                Text(NSLocalizedString("app.browserMigration.pick.unreadable",
                    value: "Phi couldn't read this browser's data.",
                    comment: "Browser migration wizard - shown when the picked source is installed but its data can't be parsed"))
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }

            Spacer()

            HStack {
                Spacer()
                Button(NSLocalizedString("app.browserMigration.pick.continueButton", value: "Continue",
                    comment: "Browser migration wizard - button that opens the preview for the picked source")) {
                    model.showPreview()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.pickedSource == nil)
            }
        }
    }

    // MARK: Preview

    private var previewStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(NSLocalizedString("app.browserMigration.preview.subtitle",
                value: "These Profiles and Spaces will be created. Untick anything you don't want.",
                comment: "Browser migration wizard - explanation above the preview tree"))
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(model.rows) { row in
                        profileRow(row)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }
            .frame(maxHeight: .infinity)

            Text(summary)
                .font(.system(size: 12))
                .foregroundColor(.secondary)

            // Said before anything starts rather than when the prompt appears:
            // the run is serial, so a user who dismisses it once is asked again
            // for every Profile.
            if let source = model.pickedSource {
                Text(source.preflightHint)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !model.isAccountBound {
                Text(NSLocalizedString("app.browserMigration.preview.accountRequired",
                    value: "Sign in to Phi — or continue as a guest — before migrating.",
                    comment: "Browser migration wizard - shown instead of starting when no account is bound"))
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }

            HStack {
                Button(NSLocalizedString("app.browserMigration.preview.backButton", value: "Back",
                    comment: "Browser migration wizard - button returning from the preview to the source list")) {
                    model.backToPick()
                }
                Spacer()
                Button(NSLocalizedString("app.browserMigration.preview.cancelButton", value: "Cancel",
                    comment: "Browser migration wizard - button closing the wizard without migrating"), action: onClose)
                    .keyboardShortcut(.cancelAction)
                Button(NSLocalizedString("app.browserMigration.preview.startButton", value: "Start Migration",
                    comment: "Browser migration wizard - button starting the migration run")) {
                    model.start()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canStart)
            }
        }
    }

    private var summary: String {
        String(
            format: NSLocalizedString("app.browserMigration.preview.summary",
                value: "Will create %1$@ and %2$@.",
                comment: "Browser migration wizard - what the previewed run creates; %1$@ is a Profile count such as \"2 Profiles\", %2$@ a Space count such as \"4 Spaces\""),
            Self.profileCountLabel(model.plannedProfileCount),
            Self.spaceCountLabel(model.plannedSpaceCount))
    }

    private static func profileCountLabel(_ count: Int) -> String {
        String.localizedStringWithFormat(
            NSLocalizedString("app.browserMigration.preview.profileCount", value: "%d Profiles",
                comment: "Browser migration wizard - Profile count in the preview summary; %d is the number of Profiles"),
            count)
    }

    private static func spaceCountLabel(_ count: Int) -> String {
        String.localizedStringWithFormat(
            NSLocalizedString("app.browserMigration.preview.spaceCount", value: "%d Spaces",
                comment: "Browser migration wizard - Space count in the preview summary; %d is the number of Spaces"),
            count)
    }

    @ViewBuilder
    private func profileRow(_ row: BrowserMigrationPreviewProfileRow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let skipReason = row.skipReason {
                // Skipped whatever the user ticks, so it carries no checkbox.
                HStack(spacing: 6) {
                    Text(row.displayName)
                    Text(Self.skipReasonLabel(skipReason))
                        .font(.system(size: 12))
                }
                .foregroundColor(.secondary)
                .padding(.leading, 20)
            } else {
                Toggle(isOn: Binding(
                    get: { row.isTicked },
                    set: { model.setProfile(row.sourceProfileKey, ticked: $0) }
                )) {
                    Text(row.displayName).font(.system(size: 13, weight: .medium))
                }
                .toggleStyle(.checkbox)
            }

            ForEach(row.spaces) { space in
                spaceRow(space)
            }
        }
    }

    private static func skipReasonLabel(
        _ reason: BrowserMigrationSkippedProfile.Reason
    ) -> String {
        switch reason {
        case .noSpaces:
            return NSLocalizedString("app.browserMigration.preview.noSpaces", value: "No Spaces",
                comment: "Browser migration wizard - reason a source profile is skipped and creates nothing")
        }
    }

    private func spaceRow(_ space: BrowserMigrationPreviewSpaceRow) -> some View {
        Toggle(isOn: Binding(
            get: { space.isTicked },
            set: { model.setSpace(space.sourceSpaceID, ticked: $0) }
        )) {
            HStack(spacing: 6) {
                Circle()
                    .fill(Color(hexString: space.colorHex))
                    .frame(width: 10, height: 10)
                Text(space.name).font(.system(size: 13))
                if space.boundToDefaultProfile {
                    Text(NSLocalizedString("app.browserMigration.preview.defaultProfileBound",
                        value: "Phi couldn't tell which profile this belongs to — it will use the default one",
                        comment: "Browser migration wizard - note on a Space whose source profile record is unreadable"))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
        }
        .toggleStyle(.checkbox)
        // It follows its Profile's tick and has no tick of its own.
        .disabled(space.boundToDefaultProfile)
        .padding(.leading, 20)
    }

    // MARK: Run

    @ViewBuilder
    private var runStep: some View {
        switch runner.state {
        case .running(let progress):
            progressStep(progress)
        case .finished(let report):
            reportStep(report)
        case .idle:
            // Only reachable if the report was dismissed elsewhere; the window
            // closes with the dismissal, so there is nothing left to draw.
            Spacer()
        }
    }

    private func progressStep(_ progress: BrowserMigrationProgress) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(
                format: NSLocalizedString("app.browserMigration.run.unit",
                    value: "%1$@ — %2$d of %3$d",
                    comment: "Browser migration wizard - which unit of the run is being worked on; %1$@ is a Profile or Space name, %2$d the unit's number, %3$d how many there are"),
                progress.unitName, progress.unitIndex + 1, progress.unitCount))
                .font(.system(size: 13))

            // Counts what has landed, so the unit being worked on is not
            // drawn as finished.
            ProgressView(
                value: Double(progress.unitIndex),
                total: Double(progress.unitCount))

            Text(NSLocalizedString("app.browserMigration.run.keepsRunning",
                value: "You can close this window — the migration carries on, and this menu item brings you back to it.",
                comment: "Browser migration wizard - tells the user a run outlives the window"))
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()

            HStack {
                Spacer()
                Button(NSLocalizedString("app.browserMigration.run.closeButton", value: "Close",
                    comment: "Browser migration wizard - button closing the window while the run carries on"), action: onClose)
                    .keyboardShortcut(.cancelAction)
            }
        }
    }

    private func reportStep(_ report: BrowserMigrationReport) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(NSLocalizedString("app.browserMigration.report.subtitle",
                value: "The migration has finished. Here's what it created.",
                comment: "Browser migration wizard - explanation above the report"))
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(report.profiles) { profile in
                        VStack(alignment: .leading, spacing: 6) {
                            reportRow(profile.displayName,
                                ok: profile.created && profile.pinnedTabsComplete
                                    && profile.browserData != .failed,
                                note: Self.profileNote(profile),
                                weight: .medium)
                            ForEach(profile.spaces) { space in
                                reportRow(space.name,
                                    ok: space.created && space.bookmarks != .failed,
                                    note: Self.spaceNote(space),
                                    weight: .regular)
                                    .padding(.leading, 20)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }
            .frame(maxHeight: .infinity)

            HStack {
                Spacer()
                // Hidden when the run created no Space: there is nowhere to go.
                if let firstSpace = report.firstCreatedSpace {
                    Button(String(
                        format: NSLocalizedString("app.browserMigration.report.goToSpaceButton",
                            value: "Go to %@",
                            comment: "Browser migration wizard - button switching to the first Space the run created; %@ is that Space's name"),
                        firstSpace.name)
                    ) {
                        SpaceManager.shared.activateInFocusedWindow(spaceId: firstSpace.spaceID)
                        finish()
                    }
                }
                Button(NSLocalizedString("app.browserMigration.report.doneButton", value: "Done",
                    comment: "Browser migration wizard - button dismissing the report and closing the window"), action: finish)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func reportRow(
        _ name: String, ok: Bool, note: String?, weight: Font.Weight
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundColor(ok ? .green : .orange)
                Text(name).font(.system(size: 13, weight: weight))
            }
            // Under the name rather than beside it: a Profile's note carries its
            // data import, its extensions and its pinned tabs, which no single
            // line of this window holds.
            if let note {
                Text(note)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 22)
            }
        }
    }

    private static let notCreatedLabel = NSLocalizedString(
        "app.browserMigration.report.notCreated",
        value: "Not created",
        comment: "Browser migration wizard - outcome of a Profile or Space the run failed to create")

    /// A Profile says what its data import claimed and how many of the source's
    /// pinned entries became pinned tabs, once it exists.
    private static func profileNote(_ profile: BrowserMigrationReport.ProfileRow) -> String? {
        guard profile.created else { return notCreatedLabel }
        let notes = [browserDataNote(profile), extensionsNote(profile), pinnedTabsNote(profile)]
            .compactMap { $0 }
        return notes.isEmpty ? nil : notes.joined(separator: " · ")
    }

    /// Deliberately weaker than "imported": the Chromium side answers the whole
    /// request with one success flag, and reports success even when a denied
    /// Keychain prompt made it skip the cookies. History is capped at the
    /// importer's own limit, so it is "recent", never "all".
    private static func browserDataNote(
        _ profile: BrowserMigrationReport.ProfileRow
    ) -> String? {
        switch profile.browserData {
        case .notAttempted:
            return nil
        case .requested:
            return NSLocalizedString("app.browserMigration.report.browserDataRequested",
                value: "Recent history and cookies requested",
                comment: "Browser migration wizard - what a migrated Profile's data import asked for; deliberately not a claim that it landed")
        case .failed:
            return NSLocalizedString("app.browserMigration.report.browserDataFailed",
                value: "History, cookies and extensions couldn't be imported",
                comment: "Browser migration wizard - shown on a Profile whose history/cookies/extensions import failed")
        }
    }

    /// Triggered, never succeeded: the Chromium side installs extensions in the
    /// background and its per-extension result has no way back here.
    private static func extensionsNote(
        _ profile: BrowserMigrationReport.ProfileRow
    ) -> String? {
        // Named even at zero: a Profile that carried no extensions has to say
        // so rather than leave the reader unable to tell it from one Phi never
        // looked at.
        guard case .requested(let extensions) = profile.browserData else { return nil }
        return String.localizedStringWithFormat(
            NSLocalizedString("app.browserMigration.report.extensionsTriggered",
                value: "install triggered for %d extensions",
                comment: "Browser migration wizard - how many extensions a migrated Profile had installation started for; %d is the number of extensions"),
            extensions)
    }

    /// A Profile whose source had no pinned entries says nothing.
    private static func pinnedTabsNote(
        _ profile: BrowserMigrationReport.ProfileRow
    ) -> String? {
        guard profile.pinnedTabsPlanned > 0 else { return nil }
        if profile.pinnedTabsComplete {
            return String.localizedStringWithFormat(
                NSLocalizedString("app.browserMigration.report.pinnedTabCount",
                    value: "%d pinned tabs",
                    comment: "Browser migration wizard - how many pinned tabs a migrated Profile received; %d is the number of pinned tabs"),
                profile.pinnedTabsWritten)
        }
        return String.localizedStringWithFormat(
            NSLocalizedString("app.browserMigration.report.pinnedTabsDropped",
                value: "%d pinned tabs couldn't be created",
                comment: "Browser migration wizard - how many of a Profile's pinned entries the run could not turn into pinned tabs; %d is the number that were dropped"),
            profile.pinnedTabsPlanned - profile.pinnedTabsWritten)
    }

    /// A Space says what became of its Bookmarks once it exists; before that,
    /// there is only the Space's own failure to report.
    private static func spaceNote(_ space: BrowserMigrationReport.SpaceRow) -> String? {
        guard space.created else { return notCreatedLabel }
        switch space.bookmarks {
        case .notAttempted:
            return nil
        case .written(let count):
            // Shown even at zero: a Space that received nothing has to say so
            // rather than read as a plain success.
            return String.localizedStringWithFormat(
                NSLocalizedString("app.browserMigration.report.bookmarkCount",
                    value: "%d bookmarks",
                    comment: "Browser migration wizard - how many bookmarks a migrated Space received; %d is the number of bookmarks"),
                count)
        case .failed:
            return NSLocalizedString("app.browserMigration.report.bookmarksFailed",
                value: "Bookmarks couldn't be saved",
                comment: "Browser migration wizard - shown on a Space whose Bookmarks did not persist")
        }
    }

    /// Dismisses the report and sends the wizard back to its source list, then
    /// closes the window — which is not released, so the next open finds this
    /// same wizard. Closing it any other way leaves the report to come back to.
    private func finish() {
        BrowserMigrationRunner.shared.dismissReport()
        model.backToPick()
        onClose()
    }
}
