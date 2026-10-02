import AppKit
import SwiftUI

/// Settings → Sync: setup and sync status, authorized devices, and recovery/removal.
struct DevicesSettingView: View {
    @ObservedObject var viewModel: DevicesSettingViewModel
    /// The runtime "remove this device from sync" entry point. Separate from
    /// `viewModel` because that object is built from an `AccountKeyManager`
    /// pair, while the removal has to run on the coordinator-owned
    /// `SyncKeyController` (see `DevicesRemoveDeviceModel`).
    @ObservedObject var removeModel: DevicesRemoveDeviceModel
    var onJoinThisDevice: () -> Void = {}
    var onResolvePairing: () -> Void = {}
    /// Polled from the shared `SyncKeyController` rather than threaded through
    /// `DevicesSettingViewModel` (which the pane's tests construct directly):
    /// checked once when the pane appears and refreshed alongside the pending
    /// join-request poll, so the banner clears once pairing resolves.
    var needsPairingCheck: () -> Bool = { false }

    @State private var needsPairing = false
    @State private var isStatusDetailsExpanded = false

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 24) {
                if viewModel.requiresReconfiguration {
                    reconfigurationCard
                }
                if needsPairing, !viewModel.requiresReconfiguration, viewModel.unlockState == .unlocked {
                    pairingCard
                }

                switch viewModel.unlockState {
                case .loading:
                    loadingCard
                case .notSignedIn:
                    signInCard
                case .failed(let m):
                    SettingsDetailCard {
                        row(m) {
                            actionButton(NSLocalizedString("sync.settings.retry", value: "Retry", comment: "Reload sync settings")) {
                                Task { await viewModel.loadAll() }
                            }
                        }
                    }
                case .needsJoin:
                    SettingsDetailCard {
                        row(NSLocalizedString("sync.devices.notSetUp", value: "This device isn’t set up for sync yet.", comment: "Devices settings - shown when this device has not joined sync")) {
                            actionButton(NSLocalizedString("sync.devices.setUp", value: "Set up sync on this device", comment: "Devices settings - button that starts sync setup on this device")) {
                                onJoinThisDevice()
                            }
                        }
                    }
                case .unlocked:
                    if !needsPairing { statusCard }
                }

                if viewModel.isUnlocked, hasDevicesContent {
                    devicesSection
                }

                if let err = viewModel.actionError {
                    errorText(err)
                }

                if removeModel.isVisible(unlockState: viewModel.unlockState) {
                    removeDeviceSection
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 36)
            .padding(.horizontal, 36)
        }
        .themedBackground(PhiPreferences.fixedWindowBackground)
        .frame(width: 680, height: 561)
        .task {
            await viewModel.loadAll()
            needsPairing = needsPairingCheck()
            // Mirrors the ViewModel's own 3s pending-approval poll cadence so the
            // banner clears promptly once another entry point resolves pairing
            // (e.g. the key-layer window). Tied to the view's task lifecycle, so
            // it stops automatically alongside `stopPolling()` below.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                needsPairing = needsPairingCheck()
            }
        }
        .onDisappear { Task { await viewModel.stopPolling() } }
        .onChange(of: viewModel.syncNowOutcome) { _, outcome in
            guard let outcome else { return }
            switch outcome.result {
            case .finished:
                announce(NSLocalizedString("sync.status.syncNowDone", value: "Sync finished", comment: "Sync settings - VoiceOver announcement when a sync the user started with Sync Now has finished"))
            case .failed(let category):
                announce(category.map(problemTitle) ?? NSLocalizedString("sync.status.syncNowIncomplete", value: "Sync did not finish", comment: "Sync settings - VoiceOver announcement when a sync the user started with Sync Now ended without finishing and no specific problem is known"))
            case .rejected:
                announce(Self.syncNowFailedText)
            }
        }
    }

    // MARK: - Shared pane styling

    /// A titled group of cards; the title sits above the card, as in the
    /// General pane's sections.
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.system(size: 12))
                .themedForeground(.textSecondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A card row: a title with optional detail lines under it, and a
    /// trailing control.
    private func row<Details: View, Control: View>(
        _ title: String,
        @ViewBuilder details: () -> Details,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 13))
                    .themedForeground(.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                details()
            }
            Spacer(minLength: 12)
            control()
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row<Control: View>(_ title: String, @ViewBuilder control: () -> Control) -> some View {
        row(title, details: { EmptyView() }, control: control)
    }

    private func hintText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .themedForeground(.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func errorText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(Color.red)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func actionButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.bordered)
            .controlSize(.small)
    }

    // MARK: - Setup and status

    private var loadingCard: some View {
        SettingsDetailCard {
            HStack {
                Spacer()
                ProgressView()
                    .controlSize(.small)
                Spacer()
            }
            .padding(.vertical, 20)
        }
    }

    private var signInCard: some View {
        SettingsDetailCard {
            row(NSLocalizedString("sync.settings.signIn", value: "Sign in to sync across devices", comment: "Sync settings signed out explanation")) {
                actionButton(NSLocalizedString("sync.settings.signInAction", value: "Sign in", comment: "Sync settings sign in action")) {
                    LoginController.shared.showLoginWindow()
                }
            }
        }
    }

    private var reconfigurationCard: some View {
        SettingsDetailCard {
            row(SyncReconfigurationStrings.explanation) {
                if let error = viewModel.reconfigurationError {
                    errorText(error)
                }
            } control: {
                actionButton(SyncReconfigurationStrings.title) { onResolvePairing() }
                    .disabled(viewModel.isReconfiguring)
            }
        }
    }

    private var pairingCard: some View {
        SettingsDetailCard {
            row(NSLocalizedString("sync.setup.notPaired", value: "Not paired", comment: "Sync status before matching completes")) {
                hintText(NSLocalizedString("sync.setup.notStarted", value: "Sync has not started", comment: "All sync waits for pairing completion"))
            } control: {
                actionButton(NSLocalizedString("sync.setup.continueSetup", value: "Continue setup", comment: "Reopen sync setup with fresh account data")) {
                    onResolvePairing()
                }
            }
        }
    }

    private var statusCard: some View {
        SettingsDetailCard {
            row(statusTitle(viewModel.summary.phase)) {
                if let date = viewModel.summary.lastSuccess {
                    hintText(String(format: NSLocalizedString("sync.status.lastSuccessAt", value: "Last successful sync on this Mac: %@", comment: "Devices settings - time of the last successful sync on this Mac; %@ is the date and time"), date.formatted()))
                }
                if viewModel.summary.phase == .needsAttention {
                    hintText(NSLocalizedString("sync.status.partialFailure", value: "Some content needs attention. Check the details and your connection.", comment: "One or more sync contexts failed"))
                }
                if let problem = viewModel.nativeDetail?.lastProblem {
                    hintText(String(format: NSLocalizedString("sync.status.lastProblem", value: "Last problem: %1$@ (%2$@)", comment: "Sync settings - the most recent sync problem on this Mac; %1$@ is the kind of problem, such as No connection, %2$@ is how long ago it happened, such as 5 minutes ago"), problemTitle(problem.category), problem.at.formatted(.relative(presentation: .named))))
                }
            } control: {
                syncNowControl
            }

            Divider()

            Button {
                withAnimation { isStatusDetailsExpanded.toggle() }
            } label: {
                SettingsDetailRow(NSLocalizedString("sync.status.details", value: "Details", comment: "Expand individual sync context status")) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .themedForeground(.textTertiary)
                        .rotationEffect(.degrees(isStatusDetailsExpanded ? 90 : 0))
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(.isButton)
            .accessibilityValue(isStatusDetailsExpanded
                ? NSLocalizedString("sync.status.detailsExpanded", value: "Expanded", comment: "Sync settings - VoiceOver value of the Details disclosure while it shows per-context status")
                : NSLocalizedString("sync.status.detailsCollapsed", value: "Collapsed", comment: "Sync settings - VoiceOver value of the Details disclosure while per-context status is hidden"))

            if isStatusDetailsExpanded {
                ForEach(viewModel.requiredIDs.sorted(), id: \.self) { id in
                    Divider()
                    SettingsDetailRow(viewModel.contextTitle(id)) {
                        Text(statusTitle(SyncSummaryPhase(rawValue: viewModel.contextSnapshots[id]?.phase.rawValue ?? "checking") ?? .checking))
                            .font(.system(size: 12))
                            .themedForeground(.textSecondary)
                    }
                    if id == "phi", let detail = viewModel.nativeDetail {
                        ForEach(SyncKind.allCases, id: \.self) { kind in
                            kindRow(kind, status: detail.kinds[kind])
                        }
                    }
                }
            }
        }
    }

    /// Sync now in the status row's control slot. The hint and the progress indicator keep
    /// their space while the button is shown, so the row neither jumps nor changes height
    /// when the request state changes.
    @ViewBuilder
    private var syncNowControl: some View {
        let state = viewModel.syncNowButton
        if state.isVisible {
            HStack(spacing: 8) {
                Group {
                    if state.hint == .failed {
                        errorText(Self.syncNowFailedText)
                    } else if let hint = syncNowHint(state.hint) {
                        hintText(hint)
                    }
                }
                .lineLimit(1)
                .truncationMode(.tail)
                .help(syncNowHint(state.hint) ?? "")
                .frame(width: 200, alignment: .trailing)
                ProgressView()
                    .controlSize(.small)
                    .opacity(state.showsProgress ? 1 : 0)
                    .accessibilityHidden(!state.showsProgress)
                    .accessibilityLabel(NSLocalizedString("sync.status.syncNowInProgress", value: "Sync in progress", comment: "Sync settings - VoiceOver label of the progress indicator beside Sync Now while a requested sync waits or runs"))
                actionButton(NSLocalizedString("sync.status.syncNow", value: "Sync Now", comment: "Sync settings - button that asks this Mac to sync all content now")) {
                    Task { await viewModel.syncNow() }
                }
                .disabled(!state.isEnabled || viewModel.isReconfiguring)
                .accessibilityHint(syncNowHint(state.hint) ?? "")
            }
        }
    }

    private static var syncNowFailedText: String {
        NSLocalizedString("sync.status.syncNowFailed", value: "Couldn’t start sync. Try again later.", comment: "Sync settings - shown beside Sync Now when this Mac refused to start the requested sync")
    }

    private func syncNowHint(_ hint: SyncNowButtonState.Hint) -> String? {
        switch hint {
        case .none: return nil
        case .waitingForCurrentSync: return NSLocalizedString("sync.status.syncNowQueued", value: "Waiting for current sync…", comment: "Sync settings - shown beside Sync Now when the requested sync waits for a sync already running")
        case .startingShortly: return NSLocalizedString("sync.status.syncNowStartingShortly", value: "Sync will start shortly…", comment: "Sync settings - shown beside Sync Now when the requested sync waits because a sync ran moments ago; it starts on its own within a minute")
        case .waitingForProfiles: return NSLocalizedString("sync.status.syncNowWaitingProfiles", value: "Waiting for all profiles to be available", comment: "Sync settings - shown beside Sync Now when the requested sync waits until every browser profile reports its sync status")
        case .failed: return Self.syncNowFailedText
        }
    }

    /// One per-kind line under the Phi data context: counts only, never names or content.
    private func kindRow(_ kind: SyncKind, status: SyncKindStatus?) -> some View {
        let summary = kindSummary(status)
        return SettingsDetailRow(kindTitle(kind)) {
            Text(summary)
                .font(.system(size: 12))
                .themedForeground(.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail) // The time comes last and is cut first.
                .help(summary)
        }
        .padding(.leading, 16)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(kindTitle(kind))
        .accessibilityValue(summary)
    }

    private func kindSummary(_ status: SyncKindStatus?) -> String {
        guard let status else { return Self.noKindActivityText }
        var parts: [String] = []
        if status.activityAt != nil {
            parts.append(String.localizedStringWithFormat(NSLocalizedString("sync.status.kindReceived", value: "Received %lld", comment: "Sync settings - how many changes of one kind of content, such as Bookmarks, this Mac received from the account in its most recent sync with changes; %lld is the number"), status.received))
            parts.append(String.localizedStringWithFormat(NSLocalizedString("sync.status.kindSent", value: "Sent %lld", comment: "Sync settings - how many changes of one kind of content, such as Bookmarks, this Mac sent to the account in its most recent sync with changes; %lld is the number"), status.sent))
        }
        if status.pending > 0 {
            parts.append(String.localizedStringWithFormat(NSLocalizedString("sync.status.kindPending", value: "Waiting to send %lld", comment: "Sync settings - how many local changes of one kind of content wait to be sent to the account; %lld is the number"), status.pending))
        }
        if status.held > 0 {
            parts.append(String.localizedStringWithFormat(NSLocalizedString("sync.status.kindHeld", value: "Held %lld", comment: "Sync settings - how many synced items of one kind of content are held on this Mac and not applied yet, for example because they could not be read; %lld is the number"), status.held))
        }
        guard var counts = parts.first else { return Self.noKindActivityText }
        for part in parts.dropFirst() {
            counts = String(format: NSLocalizedString("sync.status.kindCountsList", value: "%1$@ · %2$@", comment: "Sync settings - joins count phrases of one kind of content, such as Received 2 and Sent 1, into one line; %1$@ is the phrases so far, %2$@ the next phrase"), counts, part)
        }
        guard let activityAt = status.activityAt else { return counts }
        // When the received and sent counts happened, so an old count does not read as current.
        return String(format: NSLocalizedString("sync.status.kindCountsWithTime", value: "%1$@ · %2$@", comment: "Sync settings - one kind of content's counts followed by when its most recent sync with changes happened; %1$@ is the counts, such as Received 2 · Sent 1, %2$@ a relative time, such as 5 min. ago"), counts, activityAt.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))
    }

    private static var noKindActivityText: String {
        NSLocalizedString("sync.status.kindNoActivity", value: "No recent changes", comment: "Sync settings - shown for one kind of content, such as Bookmarks, when no sync since the app started has sent or received changes of that kind")
    }

    private func kindTitle(_ kind: SyncKind) -> String {
        switch kind {
        case .settings: return NSLocalizedString("sync.status.kind.settings", value: "Settings", comment: "Sync settings - per-kind status row for synced app settings")
        case .spaces: return NSLocalizedString("sync.status.kind.spaces", value: "Spaces", comment: "Sync settings - per-kind status row for synced Spaces")
        case .bookmarks: return NSLocalizedString("sync.status.kind.bookmarks", value: "Bookmarks", comment: "Sync settings - per-kind status row for synced bookmarks and folders")
        case .pinnedTabs: return NSLocalizedString("sync.status.kind.pinnedTabs", value: "Pinned tabs", comment: "Sync settings - per-kind status row for synced pinned tabs")
        case .urlRules: return NSLocalizedString("sync.status.kind.urlRules", value: "URL rules", comment: "Sync settings - per-kind status row for synced URL rules, the rules that open matching URLs in a chosen Space")
        }
    }

    private func problemTitle(_ category: SyncProblemCategory) -> String {
        switch category {
        case .offline: return NSLocalizedString("sync.status.problem.offline", value: "No connection", comment: "Sync settings - last sync problem: this Mac could not reach the sync service")
        case .signInExpired: return NSLocalizedString("sync.status.problem.signInExpired", value: "Sign-in expired", comment: "Sync settings - last sync problem: the account sign-in is no longer valid")
        case .serverError: return NSLocalizedString("sync.status.problem.serverError", value: "Server error", comment: "Sync settings - last sync problem: the sync service returned an error")
        case .saveFailedOnThisMac: return NSLocalizedString("sync.status.problem.saveFailed", value: "Couldn’t save sync state on this Mac", comment: "Sync settings - last sync problem: this Mac could not store its sync progress")
        case .readFailedOnThisMac: return NSLocalizedString("sync.status.problem.readFailed", value: "Couldn’t read data on this Mac", comment: "Sync settings - last sync problem: this Mac could not read its own local data of one kind, such as Bookmarks, to sync it")
        case .rejectedByServer: return NSLocalizedString("sync.status.problem.rejected", value: "Server rejected changes", comment: "Sync settings - last sync problem: the sync service did not accept changes sent from this Mac")
        case .unreadableRemoteData: return NSLocalizedString("sync.status.problem.unreadable", value: "Some synced data couldn’t be read", comment: "Sync settings - last sync problem: some data from the account could not be read on this Mac")
        case .resetRequired: return NSLocalizedString("sync.status.problem.resetRequired", value: "Sync needs to be reset", comment: "Sync settings - last sync problem: sync must be set up again before it can continue")
        case .waitingForProfilePairing: return NSLocalizedString("sync.status.problem.waitingForProfilePairing", value: "Waiting for a profile to be paired", comment: "Sync settings - last sync problem: some synced items wait until a browser profile on this Mac is paired with the account")
        }
    }

    private func announce(_ text: String) {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text,
                                        .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    // MARK: - Devices

    /// False while the device list is still loading with nothing to approve, so
    /// the section does not render as a title over an empty card.
    private var hasDevicesContent: Bool {
        !viewModel.pending.isEmpty || !viewModel.devices.isEmpty || viewModel.devicesLoadError != nil
    }

    private var devicesSection: some View {
        section(NSLocalizedString("sync.devices.title", value: "Devices", comment: "Devices authorized for this account")) {
            if !viewModel.pending.isEmpty {
                SettingsDetailCard { pendingSection }
            }
            if let error = viewModel.devicesLoadError {
                SettingsDetailCard {
                    row(NSLocalizedString("sync.devices.thisMacUnknown", value: "This Mac — registration could not be checked", comment: "Device list unavailable; local identity is not proof of registration")) {
                        errorText(error)
                    } control: {
                        EmptyView()
                    }
                }
            } else if !viewModel.devices.isEmpty {
                SettingsDetailCard {
                    ForEach(Array(viewModel.devices.enumerated()), id: \.element.id) { index, device in
                        if index > 0 { Divider() }
                        SettingsDetailRow(device.name, systemImage: "laptopcomputer") {
                            HStack(spacing: 8) {
                                if device.deviceKeyID == viewModel.currentDeviceID {
                                    thisMacBadge
                                }
                                Text(verbatim: Self.platformName(device.platform))
                                    .font(.system(size: 12))
                                    .themedForeground(.textSecondary)
                            }
                        }
                    }
                }
            }
        }
    }

    /// Same pill as `SettingsDefaultBadge`, marking the row for this Mac.
    private var thisMacBadge: some View {
        Text(NSLocalizedString("sync.devices.thisMac", value: "This Mac", comment: "Current authorized device marker"))
            .font(.system(size: 10, weight: .medium))
            .themedForeground(.textSecondary)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(0.15), in: Capsule())
    }

    private func statusTitle(_ phase: SyncSummaryPhase) -> String {
        switch phase {
        case .notStarted: return NSLocalizedString("sync.setup.notStarted", value: "Sync has not started", comment: "All sync waits for pairing completion")
        case .checking: return NSLocalizedString("sync.status.checking", value: "Checking sync status…", comment: "Sync status not yet known")
        case .initialSync: return NSLocalizedString("sync.status.initial", value: "Initial sync in progress", comment: "First sync is receiving account data")
        case .syncing: return NSLocalizedString("sync.status.syncing", value: "Syncing…", comment: "Sync has pending work")
        case .upToDate: return NSLocalizedString("sync.status.upToDate", value: "Up to date", comment: "All required contexts completed sync")
        case .offline: return NSLocalizedString("sync.status.offline", value: "Offline — changes will sync when connected", comment: "Eligible data waits for connectivity")
        case .needsAttention: return NSLocalizedString("sync.status.needsAttention", value: "Needs attention", comment: "Sync has a failure requiring attention")
        }
    }

    /// The pane's only destructive action, at the bottom and in the same
    /// secondary style as every other button on the pane. The confirmation, its
    /// copy and the `last_device` note all come from `SelfRevokeStrings`, shared
    /// with the pairing gate's exit of the same name.
    private var removeDeviceSection: some View {
        section(NSLocalizedString("sync.recovery.title", value: "Recovery and removal", comment: "Recovery guidance and device removal")) {
            SettingsDetailCard {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        hintText(NSLocalizedString("sync.recovery.explanation", value: "To join on another device, approve its request here or use your saved recovery code. The code is shown only when sync is first set up.", comment: "Explain existing recovery options without offering retrieval"))
                        if let note = removeModel.note {
                            // `note` carries two different kinds of line: the standing
                            // `last_device` explanation (informational) and a transient
                            // failure the user has to notice and retry. The latter is
                            // coloured like every other error on this pane.
                            if removeModel.noteIsError {
                                errorText(note)
                            } else {
                                hintText(note)
                            }
                        }
                    }
                    Spacer(minLength: 12)
                    if removeModel.isRemoving {
                        ProgressView().controlSize(.small)
                    }
                    actionButton(NSLocalizedString("sync.devices.removeThisDevice",
                                                   value: "Remove this device from sync…",
                                                   comment: "Devices settings - button that removes this device from sync")) {
                        Task { await removeModel.requestRemoval(confirm: SelfRevokeStrings.confirmRemoval) }
                    }
                    .disabled(!removeModel.canRequestRemoval || viewModel.isReconfiguring)
                }
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private var pendingSection: some View {
        if viewModel.pending.isEmpty {
            hintText(NSLocalizedString("sync.devices.noPendingRequests", value: "No devices are waiting for approval.", comment: "Devices settings - shown when no device is waiting for approval"))
                .padding(.vertical, 12)
        } else {
            ForEach(Array(viewModel.pending.enumerated()), id: \.element.id) { index, item in
                if index > 0 { Divider() }
                row(String(format: NSLocalizedString("sync.devices.pendingRequestTitle", value: "%1$@ · %2$@", comment: "Devices settings - a device waiting to join; %1$@ is the device name, %2$@ its platform, such as macOS"), item.name, Self.platformName(item.platform))) {
                    // Deliberately not selectable (no `.textSelection`
                    // modifier): it installs an NSTextView, and the
                    // 3-second poll that refreshes `viewModel.pending` can
                    // remove this row while AppKit's mouse-tracking loop is
                    // live, orphaning the loop and hanging the main thread.
                    hintText(String(format: NSLocalizedString("sync.devices.expiresAt", value: "Expires: %@", comment: "Devices settings - when a pending join request expires; %@ is the time"), item.deadline.formatted(date: .omitted, time: .shortened)))
                    Text(String(format: NSLocalizedString("sync.devices.verifyCode", value: "Verify this code matches the other device: %@", comment: "Devices settings - asks to compare a join request's code with the other device; %@ is the code"), item.verificationCode))
                        .font(.system(size: 12, design: .monospaced))
                        .themedForeground(.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                } control: {
                    if viewModel.busyRequestIDs.contains(item.id) { ProgressView().controlSize(.small) }
                    actionButton(NSLocalizedString("sync.devices.approve", value: "Approve", comment: "Devices settings - button that approves a device waiting to join")) {
                        Task { await viewModel.approve(item) }
                    }
                    .disabled(viewModel.busyRequestIDs.contains(item.id))
                    actionButton(NSLocalizedString("sync.devices.deny", value: "Deny", comment: "Devices settings - button that denies a device waiting to join")) {
                        Task { await viewModel.deny(item) }
                    }
                    .disabled(viewModel.busyRequestIDs.contains(item.id))
                }
            }
        }
    }
}

extension DevicesSettingView {
    /// Platform identifiers arrive from the sync backend in lowercase (`macos`). They are shown
    /// as product names, which are not translated; an unknown identifier is shown unchanged.
    static func platformName(_ platform: String) -> String {
        switch platform.lowercased() {
        case "macos": return "macOS"
        case "ios": return "iOS"
        case "ipados": return "iPadOS"
        case "windows": return "Windows"
        case "linux": return "Linux"
        case "android": return "Android"
        case "chromeos": return "ChromeOS"
        default: return platform
        }
    }
}
