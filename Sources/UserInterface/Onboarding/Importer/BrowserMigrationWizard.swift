// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import SwiftUI

// MARK: - Migration Sources

/// A browser a Migration can be run from. Arc and Zen so far; Dia becomes a
/// further case without the wizard learning anything about it — it knows a
/// source only through this type and the model the source hands back.
enum BrowserMigrationSourceKind: String, CaseIterable, Identifiable {
    case arc
    case zen

    var id: String { rawValue }

    /// A product name, so not localized.
    var displayName: String {
        switch self {
        case .arc: return "Arc"
        case .zen: return "Zen"
        }
    }

    /// The browser's own app icon — it is recognised by that before its name is
    /// read. Arc's is the image the import window already shows.
    var appIcon: ImageResource {
        switch self {
        case .arc: return .arcIcon
        case .zen: return .zenIcon
        }
    }

    /// The Chromium-side importer this source's data comes through.
    var browserType: BrowserType {
        switch self {
        case .arc: return .arc
        case .zen: return .zen
        }
    }

    /// The directory the source's per-profile directories sit in — a source
    /// profile's key is its basename there, which is also what the
    /// Chromium-side importer resolves — and where the Web Store extension
    /// list is read from. Zen's profiles carry none: Firefox extensions do not
    /// migrate.
    var userDataURL: URL {
        switch self {
        case .arc: return BrowserDataImporter.arcUserDataURL
        case .zen: return BrowserDataImporter.zenProfilesURL
        }
    }

    /// Every data type this source supports — Migration has no per-type
    /// toggles, so it always asks for all of them. What a browser supports is
    /// `ImportDataType`'s to say, not this enum's. Bookmarks are the one
    /// subtraction, for Arc and Zen alike: Phi parses their sidebars itself
    /// and writes each Space's tree Mac-side, the same strip the import window
    /// makes. (Zen's table lists history alone today, so for it the strip is
    /// the rule stated rather than a change.)
    var migrationDataTypes: [String] {
        requestedDataTypes.map(\.rawValue)
    }

    /// `migrationDataTypes` before the bridge's string keys — and what the
    /// report's Profile row answers for, since it answers for nothing else:
    /// data the source keeps that no ticket carries yet (Zen's cookies,
    /// Firefox bookmarks and extensions) is not on the row at all, by
    /// direction (2026-08-31), so a data type Zen's table gains later is
    /// asked for and reported without a second list to keep in step.
    var requestedDataTypes: [ImportDataType] {
        let supported = ImportDataType.availableTypes(for: browserType)
        switch self {
        case .arc, .zen:
            return supported.filter { $0 != .bookmarks }
        }
    }

    /// A non-blocking notice shown before a run starts, or nil when the source
    /// has none to give right now. Per source, and conditional: Arc and Dia
    /// share one, always — the Chromium importer decrypts their cookies with a
    /// key it reads from their Keychain item, and builds a fresh decryptor —
    /// so asks again — for every Profile it imports into. Zen's is advice to
    /// quit it, only while it is running.
    var preflightHint: String? {
        preflightHint(sourceIsRunning: isRunning)
    }

    /// The rule apart from the running check, so it can be asserted without
    /// the source on the machine.
    func preflightHint(sourceIsRunning: Bool) -> String? {
        switch self {
        case .arc:
            return String(
                format: NSLocalizedString("app.browserMigration.preflight.keychain",
                    value: "macOS will ask to use %@'s encryption key so your cookies can come across. Choose “Always Allow”, or it asks again for every Profile.",
                    comment: "Browser migration wizard - warns that the OS Keychain prompt is coming before a run starts; %@ is the source browser's name"),
                displayName)
        case .zen:
            // The Firefox importer copies Zen's main database files and misses
            // what a running Zen has not yet checkpointed, so the advice is
            // only worth giving while it runs. No Keychain hint: Zen's data is
            // unencrypted.
            guard sourceIsRunning else { return nil }
            return NSLocalizedString("app.browserMigration.preflight.quitZen",
                value: "Zen is running. Quit it before you start so its latest changes come across — Phi reads copies of Zen's files, and anything Zen hasn't saved yet would be missed.",
                comment: "Browser migration wizard - advises quitting Zen before a run starts; shown only while Zen is running")
        }
    }

    /// What the running check looks the source up by.
    private var bundleIdentifier: String {
        switch self {
        case .arc: return "company.thebrowser.Browser"
        case .zen: return "app.zen-browser.zen"
        }
    }

    /// Whether the source browser is open right now — a bundle-identifier
    /// check, nothing parsed.
    private var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty
    }

    /// A cheap presence check: the menu item validates this on every menu open,
    /// so it must not parse the source's data. That happens once, when the
    /// wizard opens. Arc is its Chromium user-data directory; Zen is its
    /// `profiles.ini`.
    var isInstalled: Bool {
        let marker: URL
        switch self {
        case .arc: marker = userDataURL
        case .zen: marker = BrowserDataImporter.zenProfilesINIURL
        }
        return FileManager.default.fileExists(atPath: marker.path)
    }

    /// Every source alphabetically. Separate from `installed` so the ordering
    /// can be asserted without a real install of anything.
    static var allInDisplayOrder: [BrowserMigrationSourceKind] {
        allCases.sorted { $0.displayName < $1.displayName }
    }

    /// The sources present on this machine, in that same order.
    static var installed: [BrowserMigrationSourceKind] {
        allInDisplayOrder.filter(\.isInstalled)
    }

    /// Reads the whole source model. Nil when the source is installed but its
    /// own data cannot be read — a missing or malformed sidebar file, a
    /// malformed session or containers file.
    func loadSource() -> BrowserMigrationSource? {
        switch self {
        case .arc:
            return BrowserDataImporter().loadArcMigrationSource()?.migrationSource
        case .zen:
            return BrowserDataImporter().loadZenMigrationSource()?.migrationSource
        }
    }
}

// MARK: - Preview rows

/// One Space row of the preview.
struct BrowserMigrationPreviewSpaceRow: Equatable, Identifiable {
    let sourceSpaceID: String
    let name: String
    /// The built-in theme the run pins — what the row's swatch is drawn from,
    /// and the only colour the preview can honestly promise. The plan's own
    /// `colorHex` is this theme's overlay hue, a brighter and different colour
    /// from the one Space settings shows for the same theme, so the row carries
    /// the theme rather than a colour.
    let themeID: String
    /// The Phi icon storage value the run will give the Space — what the row's
    /// icon is drawn from, so the preview shows the glyph the strip will show.
    let iconName: String
    let isTicked: Bool
    /// True when the source could not read this Space's own profile record, so
    /// it follows the default profile's Profile and has no tick of its own.
    let boundToDefaultProfile: Bool

    var id: String { sourceSpaceID }
}

/// How much of a Profile the plan takes. A Profile is never ticked in its own
/// right — it follows its Spaces — so its box has three states, and `mixed` is
/// the one the plan can produce that a two-state checkbox cannot show.
enum BrowserMigrationPreviewTick: Equatable {
    case on
    case mixed
    case off
}

/// One Profile row of the preview, with its Spaces beneath it.
struct BrowserMigrationPreviewProfileRow: Equatable, Identifiable {
    let sourceProfileKey: String
    /// The Profile's planned display name — suffixed against collisions —
    /// while it is ticked; the source's own name while it is not, because an
    /// unticked Profile is not in the plan and has no name to collide with.
    let displayName: String
    let tick: BrowserMigrationPreviewTick
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
            let spaces = source.spaces(ofProfile: key).map { space in
                let plannedSpace = plannedSpaces[space.id]
                return BrowserMigrationPreviewSpaceRow(
                    sourceSpaceID: space.id,
                    name: plannedSpace?.name ?? space.name,
                    // An unticked Space is not in the plan, so it falls back to
                    // the same resolution the planner would have made — or
                    // unticking one would appear to restyle it.
                    themeID: plannedSpace?.themeID
                        ?? BrowserMigrationSpaceTheme.resolved(
                            forSourceColorHex: space.colorHex).themeID,
                    iconName: plannedSpace?.iconName
                        ?? BrowserMigrationPlanner.spaceIconName(for: space.icon),
                    isTicked: plannedSpace != nil,
                    boundToDefaultProfile: plannedSpace?.boundToDefaultProfile
                        ?? source.bindsToDefaultProfile(space)
                )
            }
            return BrowserMigrationPreviewProfileRow(
                sourceProfileKey: key,
                displayName: displayName,
                tick: tick(of: spaces),
                skipReason: skipped?.reason,
                spaces: spaces
            )
        }
    }

    /// True when the source read fine and still offers nothing: every profile
    /// it has creates nothing whatever the user ticks — including a source that
    /// lists no profiles at all, which offers nothing by having nothing. A
    /// source that could not be *read* produces no rows and never reaches the
    /// preview, so that state is a different one and not this.
    static func hasNothingToMigrate(rows: [BrowserMigrationPreviewProfileRow]) -> Bool {
        rows.allSatisfy { $0.skipReason != nil }
    }

    /// A Profile follows its Spaces, so its box states how many of them the
    /// plan took. A Profile with no Spaces is off: there is nothing for a tick
    /// to mean.
    private static func tick(
        of spaces: [BrowserMigrationPreviewSpaceRow]
    ) -> BrowserMigrationPreviewTick {
        let ticked = spaces.filter(\.isTicked).count
        if ticked == 0 { return .off }
        return ticked == spaces.count ? .on : .mixed
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
    /// Any pick clears an unreadable source's notice, including re-picking the
    /// card that failed — which is the only way back when that card is the only
    /// source, and the notice tells the user to go and fix it and try again.
    @Published var pickedSource: BrowserMigrationSourceKind? {
        didSet { sourceUnreadable = false }
    }
    @Published private(set) var plan: BrowserMigrationPlan?
    @Published private(set) var rows: [BrowserMigrationPreviewProfileRow] = []
    /// Set when the picked source is installed but its data could not be read.
    @Published private(set) var sourceUnreadable = false
    /// Set when Start was pressed against a source this account has already
    /// migrated from. Nothing runs until the user answers: Migration only ever
    /// creates, so a second run leaves the first one's Profiles and Spaces
    /// where they are and makes a fresh set beside them.
    @Published var isConfirmingRerun = false

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

    /// The source read fine and offers nothing: distinct from a source that
    /// could not be read, which never gets this far, and from a user who has
    /// unticked everything, who can tick it back.
    var hasNothingToMigrate: Bool {
        source != nil && BrowserMigrationPreview.hasNothingToMigrate(rows: rows)
    }

    var canStart: Bool { isAccountBound && plannedProfileCount > 0 }

    /// Whether a run would be a second Migration from this source into an
    /// account that still holds what the first one created — the one predicate
    /// behind the body's banner, the footer's line and the confirmation, so
    /// the three cannot disagree.
    ///
    /// Answered on every read rather than snapshotted when the preview opens,
    /// so the value `start()` gates on is never stale — an account signed into
    /// while this step is open used to leave a cached `false` behind and skip
    /// the confirmation outright. On screen it is only as fresh as the next
    /// render, exactly like `isAccountBound` beside it: nothing here observes
    /// the account.
    var warnsAboutRerun: Bool {
        guard let pickedSource else { return false }
        return Self.warnsBeforeRerun(
            hasMigrated: BrowserMigrationRunner.hasMigrated(from: pickedSource),
            spaceCount: currentSpaceCount)
    }

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

    /// Starts the previewed run, asking first when a second Migration would
    /// leave the account with two copies of the same thing.
    func start() {
        if warnsAboutRerun {
            isConfirmingRerun = true
            return
        }
        beginRun()
    }

    /// The warning is about ending up with two copies, so the mark alone is not
    /// enough: an account down to a single Space no longer holds what the first
    /// Migration created, and warning it about a duplicate would be a warning
    /// about nothing.
    static func warnsBeforeRerun(hasMigrated: Bool, spaceCount: Int) -> Bool {
        hasMigrated && spaceCount > 1
    }

    /// Read from the store rather than from `SpaceManager`'s published list,
    /// which delivers partially at launch — a first delivery carrying only the
    /// default Space would read as an emptied account and drop the warning.
    /// Counted rather than fetched: this is read once per render of the
    /// preview, and only its size is ever wanted.
    private var currentSpaceCount: Int {
        AccountController.shared.localDataAccount?.localStorage.spaceCount() ?? 0
    }

    /// Hands the plan to the process-level runner and follows it. The run
    /// belongs to the process from here on: closing this window does not
    /// interrupt it.
    ///
    /// Called by the re-run confirmation as well as by `start`, so it does not
    /// ask again.
    func beginRun() {
        isConfirmingRerun = false
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

/// The import window's white-at-alpha text ladder. This window wears that
/// window's dress and is hard-coded dark with it, so text is painted rather
/// than themed — a themed token would follow the Space's colours onto a ground
/// that is not the Space's.
private enum Ink {
    static let primary = Color.white
    static let secondary = Color.white.opacity(0.7)
    static let hint = Color.white.opacity(0.5)
    /// What the import window dims a row it has switched off to.
    static let disabled = Color.white.opacity(0.4)
}

/// The corner radius the import window gives every container, and this window
/// now gives every card.
private let migrationCardRadius: CGFloat = 14

private extension View {
    /// The import window's card: a translucent white block at that radius. It
    /// stands where `settingsCardChrome()` did — this window tracks its
    /// neighbour rather than Preferences now.
    func migrationCard() -> some View {
        background(Color.white.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: migrationCardRadius, style: .continuous))
    }

    /// This view at its own height while it fits the space it is offered, and
    /// past that the same view scrolling inside that space. It is what lets a
    /// step's content sit centred when it is short and fill when it is long.
    func scrollsWhenTall() -> some View {
        ViewThatFits(in: .vertical) {
            self
            ScrollView { self }
        }
    }
}

struct BrowserMigrationWizardView: View {
    /// Fixed, and larger than the import window's 500x700. The window takes its
    /// size from here rather than the other way round: a hosting controller
    /// sizes its window from the view's fitting size, so a view that asks to
    /// fill grows the window instead of being bounded by it.
    static let windowSize = CGSize(width: 640, height: 720)

    /// The horizontal inset shared by all three bands.
    private static let bandInset: CGFloat = 24
    /// Where the import window's standalone mode puts its title: 56pt from the
    /// window's top edge, which both windows draw under their transparent
    /// titlebars, so the band clears the window controls by the same margin.
    private static let headerTopInset: CGFloat = 56
    /// Fixed whatever the step, so the body starts at one height on every step.
    /// The tallest step is Source: the brand face's 48pt line at 32, the import
    /// window's 12pt to its caption, and a subtitle that runs to two 18pt lines
    /// at the column width — 160 once the band's own insets are added.
    private static let headerBandHeight: CGFloat = 164
    /// The import window's container width for a 640pt-wide window, centred as
    /// it is there. Every step's body keeps to it, as do the subtitle and the
    /// footer's reason line.
    private static let contentColumnWidth: CGFloat = 472
    /// The import window's CTA geometry. Both slots are reserved on every step,
    /// so the band does not move under a step that fills only one of them —
    /// Migrating, whose single button is a secondary.
    private static let footerPrimaryHeight: CGFloat = 40
    private static let footerPrimaryMinWidth: CGFloat = 120
    /// Fixed for the same reason the header band is: the body must end at one
    /// height on every step too. 10 + a reason line that runs to two 13pt
    /// lines + 10 + both button slots + the onboarding bottom margin, which
    /// only Review ever fills.
    private static let footerBandHeight: CGFloat = 190
    /// Where the onboarding pages put their CTA pair: the primary's bottom
    /// edge 96pt above the window's and the secondary 8pt under it
    /// (`OnboardingBaseViewController`'s Next and Skip constraints), so the
    /// secondary slot ends 96 − 8 − 20 above the window's bottom.
    private static let footerBottomInset: CGFloat = 68
    /// Half the window: past this the title truncates rather than the button
    /// running off the band. Only "Go to %@" can reach it, and only because a
    /// Space name is the user's to make as long as they like.
    private static let footerPrimaryMaxWidth: CGFloat = 320
    private static let footerSecondaryHeight: CGFloat = 20

    /// The import window's two background layers: its wallpaper, aspect-filled
    /// so a window that is not its 4:5 crops instead of letterboxing, under its
    /// dot image at the same 0.08. The looping video that window fades in over
    /// the wallpaper is deliberately left out — it is the same appearance plus
    /// an `AVPlayer` running for the length of a migration rather than for the
    /// few seconds an onboarding step lasts. One representable adds it if the
    /// motion is ever wanted.
    private static var ground: some View {
        Image(.loginWallpaper)
            .resizable()
            .scaledToFill()
            .overlay {
                Image(.dotBg)
                    .resizable()
                    .scaledToFill()
                    .opacity(0.08)
            }
            .clipped()
    }

    @StateObject private var model: BrowserMigrationWizardModel
    /// The run is the process's, not this window's, so the view observes it
    /// where it lives rather than owning it.
    @ObservedObject private var runner = BrowserMigrationRunner.shared
    private let onClose: () -> Void

    init(model: BrowserMigrationWizardModel, onClose: @escaping () -> Void) {
        _model = StateObject(wrappedValue: model)
        self.onClose = onClose
    }

    /// Header, body and footer have the same geometry on every step; changing
    /// step swaps only the body.
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            stepBody
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.horizontal, Self.bandInset)
                // The import window lets its container sit 8pt under its caption.
                .padding(.top, 8)
                .padding(.bottom, 12)
            footer
        }
        .frame(
            width: Self.windowSize.width,
            height: Self.windowSize.height,
            alignment: .topLeading)
        .background { Self.ground }
        // The window's content runs under its transparent titlebar, which the
        // hosting view would otherwise reserve as safe area — pushing the whole
        // frame down by the titlebar's height on top of the inset the header
        // band already carries.
        .ignoresSafeArea()
    }

    // MARK: Header band

    /// Centred, as the import window's title and the caption under it are, and
    /// at that window's spacing between the two.
    private var header: some View {
        VStack(spacing: 12) {
            Text(stepHeading)
                .font(headingFont(stepHeading))
                .foregroundColor(Ink.primary)
                // One line, for the same reason the subtitle is capped at two:
                // the band's height is fixed and a second 48pt line would run
                // the heading into the body.
                .lineLimit(1)
            if let stepSubtitle {
                Text(stepSubtitle)
                    .font(.system(size: 15))
                    .foregroundColor(Ink.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    // The band's height is fixed so the body cannot move, so a
                    // subtitle longer than English's must truncate inside it
                    // rather than run into the body.
                    .lineLimit(2)
                    .frame(maxWidth: Self.contentColumnWidth)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Self.bandInset)
        .padding(.top, Self.headerTopInset)
        .padding(.bottom, 8)
        .frame(height: Self.headerBandHeight, alignment: .top)
    }

    /// The onboarding brand face the import window titles itself in. Built
    /// through the fallback helper rather than by name: the face is Latin-only
    /// and every step heading is a localized string, so a non-Latin
    /// localization has to come out in the system face rather than as tofu.
    /// Every step takes that window's standalone size.
    private func headingFont(_ heading: String) -> Font {
        Font(NSFont.brandDisplay(
            OnboardingBaseViewController.titleFontName,
            size: 32,
            renders: heading))
    }

    /// Each step names itself, so no step rail is needed to say where the user
    /// is.
    private var stepHeading: String {
        switch model.step {
        case .pick:
            return NSLocalizedString("app.browserMigration.title", value: "Migrate to Phi",
                comment: "Browser migration wizard - heading of the source step; the window title is a key of its own")
        case .preview:
            return NSLocalizedString("app.browserMigration.preview.heading",
                value: "Review what will be created",
                comment: "Browser migration wizard - heading of the review step")
        case .run:
            if case .finished = runner.state {
                return NSLocalizedString("app.browserMigration.report.heading",
                    value: "Migration finished",
                    comment: "Browser migration wizard - heading of the report shown once a run has ended")
            }
            return NSLocalizedString("app.browserMigration.run.heading", value: "Migrating…",
                comment: "Browser migration wizard - heading while a run is working")
        }
    }

    private var stepSubtitle: String? {
        switch model.step {
        case .pick:
            // Nothing to choose between, so the promise about choosing is not
            // made; the body carries the whole message instead.
            guard !model.installedSources.isEmpty else { return nil }
            return NSLocalizedString("app.browserMigration.pick.subtitle",
                value: "Phi recreates your Profiles and Spaces from another browser. It only ever creates — nothing you already have is changed.",
                comment: "Browser migration wizard - explanation above the source list")
        case .preview:
            return nil
        case .run:
            if case .finished = runner.state { return nil }
            return NSLocalizedString("app.browserMigration.run.subtitle",
                value: "This can take a few minutes.",
                comment: "Browser migration wizard - subtitle shown while a run is working")
        }
    }

    // MARK: Body band

    @ViewBuilder
    private var stepBody: some View {
        switch model.step {
        case .pick:
            pickBody
        case .preview:
            previewBody
        case .run:
            runBody
        }
    }

    // MARK: Footer band

    private var footer: some View {
        let buttons = footerButtons
        return VStack(spacing: 10) {
            if let contextLine {
                Text(contextLine)
                    // The reason a disabled button is disabled has to be read,
                    // so it takes the secondary rung rather than the hint one.
                    .font(.system(size: 13))
                    .foregroundColor(Ink.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    // The band's height is fixed, so a reason longer than
                    // English's truncates inside it rather than pushing the
                    // buttons out of the band.
                    .lineLimit(2)
                    .frame(maxWidth: Self.contentColumnWidth)
            }
            // Holds the buttons against the bottom of the band whether or not
            // the step has a reason to give, so they sit at one height on all
            // four.
            Spacer(minLength: 0)
            VStack(spacing: 8) {
                ZStack {
                    if let primary = buttons.primary { primaryButton(primary) }
                }
                .frame(height: Self.footerPrimaryHeight)
                HStack(spacing: 24) {
                    ForEach(buttons.secondary) { secondaryButton($0) }
                }
                .frame(height: Self.footerSecondaryHeight)
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Self.bandInset)
        .padding(.top, 10)
        .padding(.bottom, Self.footerBottomInset)
        .frame(height: Self.footerBandHeight)
    }

    /// The one line the footer speaks, and only when Start is disabled for a
    /// reason nothing else on the step states. First applicable wins — it is
    /// never disabled without one showing somewhere. A second Migration is not
    /// one of them: the banner under the tree says so, and the confirmation on
    /// Start says it again.
    private var contextLine: String? {
        guard model.step == .preview else { return nil }
        if !model.isAccountBound {
            return NSLocalizedString("app.browserMigration.preview.accountRequired",
                value: "Sign in to Phi — or continue as a guest — before migrating.",
                comment: "Browser migration wizard - shown instead of starting when no account is bound")
        }
        // The well under the tree, directly above this band, already says so;
        // and it also empties the plan, so the nothing-ticked line must not
        // speak for it either.
        if model.hasNothingToMigrate { return nil }
        if model.plannedProfileCount == 0 {
            return NSLocalizedString("app.browserMigration.preview.nothingTicked",
                value: "Choose at least one Space to migrate.",
                comment: "Browser migration wizard - why Start is disabled when the user has unticked everything")
        }
        return nil
    }

    /// The picked source's name, which every line about the source interpolates.
    /// Empty only on a step that has no source, where none of them is drawn.
    private var sourceName: String { model.pickedSource?.displayName ?? "" }

    /// The browser the report's run actually read from. Not the wizard's
    /// current pick: a run outlives the window, and the one reopened over a
    /// finished run may have moved the pick on since.
    private var reportSourceName: String {
        runner.runSource?.displayName ?? sourceName
    }

    private static let cancelLabel = NSLocalizedString(
        "app.browserMigration.preview.cancelButton", value: "Cancel",
        comment: "Browser migration wizard - button closing the wizard without migrating")

    private static let continueLabel = NSLocalizedString(
        "app.browserMigration.pick.continueButton", value: "Continue",
        comment: "Browser migration wizard - button that opens the preview for the picked source")

    private static let backLabel = NSLocalizedString(
        "app.browserMigration.preview.backButton", value: "Back",
        comment: "Browser migration wizard - button returning from the preview to the source list")

    private static let startLabel = NSLocalizedString(
        "app.browserMigration.preview.startButton", value: "Start Migration",
        comment: "Browser migration wizard - button starting the migration run")

    private static let doneLabel = NSLocalizedString(
        "app.browserMigration.report.doneButton", value: "Done",
        comment: "Browser migration wizard - button dismissing the report and closing the window")

    private static let goToSpaceFormat = NSLocalizedString(
        "app.browserMigration.report.goToSpaceButton", value: "Go to %@",
        comment: "Browser migration wizard - button switching to the first Space the run created; %@ is that Space's name")

    private static let closeLabel = NSLocalizedString(
        "app.browserMigration.run.closeButton", value: "Close",
        comment: "Browser migration wizard - button closing the window while the run carries on")

    /// One button in the footer: what it says, whether it can be pressed, and
    /// whether Escape presses it.
    private struct FooterButton: Identifiable {
        /// The title identifies it: no step draws the same one twice, and an
        /// index would hand Cancel's identity to Back when the step changes.
        var id: String { title }
        let title: String
        var isEnabled = true
        var isCancel = false
        let action: () -> Void
    }

    /// The step's buttons, split once rather than at each of the two slots that
    /// draw them: the default action goes in the gradient primary and the rest
    /// in the borderless row under it, so the slots cannot disagree about which
    /// button is which.
    private var footerButtons: (primary: FooterButton?, secondary: [FooterButton]) {
        let cancel = FooterButton(title: Self.cancelLabel, isCancel: true, action: onClose)
        switch model.step {
        case .pick:
            // Withheld rather than disabled when nothing was detected: there is
            // no source to enable it for.
            guard !model.installedSources.isEmpty else { return (nil, [cancel]) }
            return (
                FooterButton(
                    title: Self.continueLabel,
                    isEnabled: model.pickedSource != nil && !model.sourceUnreadable,
                    action: { model.showPreview() }),
                [cancel])
        case .preview:
            return (
                FooterButton(
                    title: Self.startLabel,
                    isEnabled: model.canStart,
                    action: { model.start() }),
                [
                    // The only way back, and only from Review: it is gone the
                    // instant Start is pressed, because a run cannot be undone.
                    FooterButton(title: Self.backLabel, action: { model.backToPick() }),
                    cancel,
                ])
        case .run:
            guard case .finished(let report) = runner.state else {
                return (nil, [FooterButton(title: Self.closeLabel, isCancel: true, action: onClose)])
            }
            let done = FooterButton(title: Self.doneLabel, action: finish)
            // The report exists to land the user in what they migrated, so the
            // jump is the default action and Done is the fallback beside it.
            // Pressing Return on the report therefore switches Spaces rather
            // than closing, which is intended. With no Space created there is
            // nowhere to go, and Done takes the primary's place alone.
            guard let firstSpace = report.firstCreatedSpace else { return (done, []) }
            return (
                FooterButton(title: String(format: Self.goToSpaceFormat, firstSpace.name)) {
                    SpaceManager.shared.activateInFocusedWindow(spaceId: firstSpace.spaceID)
                    finish()
                },
                [done])
        }
    }

    private func primaryButton(_ button: FooterButton) -> some View {
        GradientBorderButtonView(
            title: button.title,
            isEnabled: button.isEnabled,
            width: Self.primaryButtonWidth(button.title),
            height: Self.footerPrimaryHeight,
            action: button.action)
            // The button's own label would wrap inside its fixed height rather
            // than truncate, and two lines of 16pt do not belong in 40.
            .lineLimit(1)
            // The import window's own disabled affordance: switched off and
            // dimmed with it, rather than switched off alone. Switched off here
            // as well as inside the button, so the keyboard shortcut below is
            // bound to a control this view has already disabled.
            .disabled(!button.isEnabled)
            .opacity(button.isEnabled ? 1 : 0.5)
            // The gradient border stands in for the default button's ring,
            // which a plain view does not draw; the binding is still needed.
            .keyboardShortcut(.defaultAction)
    }

    private func secondaryButton(_ button: FooterButton) -> some View {
        Button(button.title, action: button.action)
            .buttonStyle(.plain)
            // The import window's Skip: the primary's size in the regular
            // weight, so the pair differ by weight rather than by size.
            .font(.system(size: 16))
            .foregroundColor(Ink.hint)
            .lineLimit(1)
            // The same affordance the primary uses, so a secondary that is ever
            // switched off looks switched off rather than merely inert.
            .disabled(!button.isEnabled)
            .opacity(button.isEnabled ? 1 : 0.5)
            .keyboardShortcut(button.isCancel ? KeyboardShortcut.cancelAction : nil)
    }

    /// The import window's CTA is a hard 120 x 40; this one keeps the height
    /// and treats the width as a floor. That button lays its title out with no
    /// horizontal padding of its own, and "Go to %@" carries a Space name the
    /// user made — at 120 anything past "Go to Personal" is an ellipsis, and
    /// "Start Migration" sits 4pt from the border on each side.
    private static func primaryButtonWidth(_ title: String) -> CGFloat {
        let width = (title as NSString)
            .size(withAttributes: [.font: GradientBorderButtonView.titleFont])
            .width
        return min(footerPrimaryMaxWidth, max(footerPrimaryMinWidth, ceil(width) + 32))
    }

    // MARK: Pick

    /// The import window's row at this window's width: 68 tall, 18pt in from
    /// either edge, a 32pt icon and an 18pt name, at r8.
    private static let sourceRowHeight: CGFloat = 68

    @ViewBuilder
    private var pickBody: some View {
        if model.installedSources.isEmpty {
            // Reachable only if a source disappears between the menu validating
            // it and this window opening — but an empty window would say less
            // than one sentence does.
            Text(NSLocalizedString("app.browserMigration.pick.noSourcesFound",
                value: "Phi didn't find Arc, Dia or Zen on this Mac.",
                comment: "Browser migration wizard - shown in place of the source list when none of the browsers Phi can migrate from is installed"))
                .font(.system(size: 15))
                .foregroundColor(Ink.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                // One container round every row, as the import window lays its
                // sources out: its 8pt inside the card and between rows.
                VStack(spacing: 8) {
                    ForEach(model.installedSources) { source in
                        sourceRow(source)
                    }
                }
                .padding(8)
                .migrationCard()

                if model.sourceUnreadable, let source = model.pickedSource {
                    unreadableNotice(source)
                }
            }
            .frame(width: Self.contentColumnWidth)
            // Centred in the band, as the import window centres its container
            // in the window, rather than hugging the subtitle.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The browser's icon and its name, and nothing else: the step's job is to
    /// identify a browser, and the preview is one click away.
    private func sourceRow(_ source: BrowserMigrationSourceKind) -> some View {
        let isSelected = model.pickedSource == source
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        return Button {
            model.pickedSource = source
        } label: {
            HStack(spacing: 16) {
                // Selection reads on this glyph as well as on the row, so it is
                // never carried by colour alone. Hidden from VoiceOver, which
                // reads the row's own selected trait instead.
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 16))
                    .foregroundColor(isSelected ? Ink.primary : Ink.hint)
                    .accessibilityHidden(true)
                Image(source.appIcon)
                    .resizable()
                    .frame(width: 32, height: 32)
                Text(source.displayName)
                    .font(.system(size: 18))
                    .foregroundColor(Ink.primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity, minHeight: Self.sourceRowHeight, alignment: .leading)
            // The import window's mark for the row it has taken: the same
            // translucent fill as the container, and no ring. Unselected rows
            // carry nothing, exactly as its rows do not.
            .background(isSelected ? Color.white.opacity(0.1) : Color.clear)
            .clipShape(shape)
            // The whole row is the hit target — but only the row: clipping the
            // ground does not clip the hit region.
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// Says what to do about a source Phi could not read, rather than only that
    /// it failed. Inline under the cards: the source is still selected, and an
    /// alert would take the cards away while it is read.
    private func unreadableNotice(_ source: BrowserMigrationSourceKind) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
                .accessibilityHidden(true)
            Text(String(
                format: NSLocalizedString("app.browserMigration.pick.unreadable",
                    value: "Phi couldn't read %1$@'s data. Open %1$@ once so it writes its sidebar, then try again.",
                    comment: "Browser migration wizard - shown when the picked source is installed but its data can't be parsed; %1$@ is the source browser's name, appearing twice"),
                source.displayName))
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 13))
        .foregroundColor(Ink.secondary)
    }

    // MARK: Preview

    private var previewBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            // The tree is the step's subject, so it takes the middle of the
            // band, with the wells held against the footer beneath it. The
            // card is as tall as the tree while that fits; past that the card
            // holds still and the rows scroll inside it, so its corners never
            // scroll out of view.
            VStack(alignment: .leading, spacing: 12) {
                treeRows
                    .padding(12)
                    .scrollsWhenTall()
                    .migrationCard()

                // Withheld while the plan creates nothing: "Will create 0
                // Profiles and 0 Spaces." is a total nobody asked for, whether
                // the source offers nothing or the user has unticked everything.
                if model.plannedProfileCount > 0 {
                    Text(summary)
                        .font(.system(size: 13))
                        .foregroundColor(Ink.secondary)
                }
            }
            .frame(maxHeight: .infinity)

            // What pressing Start entails, between the tree and the button
            // rather than ahead of the tree: the step is about what will be
            // created, and these are read on the way to Start. Outside the
            // scroll, so the tree's length never hides them.
            if model.warnsAboutRerun {
                fieldWell(String(
                    format: NSLocalizedString("app.browserMigration.preview.alreadyMigratedBanner",
                        value: "You already migrated from %@ for this account. Migrating again creates a second set of Profiles and Spaces — it doesn't update the first.",
                        comment: "Browser migration wizard - stated before Start that a run would be a second migration; %@ is the source browser's name"),
                    sourceName))
            }

            // One slot, and what is wrong wins it: a run that will not happen
            // prompts for nothing, so the source's hint gives way rather than
            // stacking underneath it.
            if model.hasNothingToMigrate {
                fieldWell(String(
                    format: NSLocalizedString("app.browserMigration.preview.nothingToMigrate",
                        value: "Phi found %1$@, but there's nothing here to migrate — no %2$@ profile has data Phi can move.",
                        comment: "Browser migration wizard - shown under the tree when the source read fine and offers nothing; %1$@ and %2$@ are both the source browser's name"),
                    sourceName, sourceName))
            } else if let hint = model.pickedSource?.preflightHint {
                // Said before anything starts rather than when it would
                // matter: Arc's Keychain prompt is asked again for every
                // Profile of a serial run, and a running Zen's recent changes
                // are missed silently. It stands under the tree and never in
                // the footer's conditional line, which is spoken for by
                // whatever is wrong.
                fieldWell(hint)
            }
        }
        .frame(width: Self.contentColumnWidth)
        .frame(maxWidth: .infinity)
        .alert(
            String(
                format: NSLocalizedString("app.browserMigration.rerun.title",
                    value: "Migrate from %@ again?",
                    comment: "Browser migration wizard - title of the confirmation shown when this account has already migrated from the picked source; %@ is the source browser's name"),
                model.pickedSource?.displayName ?? ""),
            isPresented: $model.isConfirmingRerun
        ) {
            Button(NSLocalizedString("app.browserMigration.rerun.confirmButton",
                value: "Migrate Again",
                comment: "Browser migration wizard - button starting a second migration from a source this account has already migrated from")) {
                model.beginRun()
            }
            // Return dismisses rather than confirms: a warning a held key can
            // walk through is no warning at all.
            Button(NSLocalizedString("app.browserMigration.rerun.cancelButton", value: "Cancel",
                comment: "Browser migration wizard - button dismissing the second-migration confirmation without starting anything"),
                role: .cancel) {}
                .keyboardShortcut(.defaultAction)
        } message: {
            Text(NSLocalizedString("app.browserMigration.rerun.message",
                value: "You've migrated from this browser into this account before. Phi will create a new set of Profiles and Spaces — the ones you already have stay exactly as they are.",
                comment: "Browser migration wizard - explains that a second migration creates a fresh set of Profiles and Spaces rather than updating the first one's"))
        }
    }

    private var treeRows: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(model.rows) { row in
                profileRow(row)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// What the ticked plan would create, under the tree it was read off. The
    /// report states actuals in the same shape, so this one keeps the future
    /// tense: an intention and an outcome must never read alike.
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

    /// A statement that is true for the whole step, in the same card the rest
    /// of the window is built from. Deliberately not a warning shape: nothing
    /// here is wrong, and the footer owns what is.
    private func fieldWell(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundColor(Ink.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .migrationCard()
    }

    @ViewBuilder
    private func profileRow(_ row: BrowserMigrationPreviewProfileRow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let skipReason = row.skipReason {
                // Skipped whatever the user ticks, so it carries no checkbox.
                HStack(spacing: 6) {
                    Text(row.displayName)
                        .font(.system(size: 15, weight: .medium))
                    Text(Self.skipReasonLabel(skipReason))
                        .font(.system(size: 13))
                }
                .foregroundColor(Ink.secondary)
                .padding(.leading, 20)
            } else {
                // The box and the name are separate views on purpose. An
                // `NSButton` carrying the name as its own title has an
                // unbounded intrinsic width, and `.fixedSize()` hands it that
                // width — so a long source Profile name ran outside the card
                // and the fixed 640pt window, which scrolls only vertically.
                // The box alone is a few points wide, so pinning it is safe,
                // and the name is a SwiftUI label that wraps within the row.
                // Mixed and off both mean "not all of it is in", so a click on
                // either takes every Space and only a click on a full box
                // clears them. Stated once here and handed to both the box and
                // the name, which are two ways to press the same thing.
                let toggleEverything = {
                    model.setProfile(row.sourceProfileKey, ticked: row.tick != .on)
                }
                HStack(alignment: .center, spacing: 6) {
                    MixedStateCheckbox(tick: row.tick, spokenName: row.displayName,
                                       onToggle: toggleEverything)
                        // An `NSButton` handed the whole proposed width would
                        // take the card's full row as its hit target, which the
                        // Space toggles beneath it do not.
                        .fixedSize()

                    Text(row.displayName)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(Ink.primary)
                        // Two lines then the middle goes: a Profile name is
                        // recognised by both ends, and wrapping alone does not
                        // bound an unbroken one — it would still run outside
                        // the card. The tooltip carries what the row drops.
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .help(row.displayName)
                        // The box is the accessible control and carries this
                        // name; reading it twice is worse than not reading it
                        // here at all. The tap is a convenience over that
                        // control, not the only way to reach it — it is what
                        // clicking the AppKit title used to do, and the row
                        // around it stays inert, as the Space rows are.
                        .accessibilityHidden(true)
                        .onTapGesture(perform: toggleEverything)
                }
            }

            ForEach(row.spaces) { space in
                spaceRow(space, destinationProfile: row.displayName)
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

    /// The theme pickers' dot and ring sizes, restated here so a preview swatch
    /// comes out the size the one in Space settings is.
    private static let themeSwatchDiameter: CGFloat = 16
    private static let themeSwatchRingDiameter: CGFloat = 20

    private func spaceRow(
        _ space: BrowserMigrationPreviewSpaceRow,
        destinationProfile: String
    ) -> some View {
        return Toggle(isOn: Binding(
            get: { space.isTicked },
            set: { model.setSpace(space.sourceSpaceID, ticked: $0) }
        )) {
            HStack(spacing: 8) {
                Self.spaceIcon(space.iconName)

                VStack(alignment: .leading, spacing: 2) {
                    // The swatch follows the name on the name's own line, so
                    // the note beneath does not pull it down.
                    HStack(spacing: 8) {
                        Text(space.name)
                            .font(.system(size: 15))
                            // The row has no tick of its own, so its name
                            // carries the import window's dimmed-row alpha.
                            // The note under it does not: it is the reason,
                            // and has to be read.
                            .foregroundColor(
                                space.boundToDefaultProfile ? Ink.disabled : Ink.primary)
                        Self.themeSwatch(forID: space.themeID)
                    }
                    if space.boundToDefaultProfile {
                        Text(String(
                            format: NSLocalizedString("app.browserMigration.preview.defaultProfileBound",
                                value: "Phi couldn't tell which profile this belongs to, so it will go to %@.",
                                comment: "Browser migration wizard - note on a Space whose source profile record is unreadable; %@ is the Profile it will be created under"),
                            destinationProfile))
                            .font(.system(size: 13))
                            .foregroundColor(Ink.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .toggleStyle(.checkbox)
        // It follows its Profile's tick and has no tick of its own.
        .disabled(space.boundToDefaultProfile)
        .padding(.leading, 20)
    }

    /// Falls back to the theme the planner itself falls back to, so an id this
    /// build does not know draws as the default rather than as nothing.
    private static func theme(ofID id: String) -> Theme {
        Theme.builtInThemes.first { $0.id == id } ?? .default
    }

    /// The picker's own swatch for a theme, so the colour the preview shows —
    /// and the report repeats — is the one Space settings shows for the same
    /// theme; the plan's `colorHex` is that theme's overlay hue, which is a
    /// brighter, different colour. The swatch states the theme on its own, with
    /// the name as a tooltip — the affordance `CreateSpacePanel` gives its dots.
    private static func themeSwatch(forID id: String) -> some View {
        let theme = theme(ofID: id)
        // Resolved dark whatever the system is doing: this window forces that
        // appearance, so the light variant of a theme would be the wrong colour
        // on this ground rather than a matching one.
        let themeColor = Color(theme.color(for: .themeColor, appearance: .dark))
        return ThemeSwatchView(
            fillColor: theme == .pure ? .white : themeColor,
            ringColor: themeColor,
            selected: false,
            title: nil,
            showsContrastBorder: theme == .pure,
            dotDiameter: themeSwatchDiameter,
            ringDiameter: themeSwatchRingDiameter,
            action: {}
        )
        // It is a button of its own; in a row the row is what a click means,
        // and the name beside it is what VoiceOver reads.
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .help(theme.name)
    }

    /// The Space's icon as the strip will draw it: the shared Space icon view
    /// at the size the import window's Space picker row uses. Never tinted —
    /// a Phi icon is its own artwork and an emoji is an emoji — so the tint
    /// only reaches the view's legacy SF Symbol fallback, which no plan
    /// produces.
    private static func spaceIcon(_ storedValue: String) -> some View {
        SpaceIconView(storedValue: storedValue, size: 16, symbolWeight: .regular, tint: Ink.primary)
            // As with the swatch, the name beside it is what VoiceOver reads.
            .accessibilityHidden(true)
    }

    // MARK: Run

    private var runBody: some View {
        Group {
            switch runner.state {
            case .running(let progress):
                progressBody(progress)
            case .finished(let report):
                reportBody(report)
            case .idle:
                // Only reachable if the report was dismissed elsewhere; the
                // window closes with the dismissal, so there is nothing left to
                // draw.
                EmptyView()
            }
        }
        .frame(width: Self.contentColumnWidth)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Where a unit sits relative to the one in flight — the only distinction
    /// the checklist draws, resolved once per row rather than re-derived by
    /// each of the three things that reads it.
    private enum ChecklistUnitState {
        case done
        case current
        case pending

        init(index: Int, current: Int) {
            if index < current {
                self = .done
            } else if index == current {
                self = .current
            } else {
                self = .pending
            }
        }

        /// The list is greyed apart from the unit in flight, which is the one
        /// thing on it worth reading.
        var textColor: Color {
            switch self {
            case .done: return Ink.secondary
            case .current: return Ink.primary
            case .pending: return Ink.hint
            }
        }
    }

    /// Wide enough for the inline spinner the unit in flight carries, and
    /// fixed so all three states line their names up at the same x and a row
    /// does not grow around the spinner.
    private static let checklistGlyphSide: CGFloat = 16

    /// The unit in flight, the counter, the bar and the list of units — and
    /// nothing else. The step says what it is doing and stops: the Keychain
    /// hint was spoken on Review, and the run outliving this window is carried
    /// by the Close button rather than by a line of prose.
    private func progressBody(_ progress: BrowserMigrationProgress) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(String(
                format: NSLocalizedString("app.browserMigration.run.creatingUnit",
                    value: "Creating %@",
                    comment: "Browser migration wizard - the unit of the run being worked on; %@ is a Profile or Space name"),
                progress.currentUnit.name))
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(Ink.primary)

            Text(Self.unitPosition(progress))
                .font(.system(size: 13))
                .foregroundColor(Ink.secondary)
                .padding(.top, 3)

            // Counts what has landed, so the unit being worked on is not
            // drawn as finished.
            ProgressView(
                value: Double(progress.unitIndex),
                total: Double(progress.unitCount))
                .padding(.top, 14)

            checklist(progress)
                .padding(.top, 18)
        }
    }

    /// The counter beneath the unit's name, worded by what the unit is: a
    /// Profile's unit and a Space's read differently at the same position.
    private static func unitPosition(_ progress: BrowserMigrationProgress) -> String {
        let format = progress.currentUnit.isSpace
            ? NSLocalizedString("app.browserMigration.run.unitPositionSpace",
                value: "Space %1$d of %2$d",
                comment: "Browser migration wizard - where the Space being created sits in the run; %1$d is its number, %2$d how many units the run has")
            : NSLocalizedString("app.browserMigration.run.unitPositionProfile",
                value: "Profile %1$d of %2$d",
                comment: "Browser migration wizard - where the Profile being created sits in the run; %1$d is its number, %2$d how many units the run has")
        return String(format: format, progress.unitIndex + 1, progress.unitCount)
    }

    /// Every unit of the run in the order it works through them — every
    /// Profile, then every Space in the source's own order: what has landed,
    /// what is in flight and what is still to come. It is the difference
    /// between a window that is working and one that is stuck while a
    /// Chromium import takes minutes over one Profile.
    private func checklist(_ progress: BrowserMigrationProgress) -> some View {
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: 0) {
                ForEach(progress.units.indices, id: \.self) { index in
                    checklistRow(
                        progress.units[index],
                        state: ChecklistUnitState(
                            index: index, current: progress.unitIndex))
                        .id(index)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .scrollsWhenTall()
            // A run with more units than fit is exactly the one whose unit in
            // flight must not be left off screen. With every unit in view there
            // is no scroll view for the proxy to find, and it does nothing.
            .onChange(of: progress.unitIndex) { _, index in
                withAnimation { proxy.scrollTo(index, anchor: .center) }
            }
            .onAppear { proxy.scrollTo(progress.unitIndex, anchor: .center) }
        }
    }

    private func checklistRow(
        _ unit: BrowserMigrationRunUnit, state: ChecklistUnitState
    ) -> some View {
        HStack(spacing: 8) {
            checklistGlyph(state)
                .frame(width: Self.checklistGlyphSide, height: Self.checklistGlyphSide)
            Text(unit.name)
                .font(.system(size: 15, weight: state == .current ? .medium : .regular))
                .foregroundColor(state.textColor)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func checklistGlyph(_ state: ChecklistUnitState) -> some View {
        switch state {
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14))
                .foregroundColor(Ink.secondary)
        case .current:
            ProgressView().controlSize(.small)
        case .pending:
            Image(systemName: "circle")
                .font(.system(size: 14))
                .foregroundColor(Ink.hint)
        }
    }

    // MARK: Report

    /// Summary first, then the failures worth looking at, then everything else
    /// behind a disclosure that starts closed. What is promoted is decided by
    /// the report itself; this only draws the answer.
    private func reportBody(_ report: BrowserMigrationReport) -> some View {
        let problems = report.problems
        return VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.summaryLine(report))
                    .font(.system(size: 15))
                    .foregroundColor(Ink.primary)
                if !problems.isEmpty {
                    Text(Self.problemCountLine(problems.count))
                        .font(.system(size: 15))
                        .foregroundColor(Ink.secondary)
                }
                // Source-level, because the Profile it would sit under was
                // never created and has no row: what the plan left behind
                // with the profiles it skipped, said rather than implied
                // gone. Not a problem — it is the source's own arrangement
                // — so it carries no glyph and is not promoted.
                if report.droppedPinnedEntries > 0 {
                    Text(Self.pinnedTabsLeftBehindLine(report.droppedPinnedEntries))
                        .font(.system(size: 15))
                        .foregroundColor(Ink.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)

            if !problems.isEmpty {
                problemCard(problems, requested: report.requestedDataTypes)
            }

            // The whole tree, always: the promoted rows appear in it again in
            // their own place rather than being moved out of it, so the card
            // above adds and never reorders. The tree scrolls when it is
            // taller than what the band has left; the summary stays put, and
            // the card holds at a few rows so the tree is what gets the band.
            reportTree(report)
                .padding(12)
                .scrollsWhenTall()
                .migrationCard()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// What the run created, in actuals — the report's counterpart to the
    /// preview's future tense.
    private static func summaryLine(_ report: BrowserMigrationReport) -> String {
        let profiles = report.createdProfileCount
        let spaces = report.createdSpaceCount
        guard profiles > 0 || spaces > 0 else {
            return NSLocalizedString("app.browserMigration.report.summaryNothingCreated",
                value: "Nothing was created.",
                comment: "Browser migration wizard - summary of a run that created no Profile and no Space")
        }
        return String(
            format: NSLocalizedString("app.browserMigration.report.summaryCreated",
                value: "Created %1$@ and %2$@.",
                comment: "Browser migration wizard - summary of what a run created; %1$@ is a Profile count such as \"2 Profiles\", %2$@ a Space count such as \"5 Spaces\""),
            reportProfileCountLabel(profiles),
            reportSpaceCountLabel(spaces))
    }

    /// The preview's counts say the same words about a different thing — an
    /// intention rather than an outcome — so the report states its own rather
    /// than tying the two surfaces' wording together.
    private static func reportProfileCountLabel(_ count: Int) -> String {
        String.localizedStringWithFormat(
            NSLocalizedString("app.browserMigration.report.profileCount", value: "%d Profiles",
                comment: "Browser migration wizard - Profile count in the report summary; %d is the number of Profiles the run created"),
            count)
    }

    private static func reportSpaceCountLabel(_ count: Int) -> String {
        String.localizedStringWithFormat(
            NSLocalizedString("app.browserMigration.report.spaceCount", value: "%d Spaces",
                comment: "Browser migration wizard - Space count in the report summary; %d is the number of Spaces the run created"),
            count)
    }

    private static func problemCountLine(_ count: Int) -> String {
        String.localizedStringWithFormat(
            NSLocalizedString("app.browserMigration.report.summaryProblems",
                value: "%d things need your attention.",
                comment: "Browser migration wizard - how many promoted failures the report lists; %d is the number of them"),
            count)
    }

    /// Three rows of the problem grid and half of a fourth: the card's 12pt
    /// top padding, then rows of 15pt text that the grid lays out 19pt tall
    /// on the glyph's baseline, at its 6pt spacing — the fourth row starts
    /// at 87 and 96 cuts it in the middle. The card is the shortcut to what
    /// is wrong and the tree is the report, so a run that went wrong in
    /// many places — the one that needs the tree most — must not have the
    /// card take the band from it. The half row is what says there is more
    /// to scroll to.
    private static let problemCardMaxHeight: CGFloat = 96

    /// The failures, always open, and never more than a few rows tall.
    /// Everything in it is also in the tree below, so this is a shortcut to
    /// what is wrong rather than a place things are taken to.
    private func problemCard(
        _ problems: [BrowserMigrationReport.Problem], requested: Set<ImportDataType>
    ) -> some View {
        // A grid rather than a stack of rows so the outcomes line up in a
        // column of their own however long the names beside them run.
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 6) {
            ForEach(Array(problems.enumerated()), id: \.offset) { _, problem in
                GridRow {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        reportGlyph(ok: false)
                        Text(Self.problemSubject(problem, requested: requested))
                            .font(.system(size: 15))
                            .foregroundColor(Ink.primary)
                    }
                    .gridColumnAlignment(.leading)
                    Text(Self.problemOutcome(problem))
                        .font(.system(size: 15))
                        .foregroundColor(Ink.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        // As the tree: the card is as tall as the grid while that fits under
        // the cap, and past it the rows scroll inside the card. The fixed
        // size is what keeps the card at the grid's own height under the
        // cap — a flexible frame on its own would claim the cap whatever it
        // holds, and a two-row card would grow to it.
        .scrollsWhenTall()
        .frame(maxHeight: Self.problemCardMaxHeight)
        .fixedSize(horizontal: false, vertical: true)
        .migrationCard()
    }

    /// Where the failure happened, deepest named thing last: a Profile, a
    /// Profile and its Space, or a Profile and the facet of it that fell short.
    private static func problemSubject(
        _ problem: BrowserMigrationReport.Problem, requested: Set<ImportDataType>
    ) -> String {
        switch problem {
        case .profileNotCreated(let profile):
            return profile
        case .browserDataFailed(let profile):
            // Not `browserDataLabel`: one Chromium flag answers for every
            // facet that was asked for, so the row the reader is made to look
            // at names all of them — the three, or history alone when the
            // source's cookies and extensions were never part of the request.
            // The Profile's own grid still splits them, because there the
            // labels are a fixed ladder rather than a description of a failure.
            return "\(profile) · \(browserDataFailedSubjectLabel(requested: requested))"
        case .spaceNotCreated(let profile, let space),
             .bookmarksFailed(let profile, let space),
             .bookmarksNoneSaved(let profile, let space):
            return "\(profile) · \(space)"
        case .pinnedTabsIncomplete(let profile, _, _):
            return "\(profile) · \(pinnedTabsLabel)"
        }
    }

    private static func problemOutcome(_ problem: BrowserMigrationReport.Problem) -> String {
        switch problem {
        case .profileNotCreated:
            return NSLocalizedString("app.browserMigration.report.profileNotCreated",
                value: "Profile not created",
                comment: "Browser migration wizard - promoted failure of a Profile the run could not create")
        case .browserDataFailed:
            // The same words the expanded rows use, because the same thing
            // happened: promoting it changes where the reader meets it, not
            // what it says.
            return couldNotImportLabel
        case .spaceNotCreated:
            return NSLocalizedString("app.browserMigration.report.spaceNotCreated",
                value: "Space not created",
                comment: "Browser migration wizard - promoted failure of a Space the run could not create")
        case .bookmarksFailed:
            return bookmarksFailedLabel
        case .bookmarksNoneSaved:
            return bookmarksNoneSavedLabel
        case .pinnedTabsIncomplete(_, let written, let planned):
            return pinnedTabsShortfallLabel(written: written, planned: planned)
        }
    }

    /// Every Profile and every Space, in plan order, each with what became of
    /// it. Shown only once the disclosure is open.
    private func reportTree(_ report: BrowserMigrationReport) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(report.profiles) { profile in
                VStack(alignment: .leading, spacing: 4) {
                    reportObjectRow(
                        name: profile.displayName,
                        ok: profile.landedCleanly,
                        outcome: profile.created ? nil : Self.notCreatedLabel,
                        weight: .medium)
                    // An outcome Phi never got vanishes rather than being
                    // spelled out: a Profile that does not exist imported
                    // nothing, and its own row already says so.
                    if profile.created {
                        outcomeGrid(profile, requested: report.requestedDataTypes)
                            .padding(.leading, 22)
                    }
                    ForEach(profile.spaces) { space in
                        reportObjectRow(
                            name: space.name,
                            ok: space.failure == nil,
                            outcome: spaceOutcome(space),
                            weight: .regular,
                            space: space)
                            .padding(.leading, 20)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func reportObjectRow(
        name: String, ok: Bool, outcome: String?, weight: Font.Weight,
        space: BrowserMigrationReport.SpaceRow? = nil
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            reportGlyph(ok: ok)
            // The icon and the swatch centre on the name, and the group sits
            // on the row's baseline through the name.
            HStack(spacing: 6) {
                // A Space repeats the icon and the swatch the preview promised
                // for it, in the preview's order: icon, name, swatch.
                if let space {
                    Self.spaceIcon(space.iconName)
                }
                Text(name)
                    .font(.system(size: 15, weight: weight))
                    .foregroundColor(Ink.primary)
                if let space {
                    Self.themeSwatch(forID: space.themeID)
                }
            }
            Spacer(minLength: 12)
            if let outcome {
                Text(outcome)
                    .font(.system(size: 13))
                    .foregroundColor(Ink.secondary)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Two states, and only on the rows that name a thing the run either made
    /// or failed to make. The lines inside `outcomeGrid` carry no glyph at all:
    /// a green tick beside "Import finished" would claim what Chromium never told
    /// Phi, and an orange one would call an ordinary outcome a failure.
    private func reportGlyph(ok: Bool) -> some View {
        Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
            .foregroundColor(ok ? .green : .orange)
    }

    /// A Space says what became of its Bookmarks once it exists; before that,
    /// there is only the Space's own failure to report.
    private func spaceOutcome(_ space: BrowserMigrationReport.SpaceRow) -> String? {
        guard space.created else { return Self.notCreatedLabel }
        switch space.bookmarks {
        case .notAttempted:
            return nil
        case .written(let count):
            return String.localizedStringWithFormat(
                NSLocalizedString("app.browserMigration.report.bookmarkCount",
                    value: "%d bookmarks",
                    comment: "Browser migration wizard - how many bookmarks a migrated Space received; %d is the number of bookmarks"),
                count)
        case .noneInSource:
            // Spelled out rather than left silent: an empty row would read as
            // an unknown, and this one is known.
            return String(
                format: NSLocalizedString("app.browserMigration.report.bookmarksNoneInSource",
                    value: "No bookmarks — this Space had none in %@",
                    comment: "Browser migration wizard - shown on a Space whose source tree carried no bookmarks; %@ is the source browser's name"),
                reportSourceName)
        case .noneSaved:
            return Self.bookmarksNoneSavedLabel
        case .failed:
            return Self.bookmarksFailedLabel
        }
    }

    private static let notCreatedLabel = NSLocalizedString(
        "app.browserMigration.report.notCreated",
        value: "Not created",
        comment: "Browser migration wizard - outcome of a Profile or Space the run failed to create")

    private static let bookmarksFailedLabel = NSLocalizedString(
        "app.browserMigration.report.bookmarksFailed",
        value: "Bookmarks couldn't be saved",
        comment: "Browser migration wizard - shown on a Space whose Bookmarks did not persist")

    private static let bookmarksNoneSavedLabel = NSLocalizedString(
        "app.browserMigration.report.bookmarksNoneSaved",
        value: "No bookmarks were saved",
        comment: "Browser migration wizard - shown on a Space whose source tree carried bookmarks of which none landed")

    /// The labels always present once the Profile exists — history and
    /// pinned tabs for every source, the cookies on the history line and the
    /// extensions on a line of their own where the run asked for them — so
    /// a facet Phi worked on can never go unmentioned. What the run did not
    /// ask for is not on the row at all: a source's data no ticket carries
    /// yet (Zen's cookies, Firefox bookmarks and extensions) is neither
    /// claimed nor disclaimed here, by direction. The values carry the whole
    /// hedge: what Chromium only answers with one success flag is *finished*
    /// and *started*, never *imported* with a count.
    private func outcomeGrid(
        _ profile: BrowserMigrationReport.ProfileRow, requested: Set<ImportDataType>
    ) -> some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 3) {
            GridRow {
                // History shares its line with the cookies when both were
                // asked for; alone, it is the recent history and says so.
                Self.outcomeLabel(requested.contains(.cookies)
                    ? Self.browserDataLabel : Self.recentHistoryLabel)
                Self.outcomeValue(Self.browserDataOutcome(profile))
            }
            if requested.contains(.extensions) {
                GridRow {
                    Self.outcomeLabel(Self.extensionsLabel)
                    Self.outcomeValue(Self.extensionsOutcome(profile))
                }
            }
            GridRow {
                Self.outcomeLabel(Self.pinnedTabsLabel)
                Self.outcomeValue(pinnedTabsOutcome(profile))
            }
        }
    }

    private static func outcomeLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundColor(Ink.secondary)
            .gridColumnAlignment(.leading)
    }

    private static func outcomeValue(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundColor(Ink.primary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private static let browserDataLabel = NSLocalizedString(
        "app.browserMigration.report.labelBrowserData",
        value: "History & cookies",
        comment: "Browser migration wizard - label of a migrated Profile's history and cookies outcome in the report's detail grid")

    /// The same failure named for the promoted card, where nothing else on the
    /// line says extensions were part of it.
    private static let browserDataAndExtensionsLabel = NSLocalizedString(
        "app.browserMigration.report.labelBrowserDataAndExtensions",
        value: "History, cookies & extensions",
        comment: "Browser migration wizard - subject of the promoted failure of a migrated Profile's browser-data import, which covers all three at once")

    private static let extensionsLabel = NSLocalizedString(
        "app.browserMigration.report.labelExtensions",
        value: "Extensions",
        comment: "Browser migration wizard - label of a migrated Profile's extensions outcome")

    private static let pinnedTabsLabel = NSLocalizedString(
        "app.browserMigration.report.labelPinnedTabs",
        value: "Pinned tabs",
        comment: "Browser migration wizard - label of a migrated Profile's pinned tabs outcome")

    /// History on a line of its own, when the cookies were not part of the
    /// request. "Recent" rather than "all": the import keeps the most recent
    /// entries only, and the label is where that is said.
    private static let recentHistoryLabel = NSLocalizedString(
        "app.browserMigration.report.labelRecentHistory",
        value: "Recent history",
        comment: "Browser migration wizard - label of a migrated Profile's history outcome in the report's detail grid when history was the only data the source's import was asked for, as with Zen; \"recent\" because the import keeps only the most recent entries")

    /// The subject of a promoted import failure: every facet the one Chromium
    /// flag answered for — all three; history and cookies when the extensions
    /// were not part of the request; history alone when neither was. (No
    /// source asks for extensions without cookies, so that pairing has no
    /// label.)
    private static func browserDataFailedSubjectLabel(
        requested: Set<ImportDataType>
    ) -> String {
        if requested.contains(.extensions) { return browserDataAndExtensionsLabel }
        return requested.contains(.cookies) ? browserDataLabel : recentHistoryLabel
    }

    private static func pinnedTabsLeftBehindLine(_ count: Int) -> String {
        String.localizedStringWithFormat(
            NSLocalizedString("app.browserMigration.report.pinnedTabsLeftBehind",
                value: "%d pinned tabs were left behind because their Profile had no Spaces.",
                comment: "Browser migration wizard - report note counting the source's pinned entries the run could not place because the Profile they belong to has no Spaces and so was not created; %d is the number of them"),
            count)
    }

    /// One failure for the three facets, because the Chromium side answers the
    /// whole request with a single flag: the two rows it can reach say the same
    /// thing because the same thing happened to both.
    private static let couldNotImportLabel = NSLocalizedString(
        "app.browserMigration.report.browserDataFailed",
        value: "Couldn't be imported",
        comment: "Browser migration wizard - shown when a migrated Profile's browser-data import came back failed: against its history, cookies and extensions rows in the detail grid, and as the outcome of the promoted failure")

    /// Deliberately weaker than "imported": the Chromium side answers the whole
    /// request with one success flag, and reports success even when a denied
    /// Keychain prompt made it skip the cookies. Asked only of a Profile that
    /// exists, so `notAttempted` — which is only ever a Profile that does not —
    /// never reaches it.
    private static func browserDataOutcome(
        _ profile: BrowserMigrationReport.ProfileRow
    ) -> String {
        guard case .requested = profile.browserData else { return couldNotImportLabel }
        return NSLocalizedString("app.browserMigration.report.browserDataRequested",
            value: "Import finished",
            comment: "Browser migration wizard - shown when a migrated Profile's history and cookies import ran to completion; deliberately not a claim about what landed")
    }

    /// Started, never finished: the Chromium side installs extensions in the
    /// background and its per-extension result has no way back here.
    private static func extensionsOutcome(
        _ profile: BrowserMigrationReport.ProfileRow
    ) -> String {
        guard case .requested(let extensions) = profile.browserData else {
            return couldNotImportLabel
        }
        // Named even at zero: a Profile that carried no extensions has to say
        // so rather than leave the reader unable to tell it from one Phi never
        // looked at.
        guard extensions > 0 else {
            return NSLocalizedString("app.browserMigration.report.extensionsNoneFound",
                value: "None found",
                comment: "Browser migration wizard - shown against a migrated Profile's extensions when the source profile carried none")
        }
        return String.localizedStringWithFormat(
            NSLocalizedString("app.browserMigration.report.extensionsTriggered",
                value: "Install started for %d",
                comment: "Browser migration wizard - how many extensions a migrated Profile had installation started for; %d is the number of extensions"),
            extensions)
    }

    private func pinnedTabsOutcome(
        _ profile: BrowserMigrationReport.ProfileRow
    ) -> String {
        guard profile.pinnedTabsPlanned > 0 else {
            return String(
                format: NSLocalizedString("app.browserMigration.report.pinnedTabsNoneInSource",
                    value: "None in %@",
                    comment: "Browser migration wizard - shown against a migrated Profile's pinned tabs when the source profile had none; %@ is the source browser's name"),
                reportSourceName)
        }
        guard profile.pinnedTabsComplete else {
            return Self.pinnedTabsShortfallLabel(
                written: profile.pinnedTabsWritten, planned: profile.pinnedTabsPlanned)
        }
        return String.localizedStringWithFormat(
            NSLocalizedString("app.browserMigration.report.pinnedTabCount",
                value: "%d added",
                comment: "Browser migration wizard - how many pinned tabs a migrated Profile received; %d is the number of pinned tabs"),
            profile.pinnedTabsWritten)
    }

    private static func pinnedTabsShortfallLabel(written: Int, planned: Int) -> String {
        String.localizedStringWithFormat(
            NSLocalizedString("app.browserMigration.report.pinnedTabsDropped",
                value: "%1$d of %2$d couldn't be added",
                comment: "Browser migration wizard - how many of a Profile's pinned entries the run could not turn into pinned tabs; %1$d is the number that were dropped, %2$d how many the plan carried"),
            planned - written, planned)
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

// MARK: - Mixed-state checkbox

/// A checkbox that can be mixed, for the Profile rows. SwiftUI's
/// `Toggle(.checkbox)` has two states only, and approximating the third with a
/// dimmed tick reads as disabled — so the row bridges the real `NSButton`,
/// which draws the mixed mark and reports it as mixed to accessibility.
///
/// It lives beside its one caller: the wizard is the only surface with a tick
/// that follows other ticks.
/// The box alone: what it stands for is drawn beside it, so this view's width
/// is the control's own and cannot be stretched by the text it belongs to.
/// It stays an `NSButton` because a real one is the only thing that reports a
/// genuine `.mixed` value to accessibility.
private struct MixedStateCheckbox: NSViewRepresentable {
    /// The domain state, mapped here rather than at the call site: the button's
    /// three values are this control's business and nobody else's.
    let tick: BrowserMigrationPreviewTick
    /// What the box is for. Spoken, never drawn — the visible name is the label
    /// beside it, which is hidden from accessibility so it is not read twice.
    /// Not `accessibilityLabel`: that name shadows SwiftUI's own modifier on
    /// this type.
    let spokenName: String
    /// Takes no argument on purpose. What a click means is one rule and it
    /// belongs to the caller, which also hangs it on the name beside the box.
    let onToggle: () -> Void

    private var state: NSControl.StateValue {
        switch tick {
        case .on: return .on
        case .mixed: return .mixed
        case .off: return .off
        }
    }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(
            checkboxWithTitle: "",
            target: context.coordinator,
            action: #selector(Coordinator.clicked(_:)))
        button.allowsMixedState = true
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.onToggle = onToggle
        context.coordinator.state = state
        button.setAccessibilityLabel(spokenName)
        button.state = state
    }

    func makeCoordinator() -> Coordinator { Coordinator(state: state, onToggle: onToggle) }

    final class Coordinator: NSObject {
        var state: NSControl.StateValue
        var onToggle: () -> Void

        init(state: NSControl.StateValue, onToggle: @escaping () -> Void) {
            self.state = state
            self.onToggle = onToggle
        }

        /// The button has already cycled itself through its own three-state
        /// order by the time this runs; the plan owns the state, so it is put
        /// back and the rebuilt row sets the real one.
        @objc func clicked(_ sender: NSButton) {
            sender.state = state
            onToggle()
        }
    }
}
