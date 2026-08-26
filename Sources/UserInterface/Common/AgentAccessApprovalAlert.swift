// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import SwiftUI

/// How long a refusal should stand, as picked in the agent access alert.
///
/// Only refusals are scoped in *time*. Widening either answer to every agent is
/// the alert's one shared switch instead, so the asymmetry that remains is a
/// deliberate one: a widened refusal only ever turns agents away, while a
/// widened grant hands the browser to any same-user process without a prompt,
/// which is why the latter gets no timed middle ground and a warning of its own.
enum AgentAccessDenyScope: CaseIterable {
    /// Refuse this connection; the next one asks again.
    case thisTime
    case thirtyMinutes
    case forever

    var segmentTitle: String {
        switch self {
        case .thisTime:
            return NSLocalizedString("agentControl.connectionApproval.denyScope.thisTime", value: "Just this time", comment: "CDP consent - deny scope segment: refuse this connection only")
        case .thirtyMinutes:
            return NSLocalizedString("agentControl.connectionApproval.denyScope.thirtyMinutes", value: "For 30 min", comment: "CDP consent - deny scope segment: refuse without asking again for thirty minutes")
        case .forever:
            return NSLocalizedString("agentControl.connectionApproval.denyScope.forever", value: "Never ask again", comment: "CDP consent - deny scope segment: refuse permanently")
        }
    }

    /// When a refusal of this scope lapses — nil for a permanent one. A
    /// `.thisTime` refusal records nothing at all, so it has no deadline.
    var expiry: Date? {
        switch self {
        case .thisTime, .forever: return nil
        case .thirtyMinutes: return Date().addingTimeInterval(30 * 60)
        }
    }

    /// Whether choosing this scope records anything the user can later review.
    var isRemembered: Bool { self != .thisTime }
}

/// Outcome of the agent access alert, handed back to `AgentCDPListener`.
enum AgentAccessChoice: Equatable {
    /// Let the connection through. `remembered` is the difference between
    /// "Allow Once" (this app session) and "Always Allow" (persisted);
    /// `allAgents` widens the grant from the asking agent to every agent.
    case allow(remembered: Bool, allAgents: Bool)
    case deny(scope: AgentAccessDenyScope, allAgents: Bool)
}

/// The alert's answer: what the user chose, and who they chose it about.
///
/// `subject` is normally the agent that asked. It differs when the user picks
/// a process further up the launch chain in the Details disclosure — the move
/// that exists because the agent Phi resolves is sometimes an unsigned script
/// nobody recognises while the signed app that launched it (an editor, a
/// terminal) is exactly what the user wants to decide about, once, for
/// everything it runs.
struct AgentAccessDecision: Equatable {
    let choice: AgentAccessChoice
    let subject: AgentIdentity

    /// Whether the answer was retargeted away from the agent that asked.
    func isRetargeted(from asking: AgentIdentity) -> Bool { subject.key != asking.key }
}

/// The agent browser-control consent dialog (`PhiAlert` styling), replacing the
/// old three-button `NSAlert`. The alert raised when an agent reaches Phi's
/// socket: it names the connecting process, states plainly what CDP access
/// lets it do, and — because the socket answers whether or not the feature is
/// switched on — says so when allowing would also turn it on.
///
/// Deny carries the time-scope picker rather than the allow side: a user who is
/// being asked by something they don't recognise wants to stop being asked,
/// and sending them to Settings to arrange that is the failure this replaces.
/// That picker is a second step, revealed by pressing Deny, so the first screen
/// asks one question — allow this agent or not — and how long a refusal stands
/// is only put to a user who has already refused.
///
/// "Apply to all agents" is one switch across both steps, not one per answer:
/// it scopes *who* the decision covers, which is the same question whichever
/// button is pressed, and a copy under each would ask it twice and leave the
/// user to notice they mean different things.
///
/// ## Why almost nothing here appears with `if`
///
/// The alert's window tracks the SwiftUI content's ideal height, so a row that
/// comes and goes resizes the window under the user. Animate that resize — and
/// the alert used to, on both the step change and the warning reveal — and
/// AppKit's resize fights SwiftUI's layout animation frame by frame, which is
/// the shake this file's `reservingSpace` modifier exists to remove. Anything
/// driven by the alert's own `@State` is therefore laid out from the start and
/// faded, never inserted, so the alert holds the height it opened at.
///
/// Branching on the alert's *inputs* is free — `agentIsUnsigned` and
/// `opensGates` are settled before it appears and never change while it is up.
/// Which is why the unsigned banner is keyed to the agent and not to the
/// subject: the subject moves, and a banner appearing under it would resize
/// the alert mid-answer.
///
/// The one live exception is `showsDetails`: that disclosure is *asking* for
/// more room, so it resizes the window once, unanimated, which reads as a panel
/// opening rather than as the alert twitching.
struct AgentAccessApprovalAlert: View {
    /// The agent that is asking, and the answer's subject unless the user
    /// picks another process in Details.
    let agent: AgentIdentity
    /// True when allowing also switches Developer mode and agent CDP access on.
    let opensGates: Bool
    /// Command line and launch chain behind the agent, shown under "Details".
    /// Nil when nothing could be read, which hides the disclosure entirely.
    let processDetails: AgentProcessDetails?
    let onChoice: (AgentAccessDecision) -> Void

    @State private var denyScope = AgentAccessDenyScope.thisTime
    @State private var allAgents = false
    /// Second step: the user pressed Deny and is now picking how long it holds.
    @State private var isChoosingDenyScope = false
    @State private var showsDetails = false
    /// Which row of the launch chain the answer is about, by pid — nil for the
    /// agent itself. A pid rather than an identity key because the user picks
    /// a *row*, and two rows can share a key: an app and its own helper
    /// process carry one signature between them, and keying the selection
    /// would light both of them up.
    @State private var subjectPid: pid_t?
    @State private var hasChosen = false

    @Environment(\.phiAppearance) private var appearance
    @Environment(\.phiTheme) private var theme

    private var agentName: String { agent.displayName }

    /// The process that reached the socket carries no valid code signature —
    /// the one fact on this alert that changes how much the rest of it can be
    /// trusted, so it is called out in red rather than left as a word in a
    /// summary row.
    ///
    /// Read off the *agent*, never the subject, and deliberately: it decides
    /// whether a whole banner is laid out, and retargeting must not resize the
    /// alert (see the type's note). It is also simply the truer statement —
    /// answering about the signed terminal above an unsigned script does not
    /// make the script signed, and the warning is about what is connecting.
    private var agentIsUnsigned: Bool { !agent.verified }

    /// Who the answer will be recorded about. The tree is the source of truth
    /// for it, so a pid that no longer names a row falls back to the agent
    /// rather than answering about nothing.
    private var subject: AgentIdentity {
        guard let subjectPid else { return agent }
        return processDetails?.tree.first { $0.pid == subjectPid }?.identity ?? agent
    }

    /// Compared by key, not by pid: picking a row that turns out to carry the
    /// agent's own signature has retargeted nothing, and should not be
    /// announced as though it had.
    private var isRetargeted: Bool { subject.key != agent.key }

    private func isSubjectRow(_ node: AgentProcessNode) -> Bool {
        guard let subjectPid else { return node.isAgent }
        return node.pid == subjectPid
    }

    /// A themed role resolved to a concrete color, for the few places that
    /// choose between a themed default and a literal warning red — a ternary
    /// cannot pick between the `themedForeground` and `foregroundStyle`
    /// modifiers, only between the colors they end up applying.
    private func themed(_ role: ThemedColor) -> Color {
        role.swiftUIColor(theme: theme, appearance: appearance)
    }

    var body: some View {
        PhiAlert(title: title) {
            Image(systemName: "sparkles")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(appearance.isLight ? Color.black : Color.white)
        } content: {
            VStack(alignment: .leading, spacing: 14) {
                summaryCard
                stepContent
                allAgentsSection
            }
        } actions: {
            if isChoosingDenyScope {
                denyScopeActions
            } else {
                decisionActions
            }
        }
    }

    /// The two steps share one frame: the banners answer "should I allow
    /// this?", which the second step has already settled, so the scope
    /// question takes their place. Both are laid out at all times and the
    /// inactive one is faded out, so pressing Deny and Back crosses between
    /// them without moving the window a pixel.
    ///
    /// The frame is as tall as the taller step, which is the banners — by a
    /// hair for the agent this alert usually asks about, and by a good deal
    /// when the unsigned and switches-it-on banners are both up. The scope
    /// question is centered in it rather than pinned to the top, so on those
    /// occasions the second step reads as one question on a roomy step instead
    /// of a short one with the bottom fallen out.
    private var stepContent: some View {
        ZStack(alignment: .leading) {
            decisionBanners
                .frame(maxWidth: .infinity, alignment: .leading)
                .reservingSpace(shown: !isChoosingDenyScope)
            denySection
                .frame(maxWidth: .infinity, alignment: .leading)
                .reservingSpace(shown: isChoosingDenyScope)
        }
        .animation(.easeOut(duration: 0.15), value: isChoosingDenyScope)
    }

    private var decisionBanners: some View {
        VStack(alignment: .leading, spacing: 14) {
            controlBanner
            if agentIsUnsigned {
                unsignedBanner
            }
            if opensGates {
                enablesFeatureNote
            }
        }
    }

    /// First step: allow this agent, or move on to scoping a refusal.
    private var decisionActions: some View {
        PhiAlertActions {
            PhiAlertButton(
                NSLocalizedString("agentControl.connectionApproval.denyButton", value: "Deny", comment: "CDP consent - deny")
            ) {
                isChoosingDenyScope = true
            }
            .keyboardShortcut(.cancelAction)
        } secondaryAction: {
            PhiAlertButton(
                NSLocalizedString("agentControl.connectionApproval.allowOnceButton", value: "Allow Once", comment: "CDP consent - allow for this session")
            ) {
                choose(.allow(remembered: false, allAgents: allAgents))
            }
        } primaryAction: {
            PhiAlertButton(
                NSLocalizedString("agentControl.connectionApproval.alwaysAllowButton", value: "Always Allow", comment: "CDP consent - allow and remember"),
                role: .primary
            ) {
                choose(.allow(remembered: true, allAgents: allAgents))
            }
            .keyboardShortcut(.defaultAction)
        }
    }

    /// Second step. Back deliberately takes no `.cancelAction`: Escape already
    /// reaches here from the first step, and binding it to Back as well would
    /// leave Escape flipping between the two steps with no way out. Escape then
    /// Return is the whole keyboard path to "deny, just this time".
    private var denyScopeActions: some View {
        PhiAlertActions {
            PhiAlertButton(
                NSLocalizedString("agentControl.connectionApproval.backButton", value: "Back", comment: "CDP consent - return from the deny scope step to the allow-or-deny decision")
            ) {
                isChoosingDenyScope = false
            }
        } primaryAction: {
            PhiAlertButton(
                NSLocalizedString("agentControl.connectionApproval.denyButton", value: "Deny", comment: "CDP consent - deny"),
                role: .primary
            ) {
                // A "Just this time" refusal records nothing, so there is
                // nothing for the switch to widen.
                choose(.deny(scope: denyScope, allAgents: allAgents && denyScope.isRemembered))
            }
            .keyboardShortcut(.defaultAction)
        }
    }

    private func choose(_ choice: AgentAccessChoice) {
        guard !hasChosen else { return }
        hasChosen = true
        onChoice(AgentAccessDecision(choice: choice, subject: subject))
    }

    private var title: String {
        String(
            format: NSLocalizedString("agentControl.connectionApproval.title", value: "“%@” wants to control Phi Browser",
                                      comment: "CDP consent - title"),
            agentName)
    }

    // MARK: - Summary card

    /// Wide enough for the longest label the card can show, which is the
    /// "Answer for" a retargeted row swaps in — the values stay aligned across
    /// every row and every state rather than stepping sideways when it does.
    private static let labelColumnWidth: CGFloat = 66

    /// Describes the SUBJECT, not the asking agent — the two are the same
    /// until the user retargets the answer in Details, and after that the card
    /// has to follow, because it is the readout for what the buttons below it
    /// will do. Who asked is still on screen twice: in the title, and as the
    /// row tagged "this agent" in the chain.
    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            summaryRow(
                label: subjectRowLabel,
                value: subject.displayName,
                labelColor: isRetargeted ? Color(nsColor: .systemOrange) : nil
            ) {
                CredentialAgentIcon(agentName: subject.displayName, size: 12, weight: .medium)
                    .themedForeground(.textSecondary)
            }
            Divider()
                .padding(.leading, 12)
            identityRow
            if processDetails != nil {
                Divider()
                    .padding(.leading, 12)
                detailsDisclosureRow
                detailsPanel
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(appearance.isLight ? Color.black.opacity(0.045) : Color.white.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(identityBorderColor)
        )
    }

    /// An unsigned subject's card is outlined in the same red as its identity
    /// row: the row alone sits mid-card and is easy to read past, and this is
    /// the state where the user is being asked to trust a name nothing stands
    /// behind. A verified one keeps the neutral outline — its identity row is
    /// green, and outlining the card as well would dress an ordinary state up
    /// as an event.
    ///
    /// Unlike the unsigned *banner*, this follows the subject: it is a color,
    /// so it can change under a retarget without moving anything.
    private var identityBorderColor: Color {
        if !subject.verified {
            return Color(nsColor: .systemRed).opacity(appearance.isLight ? 0.35 : 0.45)
        }
        return appearance.isLight ? Color.black.opacity(0.06) : Color.white.opacity(0.08)
    }

    /// "Agent" until the answer is retargeted, and then what the row has
    /// actually become — leaving it reading "Agent" over the name of a
    /// terminal would be the one piece of this alert that lies.
    private var subjectRowLabel: String {
        isRetargeted
            ? NSLocalizedString("agentControl.connectionApproval.subjectLabel", value: "Answer for", comment: "CDP consent - label of the top summary row once the answer has been retargeted onto a process that launched the agent, replacing the \"Agent\" label")
            : NSLocalizedString("agentControl.connectionApproval.agentLabel", value: "Agent", comment: "CDP consent - agent row label")
    }

    private var identityRow: some View {
        summaryRow(
            label: NSLocalizedString("agentControl.connectionApproval.identityLabel", value: "Identity", comment: "CDP consent - code signing identity row label"),
            value: subject.detail,
            valueColor: Self.trustColor(verified: subject.verified)
        ) {
            Image(systemName: Self.trustSymbol(verified: subject.verified))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Self.trustColor(verified: subject.verified))
        }
    }

    /// The two answers the Identity row can give, in the two colors the answer
    /// carries everywhere else: green for a signature Phi checked and trusts,
    /// red for none. Shared with the launch-chain rows, so a parent process
    /// reads at a glance the same way the agent does — and so a chain with one
    /// red link in it is impossible to miss.
    static func trustColor(verified: Bool) -> Color {
        verified ? Color(nsColor: .systemGreen) : Color(nsColor: .systemRed)
    }

    static func trustSymbol(verified: Bool) -> String {
        verified ? "checkmark.seal.fill" : "exclamationmark.triangle.fill"
    }

    private func summaryRow(label: String, value: String,
                            labelColor: Color? = nil,
                            valueColor: Color? = nil,
                            @ViewBuilder icon: () -> some View) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            icon()
                .frame(width: 16)
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(labelColor ?? themed(.textSecondary))
                .lineLimit(1)
                .frame(width: Self.labelColumnWidth, alignment: .leading)
            Text(value)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(valueColor ?? themed(.textPrimary))
                // One line, always: these rows follow the subject, and a name
                // long enough to wrap would resize the alert the moment a row
                // in the chain is picked (see the type's note). Middle
                // truncation keeps both ends of a long reverse-DNS id, which
                // is where its meaning lives.
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    // MARK: - Details disclosure

    /// The one control on the alert that grows the window, and the only place
    /// the agent's own words appear: everything above is Phi's account of who
    /// is asking, this is the command line it was read from and the chain of
    /// processes it came down. It carries the most weight for an unsigned
    /// agent, whose name comes from a script path or a self-chosen `argv[0]`
    /// and can be anything at all.
    ///
    /// Its summary doubles as the readout for a retargeted answer, because the
    /// only way to retarget one is from inside this panel — and a user who
    /// picks a row and then collapses it must not be left with an alert whose
    /// buttons quietly mean something else.
    private var detailsDisclosureRow: some View {
        Button {
            showsDetails.toggle()
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "info.circle")
                    .font(.system(size: 12, weight: .medium))
                    .themedForeground(.textSecondary)
                    .frame(width: 16)
                Text(NSLocalizedString("agentControl.connectionApproval.details.label", value: "Details", comment: "CDP consent - label of the row that expands the agent's command and process tree"))
                    .font(.system(size: 12))
                    .themedForeground(.textSecondary)
                    .lineLimit(1)
                    .frame(width: Self.labelColumnWidth, alignment: .leading)
                Text(detailsSummary)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isRetargeted
                        ? Color(nsColor: .systemOrange)
                        : themed(.textPrimary))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .themedForeground(.textTertiary)
                    .rotationEffect(.degrees(showsDetails ? 0 : -90))
                    .animation(.easeOut(duration: 0.15), value: showsDetails)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Without this the alert opens wearing a focus ring around this row:
        // it is the first focusable control in the content, so SwiftUI hands
        // it the initial focus, and a blue rectangle around "Details" reads as
        // an alarm about the thing the user has not even opened yet. The
        // alert's own buttons keep their rings.
        .focusEffectDisabled()
        .accessibilityLabel(showsDetails
            ? NSLocalizedString("agentControl.connectionApproval.details.hideAccessibilityLabel", value: "Hide the agent's command and process tree", comment: "CDP consent - accessibility label of the details disclosure button while the details are open")
            : NSLocalizedString("agentControl.connectionApproval.details.showAccessibilityLabel", value: "Show the agent's command and process tree", comment: "CDP consent - accessibility label of the details disclosure button while the details are closed"))
    }

    private var detailsSummary: String {
        guard isRetargeted else {
            return NSLocalizedString("agentControl.connectionApproval.details.summary", value: "Command and process tree", comment: "CDP consent - value of the details row, naming what the disclosure reveals")
        }
        return String(
            format: NSLocalizedString("agentControl.connectionApproval.details.answeringFor", value: "Answering for “%@”",
                                      comment: "CDP consent - value of the details row once the user has retargeted the answer onto a process that launched the agent; %@ is that process's name"),
            subject.displayName)
    }

    @ViewBuilder
    private var detailsPanel: some View {
        if showsDetails, let processDetails {
            Divider()
                .padding(.leading, 12)
            VStack(alignment: .leading, spacing: 10) {
                detailsField(
                    title: NSLocalizedString("agentControl.connectionApproval.details.commandHeading", value: "Command", comment: "CDP consent - heading over the agent's command line in the details disclosure")
                ) {
                    Text(processDetails.command)
                        .font(.system(size: 11, design: .monospaced))
                        .themedForeground(.textPrimary)
                        .lineLimit(6)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if !processDetails.tree.isEmpty {
                    detailsField(
                        title: NSLocalizedString("agentControl.connectionApproval.details.treeHeading", value: "Launched by", comment: "CDP consent - heading over the process ancestry in the details disclosure")
                    ) {
                        processTree(processDetails.tree)
                    }
                    subjectNote
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
    }

    private func detailsField(title: String,
                              @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .themedForeground(.textTertiary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Oldest ancestor at the top, the agent at the bottom, indented one step
    /// per generation — the chain read the way it happened. Each row carries
    /// its pid, which is what makes it checkable against `ps` while the prompt
    /// is still up; its signing identity, so a parent answers the same
    /// question the card above asks about the agent; and its full command in a
    /// tooltip, since a command long enough to matter is always too long for
    /// this width.
    ///
    /// Rows are also the control that retargets the answer. That is deliberate
    /// rather than a separate picker: the reason to answer about a parent is
    /// something you can only see here — that the agent is an unsigned script
    /// and the process above it is a signed application you recognise.
    private func processTree(_ nodes: [AgentProcessNode]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(nodes.enumerated()), id: \.element.id) { index, node in
                treeRow(node, depth: index)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func treeRow(_ node: AgentProcessNode, depth: Int) -> some View {
        let isSubject = isSubjectRow(node)
        let row = treeRowLabel(node, depth: depth, isSubject: isSubject)
        if node.isSelectableSubject {
            Button {
                // Selecting the agent's own row clears the retarget rather
                // than recording its pid, so "the answer is about the agent"
                // has one representation and not two.
                subjectPid = node.isAgent ? nil : node.pid
            } label: {
                row
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .accessibilityAddTraits(isSubject ? [.isButton, .isSelected] : .isButton)
        } else {
            row
        }
    }

    private func treeRowLabel(_ node: AgentProcessNode, depth: Int,
                              isSubject: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: isSubject ? "largecircle.fill.circle" : "circle")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(isSubject ? themed(.themeColor) : themed(.textTertiary))
                .opacity(node.isSelectableSubject ? 1 : 0)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(node.name)
                        .font(.system(size: 11, weight: node.isAgent ? .semibold : .regular,
                                      design: .monospaced))
                        .themedForeground(.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(verbatim: "(\(node.pid))")
                        .font(.system(size: 10, design: .monospaced))
                        .themedForeground(.textTertiary)
                    if node.isAgent {
                        tag(NSLocalizedString("agentControl.connectionApproval.details.thisAgentTag", value: "this agent", comment: "CDP consent - tag marking which row of the process tree is the agent asking for access"),
                            color: Self.trustColor(verified: node.identity?.verified ?? false))
                    }
                }
                if let identity = node.identity {
                    Text(identity.detail)
                        .font(.system(size: 10))
                        .foregroundStyle(Self.trustColor(verified: identity.verified))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, CGFloat(depth) * 10)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .help(node.command)
    }

    private func tag(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.14)))
    }

    /// What picking a row does, stated before it is picked and again after.
    /// Both readings are laid out at once so that choosing a row cannot resize
    /// the alert (see the type's note) — and because the second is a warning,
    /// which is worth exactly as much space as the invitation that preceded it.
    private var subjectNote: some View {
        ZStack(alignment: .topLeading) {
            Text(String(
                format: NSLocalizedString("agentControl.connectionApproval.details.subjectHint", value: "Your answer is about “%@”. Pick a row above to answer about the process that launched it instead.",
                                          comment: "CDP consent - hint under the process tree explaining that a row can be picked to retarget the answer; %@ is the asking agent's name"),
                agentName))
                .themedForeground(.textTertiary)
                .reservingSpace(shown: !isRetargeted)
            Text(String(
                format: NSLocalizedString("agentControl.connectionApproval.details.subjectWarning", value: "Your answer covers “%@” — every agent it launches gets the same answer, without asking again.",
                                          comment: "CDP consent - warning under the process tree once the answer has been retargeted onto a process that launched the agent; %@ is that process's name"),
                subject.displayName))
                .foregroundStyle(Color(nsColor: .systemOrange))
                .reservingSpace(shown: isRetargeted)
        }
        .font(.system(size: 11))
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeOut(duration: 0.15), value: isRetargeted)
    }

    // MARK: - Banners

    private var controlBanner: some View {
        banner(
            symbol: "hand.raised.fill",
            color: Color(nsColor: .systemOrange),
            headline: NSLocalizedString("agentControl.connectionApproval.control.headline", value: "Full control of this browser",
                                        comment: "CDP consent - headline naming what agent access grants"),
            detail: NSLocalizedString("agentControl.connectionApproval.message", value: "An agent is asking to drive Phi Browser over the DevTools Protocol — opening pages, reading content, and acting on your behalf. Only allow agents you trust.",
                                      comment: "CDP consent - body"))
    }

    /// Shown only for a peer with no valid signature. What the user loses is
    /// specific — not the agent's honesty but Phi's ability to tell one binary
    /// from another — so the banner says which check failed and points at the
    /// disclosure that can still answer the question.
    private var unsignedBanner: some View {
        banner(
            symbol: "exclamationmark.triangle.fill",
            color: Color(nsColor: .systemRed),
            headline: NSLocalizedString("agentControl.connectionApproval.unsigned.headline", value: "Unsigned — Phi can't verify this agent",
                                        comment: "CDP consent - headline of the banner shown when the asking process has no valid code signature"),
            detail: NSLocalizedString("agentControl.connectionApproval.unsigned.detail", value: "This process carries no valid code signature, so its name comes from the command it was launched with and anything could claim it. Open Details to see that command before you allow it.",
                                      comment: "CDP consent - body of the unsigned-agent warning banner"))
    }

    private var enablesFeatureNote: some View {
        banner(
            symbol: "switch.2",
            color: Color(nsColor: .systemBlue),
            headline: NSLocalizedString("agentControl.connectionApproval.enablesFeature.headline", value: "Agent control is currently off",
                                        comment: "CDP consent - headline shown when allowing will also enable the feature"),
            detail: NSLocalizedString("agentControl.connectionApproval.enablesFeatureNote", value: "Allowing also turns on Developer mode and “Allow agents to control Phi (CDP)” in Settings; you can switch them back off there at any time.",
                                      comment: "CDP consent - body of the banner shown when allowing will also enable the developer mode and agent control settings"))
    }

    private func banner(symbol: String, color: Color,
                        headline: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 20)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(headline)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(color)
                Text(detail)
                    .font(.system(size: 12))
                    .themedForeground(.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(color.opacity(appearance.isLight ? 0.09 : 0.15))
        )
    }

    // MARK: - All-agents scope

    /// Widens whichever button is pressed from the asking agent to every agent,
    /// so it stands across both steps. On the first it must stay live whatever
    /// the eventual answer; on the second the answer is known, so it follows the
    /// deny scope and goes inert for "Just this time", which records nothing to
    /// widen.
    ///
    /// The warning is one-sided on purpose, and belongs to the first step only:
    /// widening a refusal merely turns more agents away, while widening a grant
    /// is the single answer here that stops the prompt appearing at all. It
    /// keeps its space on the second step rather than collapsing, so stepping
    /// back and forth doesn't resize the alert (see the type's note).
    private var allAgentsSection: some View {
        let isInert = isChoosingDenyScope && !denyScope.isRemembered
        // Spacing lives in the warning's own padding so that collapsing it
        // leaves nothing behind — a stack spacing would hold an 8pt gap under
        // the row for the whole life of an alert the switch is never touched on.
        return VStack(alignment: .leading, spacing: 0) {
            allAgentsRow
                .disabled(isInert)
                .opacity(isInert ? 0.4 : 1)
            Text(NSLocalizedString("agentControl.connectionApproval.allAgentsScope.allowWarning", value: "If you allow, every agent that connects gets full control without asking you. Reverse it anytime in Settings ▸ Developer.",
                                   comment: "CDP consent - warning shown when the answer is widened to every agent, naming what that means on the allow side"))
                .font(.system(size: 11))
                .foregroundStyle(Color(nsColor: .systemOrange))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
                .reservingSpace(shown: allAgents && !isChoosingDenyScope)
                .frame(height: allAgents ? nil : 0, alignment: .top)
                .clipped()
        }
        .animation(.easeOut(duration: 0.15), value: isChoosingDenyScope)
        .animation(.easeOut(duration: 0.15), value: isInert)
    }

    private var allAgentsRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "person.3.fill")
                .font(.system(size: 13, weight: .medium))
                .themedForeground(.textSecondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(NSLocalizedString("agentControl.connectionApproval.allAgentsScope.title", value: "Apply to all agents",
                                       comment: "CDP consent - title of the switch that widens the answer from the asking agent to every agent"))
                    .font(.system(size: 12, weight: .medium))
                    .themedForeground(.textPrimary)
                Text(String(
                    format: NSLocalizedString("agentControl.connectionApproval.allAgentsScope.description", value: "Your answer covers every agent, not just “%@”.",
                                              comment: "CDP consent - explanation of the all-agents switch; %@ is the name of the agent asking for access"),
                    agentName))
                    .font(.system(size: 11))
                    .themedForeground(.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Toggle("", isOn: $allAgents)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .themedTint(.themeColor)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(appearance.isLight ? Color.black.opacity(0.045) : Color.white.opacity(0.06))
        )
    }

    // MARK: - Deny scope

    private var denySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(NSLocalizedString("agentControl.connectionApproval.denyScope.label", value: "How long should Phi refuse?",
                                   comment: "CDP consent - label over the picker that scopes the refusal, shown after the user presses Deny"))
                .font(.system(size: 12))
                .themedForeground(.textSecondary)
            PhiAlertSegmentedPicker(
                options: AgentAccessDenyScope.allCases,
                selection: $denyScope,
                title: \.segmentTitle)
            // Laid out for every scope so moving between segments doesn't
            // resize the alert; only "Never ask again" has anything to say.
            Text(NSLocalizedString("agentControl.connectionApproval.denyScope.reviewHint", value: "Blocked agents can be unblocked anytime in Settings ▸ Developer.",
                                   comment: "CDP consent - hint shown when the permanent deny scope is selected"))
                .font(.system(size: 11))
                .themedForeground(.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .reservingSpace(shown: denyScope == .forever)
        }
        .animation(.easeOut(duration: 0.15), value: denyScope)
    }

}

/// Keeps a view's place in the layout whether or not it is showing, so
/// revealing it fades rather than resizing the alert window around it.
///
/// Everything past the opacity is about a hidden layer still being *there*,
/// which `opacity(0)` on its own does nothing about: the two steps overlap in a
/// ZStack, so the hidden one lies over the visible one and would otherwise
/// swallow its clicks; `disabled` takes its controls out of the key-view loop,
/// so Tab doesn't land on a segmented picker nobody can see; and the
/// accessibility tree should describe the step the user is actually on.
private struct ReservedSpace: ViewModifier {
    let shown: Bool

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .allowsHitTesting(shown)
            .disabled(!shown)
            .accessibilityHidden(!shown)
    }
}

private extension View {
    func reservingSpace(shown: Bool) -> some View {
        modifier(ReservedSpace(shown: shown))
    }
}

#if DEBUG
private func previewIdentity(_ name: String, team: String?, signingId: String?,
                             verified: Bool, path: String, pid: pid_t?) -> AgentIdentity {
    AgentIdentity(key: verified ? "\(team ?? "signed"):\(signingId ?? name)" : "unsigned:\(path)",
                  displayName: name, teamId: team, signingId: signingId,
                  verified: verified, executablePath: path, pid: pid)
}

private let previewLaunchd = AgentProcessNode(
    pid: 1, name: "launchd", command: "/sbin/launchd", isAgent: false,
    identity: previewIdentity("launchd", team: nil, signingId: "com.apple.xpc.launchd",
                              verified: true, path: "/sbin/launchd", pid: 1))

private let previewCursor = previewIdentity(
    "Cursor", team: "Q6L2SF6YDW", signingId: "com.todesktop.230313mzl4w4u92",
    verified: true, path: "/Applications/Cursor.app/Contents/MacOS/Cursor", pid: 640)

private let previewSignedDetails = AgentProcessDetails(
    command: "/Applications/Cursor.app/Contents/MacOS/Cursor --agent",
    executablePath: "/Applications/Cursor.app/Contents/MacOS/Cursor",
    tree: [
        previewLaunchd,
        AgentProcessNode(pid: 640, name: "Cursor",
                         command: "/Applications/Cursor.app/Contents/MacOS/Cursor",
                         isAgent: true, identity: previewCursor),
    ])

private let previewPi = previewIdentity(
    "pi", team: nil, signingId: nil, verified: false, path: "pi", pid: 988)

private let previewUnsignedDetails = AgentProcessDetails(
    command: "/opt/homebrew/bin/node /Users/jx/.local/share/pi/node_modules/pi/dist/cli.js --serve",
    executablePath: "/opt/homebrew/bin/node",
    tree: [
        previewLaunchd,
        AgentProcessNode(pid: 431, name: "Terminal",
                         command: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal",
                         isAgent: false,
                         identity: previewIdentity("Terminal", team: nil,
                                                   signingId: "com.apple.Terminal", verified: true,
                                                   path: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal",
                                                   pid: 431)),
        AgentProcessNode(pid: 512, name: "-zsh", command: "-zsh", isAgent: false,
                         identity: previewIdentity("zsh", team: nil, signingId: nil,
                                                   verified: false, path: "/bin/zsh", pid: 512)),
        AgentProcessNode(pid: 988, name: "pi",
                         command: "/opt/homebrew/bin/node /Users/jx/.local/share/pi/node_modules/pi/dist/cli.js --serve",
                         isAgent: true, identity: previewPi),
    ])

#Preview("Agent access — signed, feature already on") {
    AgentAccessApprovalAlert(
        agent: previewCursor,
        opensGates: false,
        processDetails: previewSignedDetails
    ) { _ in }
        .padding(40)
        .background(Color(nsColor: .underPageBackgroundColor))
}

#Preview("Agent access — unsigned, allowing turns it on") {
    AgentAccessApprovalAlert(
        agent: previewPi,
        opensGates: true,
        processDetails: previewUnsignedDetails
    ) { _ in }
        .preferredColorScheme(.dark)
        .padding(40)
        .background(Color(nsColor: .underPageBackgroundColor))
}
#endif
