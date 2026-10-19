// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import SwiftUI

/// The sync method step (docs/sync.md, "Sync method and replacing this Mac's data"): what each side holds,
/// then two radio cards, merge (the default) or use the account's data. The wizard footer owns the primary
/// button and Return; this view only changes the selection.
struct SyncMethodStepView: View {
    let summary: PairingDataSummary
    @Binding var selection: SyncMethod
    /// Whether "use your account's data" is offered (the local data reset is available).
    var offersUseAccount = true

    @FocusState private var focused: Bool
    /// The card the arrow keys point at; Space selects it.
    @State private var highlighted: SyncMethod?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(NSLocalizedString("sync.pairing.method.title",
                                   value: "How should this Mac sync?",
                                   comment: "Sync setup method step - title of the page that chooses between merging this Mac with the account and using the account's data"))
                .font(.title2.bold())
                .themedForeground(.textPrimaryStrong)
            Text(NSLocalizedString("sync.pairing.method.explanation",
                                   value: "Choose how to combine your account’s data with what’s on this Mac.",
                                   comment: "Sync setup method step - one-line explanation under the title"))
                .font(.body)
                .themedForeground(.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            comparisonStrip
            VStack(spacing: 12) {
                ForEach(methods, id: \.self) { card($0) }
            }
            // The arrow keys move the keyboard highlight between the cards and Space selects the highlighted
            // card. Return is left to the footer's default action (Continue or Finish).
            .focusable()
            .focusEffectDisabled()
            .focused($focused)
            .onAppear { focused = true }
            .onKeyPress(.upArrow) { moveHighlight(by: -1); return .handled }
            .onKeyPress(.downArrow) { moveHighlight(by: 1); return .handled }
            .onKeyPress(.space) { selection = highlighted ?? selection; return .handled }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(PairingStepBar.title(for: .method))
        }
    }

    private var methods: [SyncMethod] { offersUseAccount ? [.merge, .useAccount] : [.merge] }

    private func moveHighlight(by offset: Int) {
        let current = methods.firstIndex(of: highlighted ?? selection) ?? 0
        highlighted = methods[min(max(current + offset, 0), methods.count - 1)]
    }

    // MARK: - Comparison strip

    private var comparisonStrip: some View {
        VStack(alignment: .leading, spacing: 0) {
            stripRow(label: NSLocalizedString("sync.pairing.method.compare.thisMac", value: "This Mac",
                                              comment: "Sync setup method step - label starting the line that counts the data on this Mac"),
                     counts: summary.local)
            SettingsRowDivider()
            stripRow(label: NSLocalizedString("sync.pairing.method.compare.account", value: "Your account",
                                              comment: "Sync setup method step - label starting the line that counts the data in the sync account"),
                     counts: summary.account)
        }
        .padding(.horizontal, 12)
        .settingsCardChrome()
    }

    private func stripRow(label: String, counts: PairingDataSummary.Counts) -> some View {
        let line = PairingDataSummary.stripLine(label: label, counts: counts)
        return Text(Self.boldingPrefix(label, of: line))
            .font(.body)
            .themedForeground(.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(line)
    }

    /// The side's label in bold. A translation that does not start with the label stays plain.
    private static func boldingPrefix(_ prefix: String, of line: String) -> AttributedString {
        var text = AttributedString(line)
        if line.hasPrefix(prefix), let range = text.range(of: prefix) {
            text[range].font = .body.bold()
        }
        return text
    }

    // MARK: - Method cards

    private func card(_ method: SyncMethod) -> some View {
        let selected = selection == method
        let showsHighlight = focused && highlighted == method && !selected
        let title = Self.title(for: method)
        let detail = Self.detail(for: method)
        return Button {
            selection = method
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(title).font(.body.bold()).themedForeground(.textPrimaryStrong)
                        if method == .merge {
                            SettingsBadge(text: Self.recommended)
                        }
                    }
                    Text(detail)
                        .font(.callout)
                        .themedForeground(.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .settingsCardChrome()
        .overlay {
            if selected {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Color.accentColor, lineWidth: 2)
            } else if showsHighlight {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Color.accentColor.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(method == .merge
                            ? Text(title) + Text(verbatim: ", ") + Text(Self.recommended)
                            : Text(title))
        .accessibilityHint(detail)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private static let recommended = NSLocalizedString("sync.pairing.method.recommended",
        value: "Recommended",
        comment: "Sync setup method step - pill on the merge option marking it as the recommended choice")

    private static func title(for method: SyncMethod) -> String {
        switch method {
        case .merge:
            return NSLocalizedString("sync.pairing.method.merge.title",
                                     value: "Merge this Mac with your account",
                                     comment: "Sync setup method step - title of the option that keeps this Mac's data and combines it with the account's")
        case .useAccount:
            return NSLocalizedString("sync.pairing.method.useAccount.title",
                                     value: "Use your account’s data",
                                     comment: "Sync setup method step - title of the option that replaces this Mac's data with the account's")
        }
    }

    private static func detail(for method: SyncMethod) -> String {
        switch method {
        case .merge:
            return NSLocalizedString("sync.pairing.method.merge.detail",
                                     value: "Match profiles and Spaces one by one. Bookmarks, pinned tabs and URL rules from both sides are kept.",
                                     comment: "Sync setup method step - explanation under the merge option")
        case .useAccount:
            return NSLocalizedString("sync.pairing.method.useAccount.detail",
                                     value: "Replace this Mac’s Spaces, bookmarks, pinned tabs, URL rules and synced settings with your account’s. Only this Mac changes.",
                                     comment: "Sync setup method step - explanation under the option that replaces this Mac's data with the account's")
        }
    }
}
