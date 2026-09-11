import SwiftUI

/// Where this view is being shown. The Devices pane (`.settings`) keeps today's
/// English copy, today's button title and today's row chrome verbatim; the
/// pairing wizard's step 1 (`.gate`) renders the ROW LIST ALONE — title, body,
/// primary button and the "remove this device" exit all live in
/// `PairingWizardView`'s chrome (§5.3), and the rows take the wizard's card
/// chrome (`RowChrome`).
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
    /// or a remote row's "Assign to X".
    var claimedRemoteUuids: Set<String> {
        claimedByLocalSelections.union(remotes.compactMap { remote -> String? in
            if case .adopt = choice(for: remote) { return remote.uuid }
            return nil
        })
    }

    /// Remote uuids whose row chose "Create on this Mac".
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
        // Locals a remote row already claimed with "Assign to X". Their own row
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
    /// Optional extra button next to the primary one. Rendered by the
    /// `.settings` branch only — the wizard's footer owns its own exits — and
    /// every caller in the tree passes nil today.
    ///
    /// `enabled` / `note` exist for the one degraded case the self-revoke exit
    /// has: a 409 `last_device` is only knowable by trying, so the button is
    /// greyed IN PLACE with the reason underneath rather than pre-probed away.
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

    /// `.gate` 上下文下这三样归向导 chrome（§5.3），所以这里只剩 `.settings` 一支。
    ///
    /// **internal `static`，不是 `private var`**：§10.7 第 5 条要求把 Devices pane 的
    /// 文案「用一条显式断言钉住，而不是靠肉眼看 diff」，而 `private` 的计算属性在
    /// `@testable import` 下也够不着。值与今天 `titleText` / `bodyText` /
    /// `primaryTitle` 的 `.settings` 分支逐字相同。
    static let settingsTitle = NSLocalizedString("Match your profiles",
                                                 comment: "Profile pairing - title")
    static let settingsBody = NSLocalizedString(
        "We found profiles on this Mac and on your account that we couldn’t match automatically. Pick which account profile each local profile belongs to.",
        comment: "Profile pairing - explanation")
    static let settingsPrimaryTitle = NSLocalizedString("Confirm",
                                                        comment: "Profile pairing - confirm button")

    var body: some View {
        switch context {
        case .settings:
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 20) {
                    Text(Self.settingsTitle).font(.title2.bold()).themedForeground(.textPrimaryStrong)
                    Text(Self.settingsBody).font(.body).themedForeground(.textPrimary)
                    rows
                    if let pairingError = viewModel.pairingError {
                        Text(pairingError).font(.callout).foregroundColor(.red)
                    }
                    HStack(spacing: 12) {
                        Button(Self.settingsPrimaryTitle) { onSubmit(model.decisions()) }
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
        case .gate:
            VStack(alignment: .leading, spacing: 20) {
                rows
                if let pairingError = viewModel.pairingError {
                    Text(pairingError).font(.callout).foregroundColor(.red)
                }
            }
        }
    }

    /// 两个上下文共享的行列表（`localRow` / `remoteRow` 与那条 header 一字不动）。
    @ViewBuilder
    private var rows: some View {
        ForEach(locals) { local in localRow(local) }
        if !model.unclaimedRemotes.isEmpty {
            Text(NSLocalizedString("Unclaimed account profiles",
                                   comment: "Profile pairing - unclaimed remotes header"))
                .font(.headline)
                .themedForeground(.textPrimaryStrong)
            ForEach(model.unclaimedRemotes, id: \.uuid) { remote in remoteRow(remote) }
        }
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
        .modifier(RowChrome(context: context))
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
                Text(NSLocalizedString("Can’t be read right now — Phi keeps retrying in the background",
                                       comment: "Profile pairing - undecryptable remote row"))
                    .font(.callout)
                    .themedForeground(.textSecondary)
            } else {
                Picker("", selection: remoteChoiceBinding(for: remote)) {
                    Text(NSLocalizedString("Choose…",
                                           comment: "Profiles settings - download location not set"))
                        .tag(RemoteChoice?.none)
                    Text(NSLocalizedString("Create on this Mac",
                                           comment: "Profile pairing - create locally option"))
                        .tag(RemoteChoice?.some(.createLocal))
                    ForEach(model.assignableLocals(for: remote), id: \.profileId) { local in
                        Text(String(format: NSLocalizedString("Assign to %@",
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
        .modifier(RowChrome(context: context))
    }

    /// Reads through `model.choice(for:)` so a stale entry shows as "Choose…"
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

/// 行卡片的背景，**按上下文分叉**：`.gate` 走向导的 `settingsCardChrome()`，
/// `.settings` **逐字保留今天那两句**。不能一刀切换掉：这两个行构造器与 Devices pane
/// 的 `.settings` 表面是同一份代码，而 §5.3 / §6.8 / §11 都把 `.settings` 的渲染结果
/// 钉成「逐字不变」。
struct RowChrome: ViewModifier {
    let context: ProfilePairingContext

    /// 分叉判据抽成一个**纯**函数，视图与测试读同一个 switch。§10.7 第 5 条要的
    /// 「显式断言」钉的就是它：`ViewModifier` 的求值结果没法在 XCTest 里比较，能钉住
    /// 的是「`.settings` 走的仍然是今天那条腿」，而这正是唯一会退化的东西。
    enum Kind: Equatable {
        /// 向导的卡片 chrome（`settingsCardChrome()`）。
        case wizardCard
        /// **今天那两句，逐字**：`.background(Color(nsColor: .textBackgroundColor))`
        /// + `.cornerRadius(8)`。Devices pane 只能是这一条。
        case legacyTextBackground
    }

    static func kind(for context: ProfilePairingContext) -> Kind {
        switch context {
        case .gate: return .wizardCard
        case .settings: return .legacyTextBackground
        }
    }

    func body(content: Content) -> some View {
        switch Self.kind(for: context) {
        case .wizardCard:
            content.settingsCardChrome()
        case .legacyTextBackground:
            content.background(Color(nsColor: .textBackgroundColor)).cornerRadius(8)
        }
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

/// No local profile is still undecided, so every row is an unclaimed account
/// profile. Pins §(5) — with `locals == []` the remote picker is left with
/// "Choose… / Create on this Mac" and the sheet is still decidable and still
/// submittable.
///
/// `.settings`, not `.gate`: M3-2b's `.gate` branch renders the row list ALONE
/// (title, body and buttons moved to the wizard's chrome), so a `.gate` preview
/// would be a near-empty view that pins nothing. The gate-shaped preview now
/// belongs to `PairingWizardView`.
#Preview("Profile Pairing - remotes only") {
    ProfilePairingPreviewHost(
        locals: [],
        remotes: [RemoteProfile(uuid: "11111111-1111-1111-1111-111111111111", name: "Home"),
                  RemoteProfile(uuid: "22222222-2222-2222-2222-222222222222", name: nil)],
        context: .settings,
        secondaryButton: nil)
}
#endif
