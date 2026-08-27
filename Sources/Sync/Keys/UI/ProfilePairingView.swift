import SwiftUI

/// Lets the user resolve an ambiguous local-profile <-> remote-profile mapping
/// by hand: one row per local profile with a picker over the unclaimed remote
/// profiles (or "Register as new"), plus a list of any remotes nobody claimed
/// with a "Create on this Mac" toggle. Nothing is applied until the user taps
/// Confirm — `KeyLayerViewModel.startPairing` only loads candidates, it never
/// preselects a decision automatically.
struct ProfilePairingView: View {
    private enum Choice: Hashable {
        case remote(String)
        case registerNew
    }

    @ObservedObject var viewModel: KeyLayerViewModel
    let locals: [PairingLocal]
    let remotes: [RemoteProfile]
    var onSubmit: ([PairingDecision]) -> Void

    @State private var selections: [String: Choice]
    @State private var createOnMac: Set<String> = []

    init(viewModel: KeyLayerViewModel, locals: [PairingLocal], remotes: [RemoteProfile],
         onSubmit: @escaping ([PairingDecision]) -> Void) {
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

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 20) {
                Text(NSLocalizedString("Match your profiles", comment: "Profile pairing - title"))
                    .font(.title2.bold())
                    .themedForeground(.textPrimaryStrong)

                Text(NSLocalizedString(
                    "We found profiles on this Mac and on your account that we couldn’t match automatically. Pick which account profile each local profile belongs to.",
                    comment: "Profile pairing - explanation"))
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

                Button(NSLocalizedString("Confirm", comment: "Profile pairing - confirm button")) {
                    onSubmit(buildDecisions())
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.phase == .working)
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
        Toggle(remoteLabel(remote), isOn: createOnMacBinding(for: remote))
            .themedForeground(.textPrimary)
            .padding(.horizontal, 12)
    }

    private func binding(for local: PairingLocal) -> Binding<Choice> {
        Binding(
            get: { selections[local.profileId] ?? .registerNew },
            set: { selections[local.profileId] = $0 }
        )
    }

    private func createOnMacBinding(for remote: RemoteProfile) -> Binding<Bool> {
        Binding(
            get: { createOnMac.contains(remote.uuid) },
            set: { isOn in
                if isOn { createOnMac.insert(remote.uuid) } else { createOnMac.remove(remote.uuid) }
            }
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

    /// Remotes not claimed by any local's current selection — these are
    /// offered the "Create on this Mac" toggle.
    private var unclaimedRemotes: [RemoteProfile] {
        let claimed = Set(locals.compactMap { local -> String? in
            if case .remote(let uuid) = selections[local.profileId] ?? .registerNew { return uuid }
            return nil
        })
        return remotes.filter { !claimed.contains($0.uuid) }
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
        for remote in remotes where !claimedByLocals.contains(remote.uuid) && createOnMac.contains(remote.uuid) {
            decisions.append(.createLocal(remoteUuid: remote.uuid, displayName: remoteLabel(remote)))
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
#endif
