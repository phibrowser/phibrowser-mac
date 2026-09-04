// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import SwiftUI

/// Settings pane content for developer tooling, moved out of the General pane
/// into its own tab. The "Allow agents to control Phi (CDP)" switch is the
/// Agent control section's master gate: while it is off only that card shows;
/// turning it on reveals the phi-browser skill installer, the allowed-agent
/// list, and the agent permission cards right under it, all in the one
/// section. The password manager (agent credential provider) section is
/// always visible — vault settings stay reachable with agent access off.
/// Both sections share one visual language: grouped `settingsCardChrome()`
/// cards whose rows lead with a `SettingsIconChip` in a 24pt gutter, matching
/// the Agent Password Manager section.
struct DeveloperSettingsView: View {
    // Master switch state lives here (not in the agent-control section) so
    // sibling sections can gate on it too.
    @State private var agentAccessEnabled: Bool =
        PhiPreferences.AgentSpaces.cdpAgentAccessEnabled

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 24) {
                AgentControlSectionView(agentAccessEnabled: $agentAccessEnabled)
                // Deliberately outside the CDP gate: vault login and session
                // settings stay reachable while agent access is off.
                PasswordManagerSectionView()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 36)
            .padding(.horizontal, 36)
            .animation(.easeInOut(duration: 0.2), value: agentAccessEnabled)
        }
        // Approving an agent's consent prompt can switch access on while this
        // pane is already open; follow the preference rather than only the
        // toggle's own edits.
        .onReceive(NotificationCenter.default.publisher(for: .agentCDPAccessDidChange)) { _ in
            agentAccessEnabled = PhiPreferences.AgentSpaces.cdpAgentAccessEnabled
        }
        .themedBackground(PhiPreferences.fixedWindowBackground)
        .frame(width: 680, height: 561)
    }
}

/// Section title + content stack, matching the General pane's section layout.
private struct DeveloperSectionView<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.system(size: 12))
                .themedForeground(.textSecondary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Agent control (CDP access, skill install, grants, permissions)

private struct AgentControlSectionView: View {
    // Live master switch for agent CDP access over the app-owned Unix socket.
    // Flipping it starts/stops the listener immediately — no relaunch.
    @Binding var agentAccessEnabled: Bool
    // Agents currently allowed to connect (persisted "Always Allow" plus this
    // session's "Allow Once"). Read live from the listener on appear.
    @State private var allowedGrants: [AgentGrant] =
        AgentCDPListener.shared.allowedGrants()
    // Standing refusals from the consent prompt ("For 30 min" / "Never ask
    // again"). Listed even with agent access off — a permanent block has to be
    // reversible somewhere the user can find it.
    @State private var blockedAgents: [AgentDenial] =
        AgentCDPListener.shared.blockedAgents()
    // Blanket grant: every agent connects without a prompt. Reads on for both
    // the persisted grant and a session-only one made at the consent prompt.
    @State private var allAgentsAllowed: Bool =
        AgentCDPListener.shared.allAgentsGranted
    @State private var userSpaceOperationsEnabled: Bool =
        PhiPreferences.AgentSpaces.userSpaceOperationsEnabled
    @ObservedObject private var profileManager = ProfileManager.shared
    // Profiles the agent may NOT create Spaces in (blocklist mirror; empty =
    // all allowed). Kept in @State for toggle reactivity, written through to
    // the pref on each change.
    @State private var disallowedProfileIds: Set<String> =
        PhiPreferences.AgentSpaces.disallowedAgentProfileIds

    var body: some View {
        DeveloperSectionView(title: NSLocalizedString("settings.developer.agentControl.sectionTitle", value: "Agent control", comment: "Developer settings - Agent control section title")) {
            VStack(alignment: .leading, spacing: 10) {
                accessCard
                if agentAccessEnabled {
                    allowedAgentsCard
                }
                // Outside the access gate: a block recorded before the switch
                // was turned off must stay visible and liftable.
                if !blockedAgents.isEmpty {
                    blockedAgentsCard
                }
                if agentAccessEnabled {
                    permissionsCard
                }
            }
        }
        .onAppear {
            allowedGrants = AgentCDPListener.shared.allowedGrants()
            blockedAgents = AgentCDPListener.shared.blockedAgents()
            allAgentsAllowed = AgentCDPListener.shared.allAgentsGranted
            profileManager.refresh()
        }
    }

    // MARK: Access card — the master gate, with the skill installer under it.

    private var accessCard: some View {
        VStack(spacing: 0) {
            cdpRow
            if agentAccessEnabled {
                Divider()
                SkillInstallRowView()
            }
        }
        .padding(.horizontal, 12)
        .settingsCardChrome()
    }

    private var cdpRow: some View {
        HStack(alignment: .top, spacing: 12) {
            SettingsIconChip(systemName: "sparkles", color: .indigo)
            VStack(alignment: .leading, spacing: 4) {
                Text(NSLocalizedString("settings.developer.agentControl.enableToggle", value: "Allow agents to control Phi (CDP)", comment: "Developer settings - Toggle title for the Chrome DevTools Protocol endpoint"))
                    .font(.system(size: 13))
                    .themedForeground(.textPrimary)
                Text(NSLocalizedString("settings.developer.agentControl.enableDescription", value: "Lets agent tools (Claude Code, Codex) drive Phi over the DevTools Protocol through a private socket only this Mac’s processes can reach. Each agent asks for your approval the first time it connects. Turning this off disconnects them right away; the next agent that connects asks you to turn it back on. Applies immediately.", comment: "Developer settings - Security note for the agent CDP toggle"))
                    .font(.system(size: 11))
                    .themedForeground(.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Toggle("", isOn: Binding(
                get: { agentAccessEnabled },
                set: { newValue in
                    agentAccessEnabled = newValue
                    AgentCDPListener.shared.setEnabled(newValue)
                    // Turning off clears the session grants — the blanket one
                    // included — and turning on lifts every standing refusal;
                    // reflect all three.
                    allowedGrants = AgentCDPListener.shared.allowedGrants()
                    blockedAgents = AgentCDPListener.shared.blockedAgents()
                    allAgentsAllowed = AgentCDPListener.shared.allAgentsGranted
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .themedTint(.themeColor)
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Allowed agents card

    private var allowedAgentsCard: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                SettingsIconChip(systemName: "checkmark.seal.fill", color: .green)
                VStack(alignment: .leading, spacing: 4) {
                    Text(NSLocalizedString("settings.developer.agentControl.allowedAgents.title", value: "Allowed agents", comment: "Developer settings - Title for the allowed CDP agent list"))
                        .font(.system(size: 13))
                        .themedForeground(.textPrimary)
                    Text(NSLocalizedString("settings.developer.agentControl.allowedAgents.description", value: "Processes you’ve approved to control Phi. Removing one makes it ask again next time it connects.", comment: "Developer settings - Explanation for the allowed CDP agent list"))
                        .font(.system(size: 11))
                        .themedForeground(.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            allAgentsRow
            Divider()
            if allowedGrants.isEmpty {
                emptyGrantsState
            } else {
                ForEach(allowedGrants) { grant in
                    grantRow(grant)
                    if grant.id != allowedGrants.last?.id {
                        Divider().padding(.leading, 36)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .settingsCardChrome()
        .animation(.easeOut(duration: 0.15), value: allAgentsAllowed)
    }

    /// The blanket grant, as a switch over the list rather than a row in it:
    /// while it is on the entries below decide nothing, so it has to sit above
    /// them and say so.
    private var allAgentsRow: some View {
        HStack(alignment: .top, spacing: 12) {
            SettingsIconChip(systemName: "person.3.fill", color: .orange)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(NSLocalizedString("settings.developer.agentControl.allowAllAgents.title", value: "Allow all agents", comment: "Developer settings - Toggle title for the blanket grant that lets every agent connect"))
                        .font(.system(size: 13))
                        .themedForeground(.textPrimary)
                    // Only a grant made with "Allow Once" at the consent
                    // prompt is session-scoped; the switch itself persists.
                    if allAgentsAllowed, AgentCDPListener.shared.allAgentsGrantIsSessionOnly {
                        grantScopePill(remembered: false)
                    }
                }
                Text(NSLocalizedString("settings.developer.agentControl.allowAllAgents.description", value: "Lets every agent connect without asking you, including ones Phi has never seen. The approval prompt stops appearing while this is on, and turning it on lifts any standing refusal. Applies immediately.", comment: "Developer settings - Security note for the blanket all-agents grant toggle"))
                    .font(.system(size: 11))
                    .themedForeground(.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Toggle("", isOn: Binding(
                get: { allAgentsAllowed },
                set: { newValue in
                    allAgentsAllowed = newValue
                    AgentCDPListener.shared.setAllAgentsGranted(newValue)
                    // Turning it on clears every standing refusal; reflect it.
                    blockedAgents = AgentCDPListener.shared.blockedAgents()
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .themedTint(.themeColor)
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Empty list. What "empty" means depends on the switch above it: with the
    /// blanket grant on, promising that Phi will ask for approval would be a
    /// lie.
    private var emptyGrantsState: some View {
        VStack(spacing: 6) {
            Image(systemName: allAgentsAllowed ? "person.3.fill" : "checkmark.shield")
                .font(.system(size: 18, weight: .medium))
                .themedForeground(.textTertiary)
            Text(allAgentsAllowed
                 ? NSLocalizedString("settings.developer.agentControl.allowedAgents.allAllowedMessage", value: "Every agent is allowed, so none is approved individually.", comment: "Developer settings - Empty state for the allowed CDP agent list while the blanket all-agents grant is on")
                 : NSLocalizedString("settings.developer.agentControl.allowedAgents.emptyMessage", value: "No agents approved yet. The first time one connects, Phi asks for your approval.", comment: "Developer settings - Empty state for the allowed CDP agent list"))
                .font(.system(size: 11))
                .themedForeground(.textTertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }

    private func grantRow(_ grant: AgentGrant) -> some View {
        HStack(spacing: 12) {
            AgentBrandIcon(assetName: Self.brandAsset(forName: grant.displayName))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(grant.displayName)
                        .font(.system(size: 13, weight: .medium))
                        .themedForeground(.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    grantScopePill(remembered: grant.remembered)
                }
                grantSubtitle(grant)
            }
            Spacer(minLength: 12)
            Button(NSLocalizedString("settings.developer.agentControl.allowedAgents.removeButton", value: "Remove", comment: "Developer settings - Revoke an allowed CDP agent")) {
                AgentCDPListener.shared.forgetGrant(key: grant.key)
                allowedGrants = AgentCDPListener.shared.allowedGrants()
            }
            .controlSize(.small)
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func grantScopePill(remembered: Bool) -> some View {
        let label = remembered
            ? NSLocalizedString("settings.developer.agentControl.grant.permanentStatus", value: "Always", comment: "Developer settings - persisted CDP grant pill")
            : NSLocalizedString("settings.developer.agentControl.grant.sessionStatus", value: "This session", comment: "Developer settings - session-only CDP grant pill")
        let color: Color = remembered ? .indigo : .gray
        return Text(label)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
    }

    /// Second line: the code-signing identity when there is one — a signed
    /// agent names its team, an unsigned one says so plainly.
    @ViewBuilder
    private func grantSubtitle(_ grant: AgentGrant) -> some View {
        if let teamId = grant.teamId, !teamId.isEmpty {
            HStack(spacing: 4) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 9))
                Text(String(format: NSLocalizedString("settings.developer.agentControl.identity.teamSummary", value: "Signed · Team %@", comment: "Developer settings - CDP grant signing team"), teamId))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(.system(size: 11))
            .themedForeground(.textTertiary)
        } else {
            Text(NSLocalizedString("settings.developer.agentControl.identity.unsignedStatus", value: "Unsigned", comment: "Developer settings - CDP grant with no code signature"))
                .font(.system(size: 11))
                .themedForeground(.textTertiary)
        }
    }

    /// The bundled brand icon for a display name that identifies a known
    /// agent, nil for anything else (shown with a generic glyph). Shared by
    /// the allowed and blocked lists so one agent looks the same in both.
    private static func brandAsset(forName displayName: String) -> String? {
        let name = displayName.lowercased()
        if name.contains("claude") { return "agent-claude" }
        if name.contains("codex") || name.contains("openai") { return "agent-openai" }
        if name.contains("cursor") { return "agent-cursor" }
        if name.contains("hermes") { return "agent-hermes" }
        if name.contains("openclaw") { return "agent-openclaw" }
        if name == "pi" { return "agent-pi" }
        return nil
    }

    // MARK: Blocked agents card — the standing refusals, and the way back.

    private var blockedAgentsCard: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                SettingsIconChip(systemName: "nosign", color: .red)
                VStack(alignment: .leading, spacing: 4) {
                    Text(NSLocalizedString("settings.developer.agentControl.blockedAgents.title", value: "Blocked agents", comment: "Developer settings - Title for the list of agents refused at the consent prompt"))
                        .font(.system(size: 13))
                        .themedForeground(.textPrimary)
                    Text(NSLocalizedString("settings.developer.agentControl.blockedAgents.description", value: "Turned away without asking you, from a “Never ask again” or “For 30 min” denial. Unblocking one makes it ask again next time it connects.", comment: "Developer settings - Explanation for the blocked agent list"))
                        .font(.system(size: 11))
                        .themedForeground(.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            ForEach(blockedAgents) { denial in
                blockedRow(denial)
                if denial.id != blockedAgents.last?.id {
                    Divider().padding(.leading, 36)
                }
            }
        }
        .padding(.horizontal, 12)
        .settingsCardChrome()
    }

    private func blockedRow(_ denial: AgentDenial) -> some View {
        HStack(spacing: 12) {
            AgentBrandIcon(assetName: denial.appliesToAllAgents
                           ? nil : Self.brandAsset(forName: denial.displayName))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(denial.displayName)
                        .font(.system(size: 13, weight: .medium))
                        .themedForeground(.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    blockScopePill(denial)
                }
                Text(blockSubtitle(denial))
                    .font(.system(size: 11))
                    .themedForeground(.textTertiary)
            }
            Spacer(minLength: 12)
            Button(NSLocalizedString("settings.developer.agentControl.blockedAgents.removeButton", value: "Unblock", comment: "Developer settings - Lift a standing refusal")) {
                AgentCDPListener.shared.forgetDenial(id: denial.id)
                blockedAgents = AgentCDPListener.shared.blockedAgents()
            }
            .controlSize(.small)
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func blockScopePill(_ denial: AgentDenial) -> some View {
        let label = denial.isPermanent
            ? NSLocalizedString("settings.developer.agentControl.block.permanentStatus", value: "Never", comment: "Developer settings - permanent block pill")
            : NSLocalizedString("settings.developer.agentControl.block.temporaryStatus", value: "Paused", comment: "Developer settings - temporary block pill")
        let color: Color = denial.isPermanent ? .red : .orange
        return Text(label)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
    }

    private func blockSubtitle(_ denial: AgentDenial) -> String {
        guard let expires = denial.expires else {
            return denial.appliesToAllAgents
                ? NSLocalizedString("settings.developer.agentControl.block.allAgentsForeverSubtitle", value: "No agent is asked for approval", comment: "Developer settings - subtitle for a permanent all-agents block")
                : NSLocalizedString("settings.developer.agentControl.block.foreverSubtitle", value: "Refused without asking", comment: "Developer settings - subtitle for a permanent single-agent block")
        }
        return String(
            format: NSLocalizedString("settings.developer.agentControl.block.untilSubtitle", value: "Until %@", comment: "Developer settings - subtitle for a timed block; %@ is a time of day"),
            Self.timeFormatter.string(from: expires))
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    // MARK: Permissions card — what approved agents may touch.

    private var permissionsCard: some View {
        VStack(spacing: 0) {
            operateSpacesRow
            Divider()
            profilesRows
        }
        .padding(.horizontal, 12)
        .settingsCardChrome()
    }

    private var operateSpacesRow: some View {
        HStack(alignment: .top, spacing: 12) {
            SettingsIconChip(systemName: "square.grid.2x2.fill", color: .orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(NSLocalizedString("settings.developer.agentBrowsingDataAccess.enableToggle", value: "Allow agents to operate your Spaces", comment: "Developer settings - Toggle title for agent user-space operations"))
                    .font(.system(size: 13))
                    .themedForeground(.textPrimary)
                Text(NSLocalizedString("settings.developer.agentBrowsingDataAccess.description", value: "Lets agent tooling manage your own browsing data — Spaces, profiles, URL rules, pinned tabs, bookmarks, and the tab layout of your windows. When off, agents can only work inside their own agent Spaces. Applies immediately.", comment: "Developer settings - Explanation for the agent user-space operations toggle"))
                    .font(.system(size: 11))
                    .themedForeground(.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Toggle("", isOn: Binding(
                get: { userSpaceOperationsEnabled },
                set: { newValue in
                    userSpaceOperationsEnabled = newValue
                    PhiPreferences.AgentSpaces.userSpaceOperationsEnabled = newValue
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .themedTint(.themeColor)
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var profilesRows: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                SettingsIconChip(systemName: "person.2.fill", color: .blue)
                VStack(alignment: .leading, spacing: 4) {
                    Text(NSLocalizedString("settings.developer.agentProfileAccess.title", value: "Profiles agents can use", comment: "Developer settings - Title for the per-profile agent-Space allowlist"))
                        .font(.system(size: 13))
                        .themedForeground(.textPrimary)
                    Text(NSLocalizedString("settings.developer.agentProfileAccess.description", value: "Choose which profiles agents may create their own Spaces in. Turning a profile off stops agents from opening any new Space bound to it; existing Spaces are unaffected.", comment: "Developer settings - Explanation for the per-profile agent-Space allowlist"))
                        .font(.system(size: 11))
                        .themedForeground(.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 12)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            if profileManager.userAssignableProfiles.isEmpty {
                Text(NSLocalizedString("settings.developer.agentProfileAccess.emptyMessage", value: "No profiles found.", comment: "Developer settings - Empty state when no browser profiles exist"))
                    .font(.system(size: 11))
                    .themedForeground(.textTertiary)
                    .padding(.leading, 36)
                    .padding(.bottom, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(profileManager.userAssignableProfiles) { profile in
                    HStack(spacing: 12) {
                        Text(profile.displayName)
                            .font(.system(size: 13))
                            .themedForeground(.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 12)
                        Toggle("", isOn: Binding(
                            get: { !disallowedProfileIds.contains(profile.profileId) },
                            set: { allowed in
                                if allowed {
                                    disallowedProfileIds.remove(profile.profileId)
                                } else {
                                    disallowedProfileIds.insert(profile.profileId)
                                }
                                PhiPreferences.AgentSpaces.disallowedAgentProfileIds =
                                    disallowedProfileIds
                            }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .themedTint(.themeColor)
                    }
                    .padding(.leading, 36)
                    .padding(.vertical, 6)
                }
                Color.clear.frame(height: 6)
            }
        }
    }
}

/// 24pt gutter icon for an allowed-agent row: the agent's brand glyph on a
/// neutral rounded square, or a generic terminal glyph for unrecognized
/// processes. Template brand assets take the text color; Hermes's colored
/// artwork renders as-is.
private struct AgentBrandIcon: View {
    let assetName: String?

    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Color.gray.opacity(0.16))
            .frame(width: 24, height: 24)
            .overlay {
                if let assetName {
                    Image(assetName)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 14, height: 14)
                        .themedForeground(.textPrimary)
                } else {
                    Image(systemName: "terminal.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .themedForeground(.textSecondary)
                }
            }
    }
}

// MARK: - phi-browser skill installer

private struct SkillInstallRowView: View {
    // A coding agent that loads skills from a folder.
    // "Install" links this app's bundled phi-browser skill into
    // <skillsDirectory>/phi-browser so the agent can drive Phi over CDP.
    private struct SkillTarget: Identifiable {
        let id: String
        let name: String
        /// Bundled brand icon (imageset under Assets ▸ agents), or nil for an
        /// agent without artwork yet (shown with a generic terminal glyph).
        /// Rendering follows the asset's own intent: the monochrome brand
        /// glyphs are template, Hermes's favicon artwork renders in color.
        let iconAsset: String?
        let skillsDirectory: URL
        /// Pi alone exposes a supported in-process message API. Its companion
        /// extension wakes idle sessions when Agent Transcript receives input.
        let companionExtensionDirectory: URL?

        init(id: String, name: String, iconAsset: String?, skillsDirectory: URL,
             companionExtensionDirectory: URL? = nil) {
            self.id = id
            self.name = name
            self.iconAsset = iconAsset
            self.skillsDirectory = skillsDirectory
            self.companionExtensionDirectory = companionExtensionDirectory
        }

        var linkURL: URL {
            skillsDirectory.appendingPathComponent("phi-browser", isDirectory: true)
        }

        var companionExtensionLinkURL: URL? {
            companionExtensionDirectory?
                .appendingPathComponent("phi-browser", isDirectory: true)
        }
    }

    /// Every agent the skill can be linked into. The first six are also the
    /// agents whose driving session the skill mirrors into Agent Transcript
    /// (see `scripts/lib/mirror-*.mjs`); the agents after Pi only DRIVE Phi.
    /// Under them the transcript shows the browser steps and `say()` prose
    /// but never the agent's own conversation — the skill's session
    /// discovery is gated on positive evidence of a known host, so adding an
    /// agent here never enrolls it in the mirror. Paths follow each agent's
    /// documented user-level skills folder (agentskills.io convention).
    private static let skillTargets: [SkillTarget] = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            SkillTarget(id: "claude", name: "Claude Code", iconAsset: "agent-claude",
                        skillsDirectory: home.appendingPathComponent(".claude/skills", isDirectory: true)),
            SkillTarget(id: "codex", name: "Codex", iconAsset: "agent-openai",
                        skillsDirectory: home.appendingPathComponent(".codex/skills", isDirectory: true)),
            SkillTarget(id: "cursor", name: "Cursor", iconAsset: "agent-cursor",
                        skillsDirectory: home.appendingPathComponent(".cursor/skills", isDirectory: true)),
            SkillTarget(id: "hermes", name: "Hermes", iconAsset: "agent-hermes",
                        skillsDirectory: home.appendingPathComponent(".hermes/skills", isDirectory: true)),
            SkillTarget(id: "openclaw", name: "OpenClaw", iconAsset: "agent-openclaw",
                        skillsDirectory: home.appendingPathComponent(".openclaw/skills", isDirectory: true)),
            SkillTarget(
                id: "pi", name: "Pi", iconAsset: "agent-pi",
                skillsDirectory: home.appendingPathComponent(".pi/agent/skills", isDirectory: true),
                companionExtensionDirectory: home.appendingPathComponent(
                    ".pi/agent/extensions", isDirectory: true)),
            // Skill-only agents: no session mirror, no companion extension.
            SkillTarget(id: "grok", name: "Grok Build", iconAsset: nil,
                        skillsDirectory: home.appendingPathComponent(".grok/skills", isDirectory: true)),
            // Deep Code (DeepSeek's CLI) reads the cross-agent ~/.agents/skills
            // folder, which Kimi Code, Cline, and DeepSeek Harness share.
            SkillTarget(id: "deepcode", name: "Deep Code", iconAsset: nil,
                        skillsDirectory: home.appendingPathComponent(".agents/skills", isDirectory: true)),
            SkillTarget(id: "gemini", name: "Gemini CLI", iconAsset: nil,
                        skillsDirectory: home.appendingPathComponent(".gemini/skills", isDirectory: true)),
            SkillTarget(id: "copilot", name: "GitHub Copilot", iconAsset: nil,
                        skillsDirectory: home.appendingPathComponent(".copilot/skills", isDirectory: true)),
            SkillTarget(id: "opencode", name: "OpenCode", iconAsset: nil,
                        skillsDirectory: home.appendingPathComponent(".config/opencode/skills", isDirectory: true)),
            SkillTarget(id: "qwen", name: "Qwen Code", iconAsset: nil,
                        skillsDirectory: home.appendingPathComponent(".qwen/skills", isDirectory: true)),
            SkillTarget(id: "codebuddy", name: "CodeBuddy", iconAsset: nil,
                        skillsDirectory: home.appendingPathComponent(".codebuddy/skills", isDirectory: true)),
        ]
    }()

    // The skill tree is bundled at Contents/Resources/phi-browser-skill.
    private static var bundledSkillURL: URL? {
        Bundle.main.resourceURL?
            .appendingPathComponent("phi-browser-skill", isDirectory: true)
    }

    private static var bundledPiExtensionURL: URL? {
        bundledSkillURL?
            .appendingPathComponent("extensions/pi", isDirectory: true)
    }

    // IDs of agents whose skills folder already links to *this* app's bundle.
    @State private var installedTargets: Set<String> = SkillInstallRowView.installedTargetIDs()

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            SettingsIconChip(systemName: "puzzlepiece.extension.fill", color: .teal)
            VStack(alignment: .leading, spacing: 4) {
                Text(NSLocalizedString("settings.developer.skillInstall.sectionTitle", value: "Install the phi-browser skill", comment: "Developer settings - Title for installing the phi-browser agent skill"))
                    .font(.system(size: 13))
                    .themedForeground(.textPrimary)
                Text(NSLocalizedString("settings.developer.skillInstall.description", value: "Links the skill bundled in this app into an AI coding agent’s skills folder so it can drive Phi over the DevTools Protocol. Pi also gets a companion extension that wakes idle sessions from Agent Transcript commands. Requires Node 22+.", comment: "Developer settings - Explanation for the phi-browser skill installer"))
                    .font(.system(size: 11))
                    .themedForeground(.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Menu {
                Button(NSLocalizedString("settings.developer.skillInstall.allAgentsAction", value: "All agents", comment: "Developer settings - Menu item installing the skill for every agent")) {
                    installAll()
                }
                Divider()
                ForEach(Self.skillTargets) { target in
                    Button {
                        installSkill(for: target)
                    } label: {
                        // The agent's brand icon leads each row; a
                        // trailing ✓ marks agents whose skills folder
                        // already links to THIS app's bundle (picking
                        // one again reinstalls / refreshes the link).
                        Label {
                            Text("\(target.name)  \(Self.displayPath(target.skillsDirectory))"
                                 + (installedTargets.contains(target.id) ? "  ✓" : ""))
                        } icon: {
                            if let asset = target.iconAsset {
                                Image(asset)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 15, height: 15)
                            } else {
                                Image(systemName: "terminal.fill")
                                    .font(.system(size: 12, weight: .semibold))
                                    .frame(width: 15, height: 15)
                            }
                        }
                    }
                }
            } label: {
                Text(NSLocalizedString("settings.developer.skillInstall.targetMenuButton", value: "Add skill to…", comment: "Developer settings - Dropdown button installing the phi-browser skill for an agent"))
            }
            .controlSize(.small)
            .fixedSize()
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Installs for every known agent, reporting one aggregate alert instead
    /// of one per target.
    private func installAll() {
        var succeeded: [String] = []
        var failed: [(String, String)] = []
        for target in Self.skillTargets {
            switch performInstall(for: target) {
            case .success: succeeded.append(target.name)
            case .cancelled: continue
            case .failure(let message): failed.append((target.name, message))
            }
        }
        if failed.isEmpty, succeeded.isEmpty { return }
        if failed.isEmpty {
            presentSkillAlert(
                title: NSLocalizedString("settings.developer.skillInstall.all.successTitle", value: "Skill installed", comment: "Developer settings - Skill install success title"),
                body: String(
                    format: NSLocalizedString("settings.developer.skillInstall.all.successMessage", value: "%@ can now use the phi-browser skill. Restart newly configured agents; in Pi, /reload is enough.", comment: "Developer settings - Skill install success body; %@ is the agent name"),
                    succeeded.joined(separator: ", ")))
        } else {
            presentSkillAlert(
                title: NSLocalizedString("settings.developer.skillInstall.all.failureTitle", value: "Couldn’t install the skill", comment: "Developer settings - Skill install error title"),
                body: failed.map { "\($0.0): \($0.1)" }.joined(separator: "\n"))
        }
    }

    private static func displayPath(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = url.path
        guard path.hasPrefix(home) else { return path }
        return "~" + String(path.dropFirst(home.count))
    }

    static func installedTargetIDs() -> Set<String> {
        guard let bundled = bundledSkillURL else { return [] }
        return Set(skillTargets.filter { target in
            guard isLinked(target.linkURL, to: bundled) else { return false }
            guard let companionLink = target.companionExtensionLinkURL else { return true }
            guard let companion = bundledPiExtensionURL else { return false }
            return isLinked(companionLink, to: companion)
        }.map(\.id))
    }

    // True only when linkURL is a symlink resolving to *this* app's bundled
    // skill, so a link left by another build (or a stale target) reads as
    // "Install" rather than already-installed.
    private static func isLinked(_ link: URL, to bundled: URL) -> Bool {
        guard let dest = try? FileManager.default
            .destinationOfSymbolicLink(atPath: link.path) else { return false }
        let resolved = dest.hasPrefix("/")
            ? dest
            : link.deletingLastPathComponent().appendingPathComponent(dest).path
        return URL(fileURLWithPath: resolved).standardizedFileURL.path
            == bundled.standardizedFileURL.path
    }

    private enum InstallOutcome {
        case success
        case cancelled          // the user declined the overwrite prompt
        case failure(String)
    }

    /// Links the bundled skill into `target`'s skills folder. Silent apart
    /// from the overwrite confirmation (a non-symlink already in place must
    /// never be clobbered without asking) — callers present the outcome, so
    /// "All agents" can aggregate into one alert.
    private func performInstall(for target: SkillTarget) -> InstallOutcome {
        let fm = FileManager.default
        guard let bundled = Self.bundledSkillURL,
              fm.fileExists(atPath: bundled.path) else {
            return .failure(NSLocalizedString("settings.developer.skillInstall.missingResourcesError", value: "This build doesn’t include the phi-browser skill resources. Rebuild Phi Browser and try again.", comment: "Developer settings - Skill install failure body when the resource is missing"))
        }

        var installs: [(link: URL, source: URL)] = [(target.linkURL, bundled)]
        if let companionLink = target.companionExtensionLinkURL {
            guard let companion = Self.bundledPiExtensionURL,
                  fm.fileExists(atPath: companion.path) else {
                return .failure(NSLocalizedString("settings.developer.skillInstall.missingCompanionError", value: "This build doesn’t include the Pi companion extension. Rebuild Phi Browser and try again.",
                    comment: "Developer settings - Pi companion extension missing"))
            }
            installs.append((companionLink, companion))
        }

        do {
            // Ask about every real destination before changing any of them, so
            // declining the Pi extension replacement cannot leave a partial install.
            for install in installs {
                try fm.createDirectory(
                    at: install.link.deletingLastPathComponent(),
                    withIntermediateDirectories: true)
                let isSymlink = (try? fm.destinationOfSymbolicLink(
                    atPath: install.link.path)) != nil
                if !isSymlink, fm.fileExists(atPath: install.link.path),
                   !confirmSkillOverwrite(at: install.link.path) {
                    return .cancelled
                }
            }

            for install in installs {
                if (try? fm.destinationOfSymbolicLink(atPath: install.link.path)) != nil
                    || fm.fileExists(atPath: install.link.path) {
                    try fm.removeItem(at: install.link)
                }
                try fm.createSymbolicLink(
                    at: install.link, withDestinationURL: install.source)
            }
            installedTargets.insert(target.id)
            return .success
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    private func installSkill(for target: SkillTarget) {
        switch performInstall(for: target) {
        case .success:
            presentSkillAlert(
                title: NSLocalizedString("settings.developer.skillInstall.single.successTitle", value: "Skill installed", comment: "Developer settings - Skill install success title"),
                body: String(
                    format: NSLocalizedString("settings.developer.skillInstall.single.successMessage", value: "%@ can now use the phi-browser skill. Restart newly configured agents; in Pi, /reload is enough.", comment: "Developer settings - Skill install success body; %@ is the agent name"),
                    target.name))
        case .cancelled:
            break
        case .failure(let message):
            presentSkillAlert(
                title: NSLocalizedString("settings.developer.skillInstall.single.failureTitle", value: "Couldn’t install the skill", comment: "Developer settings - Skill install error title"),
                body: message)
        }
    }

    private func confirmSkillOverwrite(at path: String) -> Bool {
        let response = NSApp.runPhiAlert(PhiAlertAppKitConfiguration(
            title: NSLocalizedString("settings.developer.skillInstall.overwriteConfirmation.title", value: "Replace the existing skill?", comment: "Developer settings - Skill overwrite prompt title"),
            message: String(
                format: NSLocalizedString("settings.developer.skillInstall.overwriteConfirmation.message", value: "“%@” already exists and isn’t a link created by Phi Browser. Replace it with a link to this app’s bundled skill?", comment: "Developer settings - Skill overwrite prompt body"),
                path),
            secondaryAction: PhiAlertAppKitAction(
                NSLocalizedString("settings.developer.skillInstall.overwriteConfirmation.cancelButton", value: "Cancel", comment: "Developer settings - Skill overwrite cancel button"),
                response: .alertSecondButtonReturn),
            primaryAction: PhiAlertAppKitAction(
                NSLocalizedString("settings.developer.skillInstall.overwriteConfirmation.replaceButton", value: "Replace", comment: "Developer settings - Skill overwrite confirm button"),
                role: .primary,
                response: .alertFirstButtonReturn)))
        return response == .alertFirstButtonReturn
    }

    private func presentSkillAlert(title: String, body: String) {
        _ = NSApp.runPhiAlert(PhiAlertAppKitConfiguration(
            title: title,
            message: body,
            icon: .phiAlertIcon,
            primaryAction: PhiAlertAppKitAction(
                NSLocalizedString("settings.developer.skillInstall.result.dismissButton", value: "OK", comment: "Developer settings - Alert dismiss button"),
                role: .primary,
                response: .alertFirstButtonReturn)))
    }
}

