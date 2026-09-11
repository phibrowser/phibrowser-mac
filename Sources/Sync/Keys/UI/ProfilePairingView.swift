import SwiftUI

/// Where this view is being shown. The Devices pane keeps today's English copy
/// and today's button title verbatim; the join gate uses the finalized Chinese
/// copy and gets the secondary "remove this device" slot.
enum ProfilePairingContext {
    case gate
    case settings
}

/// The pure decision core behind `ProfilePairingView`: everything the rows and
/// the enable predicate derive from the view's two `@State` dictionaries, with
/// no SwiftUI in it.
///
/// It is a separate type because the invariants the app-modal gate depends on
/// are not view rendering, they are logic that must hold on every input:
///
/// - **At most ONE decision per local profile.** Two decisions for the same
///   local (its own row's `.registerNew` plus a remote row's `.adopt`) apply in
///   order in `submitPairing`, so the register mints an account profile that the
///   adopt then abandons. Nothing claims it, `needsPairing` stays true forever,
///   and the gate's `guard !isPresented` keeps the browser blocked behind a
///   modal that can never be closed.
/// - **No row may offer a choice that is not honoured.** A remote whose envelope
///   will not open (`name == nil`) is offered by NO picker, local or remote:
///   both of its decisions throw inside `adoptRemoteProfile` ->
///   `openProfilePayload`, so offering one is a button that always fails.
/// - **No local may be claimed twice.** A local is offered by at most one remote
///   row at a time, and a choice whose target local has since gone elsewhere
///   reads back as UNDECIDED instead of surviving invisibly.
struct ProfilePairingModel {
    /// One local row's decision.
    enum Choice: Hashable {
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

    let locals: [PairingLocal]
    let remotes: [RemoteProfile]
    let selections: [String: Choice]
    let remoteChoices: [String: RemoteChoice]

    /// Default preselection: a remote whose decrypted name matches the local's
    /// display name, each remote claimed at most once. This is only a starting
    /// point — the user still has to hit Confirm.
    static func initialSelections(locals: [PairingLocal], remotes: [RemoteProfile]) -> [String: Choice] {
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
        return initial
    }

    func selection(for local: PairingLocal) -> Choice {
        selections[local.profileId] ?? .registerNew
    }

    /// Remote uuids claimed by a local row's own picker.
    var claimedByLocalSelections: Set<String> {
        Set(locals.compactMap { local -> String? in
            if case .remote(let uuid) = selection(for: local) { return uuid }
            return nil
        })
    }

    /// Remotes selectable in `local`'s picker: decryptable, and not already
    /// claimed by a *different* local's current selection (so `local`'s own
    /// selection always stays in its own list, even in the states the UI cannot
    /// otherwise produce — a Picker whose selected tag is missing renders blank).
    func remoteOptions(for local: PairingLocal) -> [RemoteProfile] {
        let own: String? = {
            if case .remote(let uuid) = selection(for: local) { return uuid }
            return nil
        }()
        let claimedByOthers = Set(locals.filter { $0.profileId != local.profileId }.compactMap { other -> String? in
            if case .remote(let uuid) = selection(for: other) { return uuid }
            return nil
        })
        return remotes.filter { remote in
            if remote.uuid == own { return true }
            return remote.name != nil && !claimedByOthers.contains(remote.uuid)
        }
    }

    /// Remotes not claimed by any local's current selection — these are the rows
    /// that carry the mandatory "create here / assign to" choice.
    var unclaimedRemotes: [RemoteProfile] {
        let claimed = claimedByLocalSelections
        return remotes.filter { !claimed.contains($0.uuid) }
    }

    /// Locals `remote`'s row may be assigned to: still `registerNew` in their
    /// own picker, and not already claimed by a DIFFERENT remote row. Without
    /// the second half the same local can be assigned twice, and the second
    /// `adoptRemoteProfile` simply overwrites the first mapping — leaving the
    /// first remote unclaimed and the gate open.
    func assignableLocals(for remote: RemoteProfile) -> [PairingLocal] {
        let claimedByOtherRows = Set(remoteChoices.compactMap { uuid, choice -> String? in
            guard uuid != remote.uuid, case .adopt(let localProfileId) = choice else { return nil }
            return localProfileId
        })
        return locals.filter { local in
            guard case .registerNew = selection(for: local) else { return false }
            return !claimedByOtherRows.contains(local.profileId)
        }
    }

    /// This remote row's LIVE choice. A stored choice reads back as UNDECIDED
    /// when the row no longer offers it — the remote became claimed by a local
    /// row, its envelope does not open, or its target local left
    /// `assignableLocals`. Otherwise `allDecided` would report "decided" for a
    /// row whose picker shows blank, and `decisions()` would emit it.
    func choice(for remote: RemoteProfile) -> RemoteChoice? {
        guard remote.name != nil, !claimedByLocalSelections.contains(remote.uuid),
              let choice = remoteChoices[remote.uuid] else { return nil }
        if case .adopt(let localProfileId) = choice,
           !assignableLocals(for: remote).contains(where: { $0.profileId == localProfileId }) {
            return nil
        }
        return choice
    }

    /// Remote uuids some row has taken responsibility for: a local's own picker,
    /// or a remote row's "指派给 X".
    var claimedRemoteUuids: Set<String> {
        claimedByLocalSelections.union(remotes.compactMap { remote -> String? in
            if case .adopt = choice(for: remote) { return remote.uuid }
            return nil
        })
    }

    /// Remote uuids whose row chose "在这台 Mac 上创建".
    var createLocalUuids: Set<String> {
        Set(remotes.compactMap { remote -> String? in
            choice(for: remote) == .createLocal ? remote.uuid : nil
        })
    }

    /// The local profile a decision acts on, if any (`.createLocal` creates its
    /// local afterwards, so it names none yet).
    static func localProfileId(of decision: PairingDecision) -> String? {
        switch decision {
        case .adopt(let localProfileId, _): return localProfileId
        case .registerNew(let localProfileId, _): return localProfileId
        case .createLocal: return nil
        }
    }

    func decisions() -> [PairingDecision] {
        let liveChoices: [(remote: RemoteProfile, choice: RemoteChoice)] = remotes.compactMap { remote in
            guard let choice = choice(for: remote) else { return nil }
            return (remote, choice)
        }
        // Locals a remote row already claimed with "指派给 X". Their own row
        // must NOT also emit a decision: the `.registerNew` would mint an
        // account profile that the row's `.adopt` then abandons, and an
        // unclaimed account profile pins `needsPairing` true forever.
        let adoptedLocals = Set(liveChoices.compactMap { pair -> String? in
            if case .adopt(let localProfileId) = pair.choice { return localProfileId }
            return nil
        })

        var decisions: [PairingDecision] = []
        for local in locals where !adoptedLocals.contains(local.profileId) {
            switch selection(for: local) {
            case .remote(let uuid):
                decisions.append(.adopt(localProfileId: local.profileId, remoteUuid: uuid))
            case .registerNew:
                decisions.append(.registerNew(localProfileId: local.profileId, displayName: local.displayName))
            }
        }
        for pair in liveChoices {
            // `.createLocal`'s displayName is the DECRYPTED name, never
            // `remoteLabel(remote)`: the latter falls back to
            // "Unnamed profile (xxxxxxxx)" for a row that will not open, and
            // §3.6's precheck would take that string for a real profile name.
            guard let name = pair.remote.name else { continue }   // read-only row
            switch pair.choice {
            case .createLocal:
                decisions.append(.createLocal(remoteUuid: pair.remote.uuid, displayName: name))
            case .adopt(let localProfileId):
                decisions.append(.adopt(localProfileId: localProfileId, remoteUuid: pair.remote.uuid))
            }
        }

        let named = decisions.compactMap(Self.localProfileId(of:))
        assert(Set(named).count == named.count,
               "two decisions for one local profile mint an orphan account profile and pin the gate open")
        return decisions
    }
}

/// `.settings` 上下文（Devices pane）的状态壳。§5.3 把这两份状态上提到了向导 VM 上
/// （页脚要读 `allRowsDecided` 与 `decisions()`，而它已经不在这个 view 里了），
/// Devices pane 没有向导 VM，所以由这里持一个最小的壳。**渲染结果逐字不变**，
/// 种子与今天 `init` 里那句 `State(initialValue: ProfilePairingModel.initialSelections(…))`
/// 是同一句，只是搬到了外面。
@MainActor
final class ProfilePairingSelectionStore: ObservableObject {
    @Published var selections: [String: ProfilePairingModel.Choice] = [:]
    @Published var remoteChoices: [String: ProfilePairingModel.RemoteChoice] = [:]

    func seed(locals: [PairingLocal], remotes: [RemoteProfile]) {
        selections = ProfilePairingModel.initialSelections(locals: locals, remotes: remotes)
        remoteChoices = [:]
    }
}

/// Lets the user resolve an ambiguous local-profile <-> remote-profile mapping
/// by hand: one row per local profile with a picker over the unclaimed remote
/// profiles (or "Register as new"), plus a row per remote nobody claimed with a
/// mandatory "create here / assign to a local profile" choice. Nothing is
/// applied until the user confirms — `KeyLayerViewModel.startPairing` only loads
/// candidates, it never preselects a decision automatically.
///
/// All row logic lives in `ProfilePairingModel`; this type is the SwiftUI shell.
struct ProfilePairingView: View {
    typealias Choice = ProfilePairingModel.Choice
    typealias RemoteChoice = ProfilePairingModel.RemoteChoice

    @ObservedObject var viewModel: KeyLayerViewModel
    let locals: [PairingLocal]
    let remotes: [RemoteProfile]
    let context: ProfilePairingContext
    /// Optional extra button next to the primary one (the gate passes
    /// "从同步中移除本设备…"; the Devices pane passes nil).
    ///
    /// `enabled` / `note` exist for the gate's one degraded case: a 409
    /// `last_device` is only knowable by trying, so the button is greyed IN PLACE
    /// with the reason underneath rather than pre-probed away.
    let secondaryButton: (title: String, enabled: Bool, note: String?, action: () -> Void)?
    var onSubmit: ([PairingDecision]) -> Void

    @Binding var selections: [String: Choice]
    @Binding var remoteChoices: [String: RemoteChoice]

    init(viewModel: KeyLayerViewModel,
         locals: [PairingLocal],
         remotes: [RemoteProfile],
         selections: Binding<[String: Choice]>,
         remoteChoices: Binding<[String: RemoteChoice]>,
         context: ProfilePairingContext = .settings,
         secondaryButton: (title: String, enabled: Bool, note: String?, action: () -> Void)? = nil,
         onSubmit: @escaping ([PairingDecision]) -> Void) {
        self.context = context
        self.secondaryButton = secondaryButton
        self._viewModel = ObservedObject(wrappedValue: viewModel)
        self.locals = locals
        self.remotes = remotes
        self.onSubmit = onSubmit
        self._selections = selections
        self._remoteChoices = remoteChoices
    }

    /// The row logic, rebuilt from the current selection state on every evaluation.
    private var model: ProfilePairingModel {
        ProfilePairingModel(locals: locals, remotes: remotes,
                            selections: selections, remoteChoices: remoteChoices)
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

                if !model.unclaimedRemotes.isEmpty {
                    Text(NSLocalizedString("Unclaimed account profiles", comment: "Profile pairing - unclaimed remotes header"))
                        .font(.headline)
                        .themedForeground(.textPrimaryStrong)
                    ForEach(model.unclaimedRemotes, id: \.uuid) { remote in
                        remoteRow(remote)
                    }
                }

                if let pairingError = viewModel.pairingError {
                    Text(pairingError)
                        .font(.callout)
                        .foregroundColor(.red)
                }

                HStack(spacing: 12) {
                    Button(primaryTitle) { onSubmit(model.decisions()) }
                        .buttonStyle(.borderedProminent)
                        .disabled(viewModel.phase == .working || !allDecided)
                    if let secondaryButton {
                        Button(secondaryButton.title, action: secondaryButton.action)
                            .buttonStyle(.bordered)
                            .disabled(!secondaryButton.enabled)
                    }
                }
                if let note = secondaryButton?.note {
                    Text(note).font(.callout).foregroundColor(.secondary)
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
                ForEach(model.remoteOptions(for: local), id: \.uuid) { remote in
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
                    ForEach(model.assignableLocals(for: remote), id: \.profileId) { local in
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

    /// Reads through `model.choice(for:)` so a stale entry shows as "请选择"
    /// instead of a blank Picker, and prunes the state on write.
    private func remoteChoiceBinding(for remote: RemoteProfile) -> Binding<RemoteChoice?> {
        Binding(
            get: { model.choice(for: remote) },
            set: { newValue in
                var updated = remoteChoices
                updated[remote.uuid] = newValue
                remoteChoices = pruned(updated, usingSelections: selections)
            }
        )
    }

    private func binding(for local: PairingLocal) -> Binding<Choice> {
        Binding(
            get: { model.selection(for: local) },
            set: { newValue in
                var updated = selections
                updated[local.profileId] = newValue
                selections = updated
                // A local that just left `registerNew` (or took a remote a row
                // was assigning elsewhere) invalidates that row's choice.
                remoteChoices = pruned(remoteChoices, usingSelections: updated)
            }
        )
    }

    /// Drops remote-row choices their row no longer offers, so the stored state
    /// matches what the user can see. `ProfilePairingModel.choice(for:)` already
    /// ignores them; this keeps `@State` from carrying a decision nothing will
    /// honour. Both inputs are passed in rather than read back from `@State`,
    /// which is not guaranteed to reflect a write made in the same update.
    private func pruned(_ choices: [String: RemoteChoice],
                        usingSelections newSelections: [String: Choice]) -> [String: RemoteChoice] {
        let live = ProfilePairingModel(locals: locals, remotes: remotes,
                                       selections: newSelections, remoteChoices: choices)
        var kept: [String: RemoteChoice] = [:]
        for remote in remotes {
            if let choice = live.choice(for: remote) { kept[remote.uuid] = choice }
        }
        return kept
    }

    /// The single enable predicate, shared by both contexts. Undecidable rows
    /// (`name == nil`) are excluded by `allRowsDecided` itself.
    private var allDecided: Bool {
        let live = model
        return viewModel.allRowsDecided(remotes: remotes,
                                        claimedRemoteUuids: live.claimedRemoteUuids,
                                        createLocalUuids: live.createLocalUuids)
    }

    private func remoteLabel(_ remote: RemoteProfile) -> String {
        remote.name ?? String(format: NSLocalizedString(
            "Unnamed profile (%@)", comment: "Profile pairing - remote profile whose name couldn’t be decrypted"),
            String(remote.uuid.prefix(8)))
    }
}

#if DEBUG
/// 预览宿主：两个 `@Binding` 现在是必填参数，而 `.constant([:])` 写不回去（Picker 要
/// 能写），所以预览自己持一个 `ProfilePairingSelectionStore` 并交出它的 binding。
private struct ProfilePairingPreviewHost: View {
    @StateObject private var store = ProfilePairingSelectionStore()
    let locals: [PairingLocal]
    let remotes: [RemoteProfile]
    let context: ProfilePairingContext
    let secondaryButton: (title: String, enabled: Bool, note: String?, action: () -> Void)?

    var body: some View {
        ProfilePairingView(viewModel: KeyLayerViewModel.preview(), locals: locals, remotes: remotes,
                           selections: $store.selections, remoteChoices: $store.remoteChoices,
                           context: context, secondaryButton: secondaryButton, onSubmit: { _ in })
            .onAppear { store.seed(locals: locals, remotes: remotes) }
    }
}

#Preview("Profile Pairing") {
    ProfilePairingPreviewHost(
        locals: [PairingLocal(profileId: "Default", displayName: "Default"),
                 PairingLocal(profileId: "Profile 1", displayName: "Home")],
        remotes: [RemoteProfile(uuid: "11111111-1111-1111-1111-111111111111", name: "Home"),
                  RemoteProfile(uuid: "22222222-2222-2222-2222-222222222222", name: nil)],
        context: .settings,
        secondaryButton: nil)
}

/// The join gate's own shape: no local profile is still undecided, so every row
/// is an unclaimed account profile. Pins §(5) — with `locals == []` the remote
/// picker is left with "请选择 / 在这台 Mac 上创建" and the sheet is still
/// decidable and still submittable.
#Preview("Profile Pairing - remotes only") {
    ProfilePairingPreviewHost(
        locals: [],
        remotes: [RemoteProfile(uuid: "11111111-1111-1111-1111-111111111111", name: "Home"),
                  RemoteProfile(uuid: "22222222-2222-2222-2222-222222222222", name: nil)],
        context: .gate,
        secondaryButton: (title: "从同步中移除本设备…", enabled: true, note: nil, action: {}))
}
#endif
