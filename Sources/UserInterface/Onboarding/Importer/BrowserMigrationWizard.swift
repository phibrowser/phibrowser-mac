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

    /// A cheap presence check: the menu item validates this on every menu open,
    /// so it must not parse the source's data. That happens once, when the
    /// wizard opens.
    var isInstalled: Bool {
        switch self {
        case .arc:
            return FileManager.default.fileExists(
                atPath: BrowserDataImporter.arcUserDataURL.path)
        }
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
                        colorHex: plannedSpace?.colorHex ?? space.colorHex,
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
    }

    /// Identifies this run, and with it every Space, pinned tab and pin lineage
    /// the plan names, so the same input plans the same way twice.
    let operationID = UUID()
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

    /// Where the run begins. The executor lands with its own ticket; until then
    /// the wizard is preview-only and this only records what would have run.
    func start() {
        guard canStart else { return }
        AppLogInfo(
            "Browser migration start requested from "
                + "\(pickedSource?.displayName ?? "no source"): "
                + "\(plannedProfileCount) Profiles, \(plannedSpaceCount) Spaces")
    }

    private func rebuild() {
        guard let source else { return }
        let plan = BrowserMigrationPlanner.plan(
            source: source,
            existingProfileDisplayNames: ProfileManager.shared.profiles.map(\.displayName),
            pinnedTabScope: AccountController.shared.localDataAccount?
                .localStorage.pinnedTabScope() ?? .profile,
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
}
