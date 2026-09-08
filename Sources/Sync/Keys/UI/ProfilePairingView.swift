import SwiftUI

/// Where this view is being shown. The Devices pane keeps today's English copy
/// and today's button title verbatim; the join gate uses the finalized Chinese
/// copy and gets the secondary "remove this device" slot.
enum ProfilePairingContext {
    case gate
    case settings
}

/// Lets the user resolve an ambiguous local-profile <-> remote-profile mapping
/// by hand: one row per local profile with a picker over the unclaimed remote
/// profiles (or "Register as new"), plus a row per remote nobody claimed with a
/// mandatory "create here / assign to a local profile" choice. Nothing is
/// applied until the user confirms — `KeyLayerViewModel.startPairing` only loads
/// candidates, it never preselects a decision automatically.
struct ProfilePairingView: View {
    private enum Choice: Hashable {
        case remote(String)
        case registerNew
    }

    /// One unclaimed remote row's decision. `nil` (absent from the dictionary)
    /// is the third state -- UNDECIDED -- and it is what keeps the main button
    /// disabled. The shipped default-off `Toggle` silently dropped exactly this
    /// case, which is the defect both contexts are fixing.
    enum RemoteChoice: Hashable {
        case createLocal
        case adopt(localProfileId: String)
    }

    @ObservedObject var viewModel: KeyLayerViewModel
    let locals: [PairingLocal]
    let remotes: [RemoteProfile]
    let context: ProfilePairingContext
    /// Optional extra button next to the primary one (the gate passes
    /// "从同步中移除本设备…"; the Devices pane passes nil).
    let secondaryButton: (title: String, action: () -> Void)?
    var onSubmit: ([PairingDecision]) -> Void

    @State private var selections: [String: Choice]
    @State private var remoteChoices: [String: RemoteChoice] = [:]

    init(viewModel: KeyLayerViewModel,
         locals: [PairingLocal],
         remotes: [RemoteProfile],
         context: ProfilePairingContext = .settings,
         secondaryButton: (title: String, action: () -> Void)? = nil,
         onSubmit: @escaping ([PairingDecision]) -> Void) {
        self.context = context
        self.secondaryButton = secondaryButton
        self._viewModel = ObservedObject(wrappedValue: viewModel)
        self.locals = locals
        self.remotes = remotes
        self.onSubmit = onSubmit

        // Default preselection: a remote whose decrypted name matches the
        // local's display name, each remote claimed at most once. This is
        // only a starting point — the user still has to hit Confirm.
        var initial: [String: Choice] = [:]
        var claimed: Set<String> = []
        for local in locals {
            if let match = remotes.first(where: { $0.name == local.displayName && !claimed.contains($0.uuid) }) {
                initial[local.profileId] = .remote(match.uuid)
                claimed.insert(match.uuid)
            } else {
                initial[local.profileId] = .registerNew
            }
        }
        self._selections = State(initialValue: initial)
    }

    private var titleText: String {
        switch context {
        case .gate: return NSLocalizedString("完成 Profile 配对", comment: "Pairing gate - title")
        case .settings: return NSLocalizedString("Match your profiles", comment: "Profile pairing - title")
        }
    }

    private var bodyText: String {
        switch context {
        case .gate:
            return NSLocalizedString(
                "这台 Mac 上的 Profile 需要与账户里的 Profile 一一对应，Phi 才能把 Space 和书签同步到正确的 Profile。完成配对前，浏览器暂时不可用。",
                comment: "Pairing gate - explanation")
        case .settings:
            return NSLocalizedString(
                "We found profiles on this Mac and on your account that we couldn’t match automatically. Pick which account profile each local profile belongs to.",
                comment: "Profile pairing - explanation")
        }
    }

    private var primaryTitle: String {
        switch context {
        case .gate: return NSLocalizedString("完成配对", comment: "Pairing gate - confirm button")
        case .settings: return NSLocalizedString("Confirm", comment: "Profile pairing - confirm button")
        }
    }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 20) {
                Text(titleText)
                    .font(.title2.bold())
                    .themedForeground(.textPrimaryStrong)

                Text(bodyText)
                    .font(.body)
                    .themedForeground(.textPrimary)

                ForEach(locals) { local in
                    localRow(local)
                }

                if !unclaimedRemotes.isEmpty {
                    Text(NSLocalizedString("Unclaimed account profiles", comment: "Profile pairing - unclaimed remotes header"))
                        .font(.headline)
                        .themedForeground(.textPrimaryStrong)
                    ForEach(unclaimedRemotes, id: \.uuid) { remote in
                        remoteRow(remote)
                    }
                }

                if let pairingError = viewModel.pairingError {
                    Text(pairingError)
                        .font(.callout)
                        .foregroundColor(.red)
                }

                HStack(spacing: 12) {
                    Button(primaryTitle) { onSubmit(buildDecisions()) }
                        .buttonStyle(.borderedProminent)
                        .disabled(viewModel.phase == .working || !allDecided)
                    if let secondaryButton {
                        Button(secondaryButton.title, action: secondaryButton.action)
                            .buttonStyle(.bordered)
                    }
                }
            }
            .padding(32)
        }
        .frame(minWidth: 420)
    }

    @ViewBuilder
    private func localRow(_ local: PairingLocal) -> some View {
        HStack(spacing: 16) {
            Text(local.displayName)
                .font(.body.bold())
                .themedForeground(.textPrimaryStrong)
            Spacer()
            Picker("", selection: binding(for: local)) {
                ForEach(remoteChoices(excluding: local), id: \.uuid) { remote in
                    Text(remoteLabel(remote)).tag(Choice.remote(remote.uuid))
                }
                Text(NSLocalizedString("Register as new", comment: "Profile pairing - register as new option"))
                    .tag(Choice.registerNew)
            }
            .labelsHidden()
            .frame(maxWidth: 220)
        }
        .padding(12)
        .background(Color(nsColor: .textBackgroundColor))
        .cornerRadius(8)
    }

    @ViewBuilder
    private func remoteRow(_ remote: RemoteProfile) -> some View {
        HStack(spacing: 16) {
            Text(remoteLabel(remote))
                .font(.body.bold())
                .themedForeground(.textPrimaryStrong)
            Spacer()
            if remote.name == nil {
                // Read-only. BOTH of this row's decisions end in
                // `adoptRemoteProfile` -> `openProfilePayload`, which throws for
                // an envelope that will not open under the current ARK. Offering
                // them would leave a modal whose primary button can never
                // succeed and whose other exit (`last_device`) may be closed too.
                Text(NSLocalizedString("暂时无法读取，Phi 会在后台自动重试",
                                       comment: "Profile pairing - undecryptable remote row"))
                    .font(.callout)
                    .themedForeground(.textSecondary)
            } else {
                Picker("", selection: remoteChoiceBinding(for: remote)) {
                    Text(NSLocalizedString("请选择", comment: "Profile pairing - undecided option"))
                        .tag(RemoteChoice?.none)
                    Text(NSLocalizedString("在这台 Mac 上创建",
                                           comment: "Profile pairing - create locally option"))
                        .tag(RemoteChoice?.some(.createLocal))
                    ForEach(unmappedLocals, id: \.profileId) { local in
                        Text(String(format: NSLocalizedString("指派给 %@",
                                    comment: "Profile pairing - assign to a local profile"),
                                    local.displayName))
                            .tag(RemoteChoice?.some(.adopt(localProfileId: local.profileId)))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 260)
            }
        }
        .padding(12)
        .background(Color(nsColor: .textBackgroundColor))
        .cornerRadius(8)
    }

    private func remoteChoiceBinding(for remote: RemoteProfile) -> Binding<RemoteChoice?> {
        Binding(
            get: { remoteChoices[remote.uuid] },
            set: { remoteChoices[remote.uuid] = $0 }
        )
    }

    /// Locals whose own picker is still `registerNew`, i.e. the ones a remote
    /// row may legally be assigned to.
    private var unmappedLocals: [PairingLocal] {
        locals.filter {
            if case .registerNew = selections[$0.profileId] ?? .registerNew { return true }
            return false
        }
    }

    private func binding(for local: PairingLocal) -> Binding<Choice> {
        Binding(
            get: { selections[local.profileId] ?? .registerNew },
            set: { selections[local.profileId] = $0 }
        )
    }

    /// Remotes selectable for `local`'s picker: every remote not already
    /// claimed by a *different* local's current selection (so `local`'s own
    /// selection, if any, always stays in its own list).
    private func remoteChoices(excluding local: PairingLocal) -> [RemoteProfile] {
        let claimedByOthers = Set(locals.filter { $0.profileId != local.profileId }.compactMap { other -> String? in
            if case .remote(let uuid) = selections[other.profileId] ?? .registerNew { return uuid }
            return nil
        })
        return remotes.filter { !claimedByOthers.contains($0.uuid) }
    }

    /// Remotes not claimed by any local's current selection — these are the rows
    /// that carry the mandatory "create here / assign to" choice.
    private var unclaimedRemotes: [RemoteProfile] {
        let claimed = Set(locals.compactMap { local -> String? in
            if case .remote(let uuid) = selections[local.profileId] ?? .registerNew { return uuid }
            return nil
        })
        return remotes.filter { !claimed.contains($0.uuid) }
    }

    /// The single enable predicate, shared by both contexts. Undecidable rows
    /// (`name == nil`) are excluded by `allRowsDecided` itself.
    private var allDecided: Bool {
        let claimed = Set(locals.compactMap { local -> String? in
            if case .remote(let uuid) = selections[local.profileId] ?? .registerNew { return uuid }
            return nil
        }).union(remoteChoices.compactMap { uuid, choice -> String? in
            if case .adopt = choice { return uuid }
            return nil
        })
        let createLocals = Set(remoteChoices.compactMap { uuid, choice -> String? in
            choice == .createLocal ? uuid : nil
        })
        return viewModel.allRowsDecided(remotes: remotes,
                                        claimedRemoteUuids: claimed,
                                        createLocalUuids: createLocals)
    }

    private func remoteLabel(_ remote: RemoteProfile) -> String {
        remote.name ?? String(format: NSLocalizedString(
            "Unnamed profile (%@)", comment: "Profile pairing - remote profile whose name couldn’t be decrypted"),
            String(remote.uuid.prefix(8)))
    }

    private func buildDecisions() -> [PairingDecision] {
        var decisions: [PairingDecision] = []
        for local in locals {
            switch selections[local.profileId] ?? .registerNew {
            case .remote(let uuid):
                decisions.append(.adopt(localProfileId: local.profileId, remoteUuid: uuid))
            case .registerNew:
                decisions.append(.registerNew(localProfileId: local.profileId, displayName: local.displayName))
            }
        }
        let claimedByLocals = Set(decisions.compactMap { decision -> String? in
            if case .adopt(_, let uuid) = decision { return uuid }
            return nil
        })
        for remote in remotes where !claimedByLocals.contains(remote.uuid) {
            // `.createLocal`'s displayName is the DECRYPTED name, never
            // `remoteLabel(remote)`: the latter falls back to
            // "Unnamed profile (xxxxxxxx)" for a row that will not open, and
            // §3.6's precheck would take that string for a real profile name.
            guard let name = remote.name else { continue }   // read-only row
            switch remoteChoices[remote.uuid] {
            case .createLocal:
                decisions.append(.createLocal(remoteUuid: remote.uuid, displayName: name))
            case .adopt(let localProfileId):
                decisions.append(.adopt(localProfileId: localProfileId, remoteUuid: remote.uuid))
            case nil:
                continue   // unreachable while `allDecided` gates the button
            }
        }
        return decisions
    }
}

#if DEBUG
#Preview("Profile Pairing") {
    ProfilePairingView(
        viewModel: KeyLayerViewModel.preview(),
        locals: [PairingLocal(profileId: "Default", displayName: "Default"),
                 PairingLocal(profileId: "Profile 1", displayName: "Home")],
        remotes: [RemoteProfile(uuid: "11111111-1111-1111-1111-111111111111", name: "Home"),
                  RemoteProfile(uuid: "22222222-2222-2222-2222-222222222222", name: nil)],
        onSubmit: { _ in })
}

/// The join gate's own shape: no local profile is still undecided, so every row
/// is an unclaimed account profile. Pins §(5) — with `locals == []` the remote
/// picker is left with "请选择 / 在这台 Mac 上创建" and the sheet is still
/// decidable and still submittable.
#Preview("Profile Pairing - remotes only") {
    ProfilePairingView(
        viewModel: KeyLayerViewModel.preview(),
        locals: [],
        remotes: [RemoteProfile(uuid: "11111111-1111-1111-1111-111111111111", name: "Home"),
                  RemoteProfile(uuid: "22222222-2222-2222-2222-222222222222", name: nil)],
        context: .gate,
        secondaryButton: (title: "从同步中移除本设备…", action: {}),
        onSubmit: { _ in })
}
#endif
