// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import SwiftUI

/// Universal editor for every Space's URL routing rules. Reachable from the
/// Spaces menu in the main menu bar. Each row carries its own target Space
/// picker so the user can manage all rules in one list — moving a rule from
/// one Space to another is a picker change, not a delete-and-recreate.
///
/// Persists via `SpaceManager.setAllRules(_:)`, which replaces every Space's
/// rule set atomically and pushes the recompiled routing table down to
/// Chromium in one shot. No direct LocalStore writes from the view, no
/// manual bridge calls.
///
/// Stays intentionally small: one host per row matched as either a domain
/// suffix (host + all subdomains) or an exact domain, enable toggle,
/// drag-to-reorder within the flat list. Sort order is preserved per target
/// Space at save time.
struct URLRulesEditor: View {
    @ObservedObject var manager: SpaceManager
    let onClose: () -> Void

    @State private var rows: [Row] = []
    /// Snapshot of the persisted rules taken when the sheet opened, so we
    /// can detect a no-op save and skip the LocalStore round-trip.
    @State private var initialFingerprint: String = ""

    /// Sentinel selection in a row's target-Space picker meaning "don't route
    /// to a fixed Space — prompt every time". Distinct from any real
    /// `spaceId` (UUID strings / "default-space"), so it can never collide.
    static let askSpaceTag = "__phi_ask__"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ruleList
            Divider()
            footer
        }
        .frame(minWidth: 620, idealWidth: 700, minHeight: 380, idealHeight: 460)
        .onAppear { load() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(NSLocalizedString("URL Rules",
                comment: "Title of the universal URL rules editor"))
                .font(.headline)
            Text(NSLocalizedString(
                "URLs matching any rule will open in the assigned Space, no matter where you click or type them.",
                comment: "Subtitle of the universal URL rules editor"
            ))
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var ruleList: some View {
        List {
            ForEach($rows) { $row in
                RuleRowView(row: $row, spaces: manager.spaces, onDelete: { delete(row) })
            }
            .onMove { offsets, destination in
                rows.move(fromOffsets: offsets, toOffset: destination)
            }
            if rows.isEmpty {
                emptyState
            }
        }
        .listStyle(.inset)
    }

    private var emptyState: some View {
        VStack(alignment: .center, spacing: 6) {
            Text(NSLocalizedString("No rules yet.",
                comment: "Empty state label in the URL rules editor"))
                .font(.body)
                .foregroundStyle(.secondary)
            Text(NSLocalizedString(
                "Pick a target Space and enter a host like \u{201C}github.com\u{201D}.",
                comment: "Empty state hint in the universal URL rules editor"
            ))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .listRowSeparator(.hidden)
    }

    private var footer: some View {
        HStack {
            Button {
                addBlankRow()
            } label: {
                Label(NSLocalizedString("Add Rule", comment: "Footer button in URL rules editor"),
                      systemImage: "plus")
            }
            .disabled(manager.spaces.isEmpty)
            Spacer()
            Button(NSLocalizedString("Cancel", comment: "Cancel button")) {
                onClose()
            }
            .keyboardShortcut(.cancelAction)
            Button(NSLocalizedString("Save", comment: "Save button")) {
                save()
                onClose()
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Data

    private func load() {
        rows = manager.allRules.map(Row.init(from:))
        initialFingerprint = fingerprint(of: rows)
    }

    private func addBlankRow() {
        guard let firstSpaceId = manager.spaces.first?.spaceId else { return }
        rows.append(Row(defaultSpaceId: firstSpaceId))
    }

    private func delete(_ row: Row) {
        rows.removeAll { $0.id == row.id }
    }

    private func save() {
        guard fingerprint(of: rows) != initialFingerprint else { return }
        let validSpaceIds = Set(manager.spaces.map(\.spaceId))
        var byTarget: [String: [LocalStore.URLRuleDraft]] = [:]
        for row in rows {
            let trimmedValue = row.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedValue.isEmpty else { continue }
            // Resolve the bucket Space. An auto-route rule must target a live
            // Space; an "ask every time" rule only uses its target as the
            // prompt's default, so if that Space was deleted fall back to any
            // Space rather than dropping the rule.
            let targetSpaceId: String
            if validSpaceIds.contains(row.targetSpaceId) {
                targetSpaceId = row.targetSpaceId
            } else if row.askBeforeRouting, let fallback = manager.spaces.first?.spaceId {
                targetSpaceId = fallback
            } else {
                continue
            }
            let (host, pathPrefix) = row.matchType.encode(value: trimmedValue)
            guard !host.isEmpty else { continue }
            let draft = LocalStore.URLRuleDraft(
                id: row.id.uuidString,
                host: host,
                pathPrefix: pathPrefix,
                askBeforeRouting: row.askBeforeRouting,
                createdDate: row.createdDate
            )
            byTarget[targetSpaceId, default: []].append(draft)
        }
        manager.setAllRules(byTarget)
    }

    private func fingerprint(of rows: [Row]) -> String {
        rows.map { row in
            "\(row.id.uuidString)|\(row.askBeforeRouting ? 1 : 0)|\(row.targetSpaceId)|\(row.matchType.rawValue)|\(row.value)"
        }.joined(separator: "\n")
    }

    // MARK: - Row model

    enum MatchType: String, CaseIterable, Identifiable {
        case domainSuffix    // host + all subdomains ("*.host")
        case domain          // exact host only
        case domainContains  // host contains a substring ("*needle*")
        case url             // exact host + path prefix ("github.com" + "/anthropics")

        var id: String { rawValue }

        var label: String {
            switch self {
            case .domainSuffix:
                return NSLocalizedString("Domain suffix",
                    comment: "URL rule match type: host plus all subdomains")
            case .domain:
                return NSLocalizedString("Domain",
                    comment: "URL rule match type: exact host only")
            case .domainContains:
                return NSLocalizedString("Domain contains",
                    comment: "URL rule match type: host contains a substring")
            case .url:
                return NSLocalizedString("URL",
                    comment: "URL rule match type: exact host plus a path prefix")
            }
        }

        var placeholder: String {
            switch self {
            case .domainSuffix:
                return NSLocalizedString("example.com",
                    comment: "URL rule value placeholder for Domain suffix match")
            case .domain:
                return NSLocalizedString("www.example.com",
                    comment: "URL rule value placeholder for Domain match")
            case .domainContains:
                return NSLocalizedString("example",
                    comment: "URL rule value placeholder for Domain contains match")
            case .url:
                return NSLocalizedString("https://example.com/path",
                    comment: "URL rule value placeholder for URL (host + path) match")
            }
        }

        /// Translate the editor's (matchType, value) into the persisted
        /// (host, pathPrefix?) pair the C++ matcher expects. The host-only
        /// modes reduce the value to a bare host (a pasted full URL would
        /// otherwise leave the scheme or a "/" inside the stored host and
        /// the rule would silently never match — GURL hosts contain
        /// neither). The `.url` mode instead keeps the path, splitting the
        /// pasted URL into an exact host plus a path prefix.
        ///
        /// The "*" sigils in the stored host are the wire sentinel, not
        /// user input: the mode picker is the single source of truth, so
        /// any typed "*."/"*"s are stripped and `encode` re-adds the form
        /// its own mode requires. An input that reduces to nothing (e.g. a
        /// bare "*.") yields an empty host, which `save()` drops.
        func encode(value: String) -> (host: String, pathPrefix: String?) {
            var work = value
            if let scheme = work.range(of: "://") {
                work = String(work[scheme.upperBound...])
            }
            // The `.url` mode is the only one that keeps the path: split the
            // value at the first "/" into host + path. The path is returned
            // raw — `LocalStore.URLRuleDraft.init` canonicalizes it (leading
            // slash, percent-encoding, trailing-slash collapse).
            if self == .url {
                var hostPart = work
                var pathPart = ""
                if let slash = work.firstIndex(of: "/") {
                    hostPart = String(work[..<slash])
                    pathPart = String(work[slash...])
                }
                let bare = hostPart.hasPrefix("*.") ? String(hostPart.dropFirst(2)) : hostPart
                let host = Self.stripPort(bare)
                return (host, pathPart.isEmpty ? nil : pathPart)
            }
            if let slash = work.firstIndex(of: "/") {
                work = String(work[..<slash])
            }
            work = Self.stripPort(work)
            switch self {
            case .domainSuffix:
                let bare = work.hasPrefix("*.") ? String(work.dropFirst(2)) : work
                return (bare.isEmpty ? "" : "*." + bare, nil)
            case .domain:
                let bare = work.hasPrefix("*.") ? String(work.dropFirst(2)) : work
                return (bare, nil)
            case .domainContains:
                let needle = work.trimmingCharacters(in: CharacterSet(charactersIn: "*"))
                return (needle.isEmpty ? "" : "*\(needle)*", nil)
            case .url:
                return (work, nil)  // unreachable — handled above
            }
        }

        /// Drops a pasted port — GURL::host() never carries one, so a
        /// ":8080" baked into the stored host could never match. Only cuts
        /// when everything after the last ":" is digits, which leaves
        /// bracketed IPv6 literals ("[::1]") untouched.
        private static func stripPort(_ host: String) -> String {
            guard let colon = host.lastIndex(of: ":") else { return host }
            let port = host[host.index(after: colon)...]
            guard !port.isEmpty, port.allSatisfy(\.isNumber) else { return host }
            return String(host[..<colon])
        }

        /// Inverse of `encode` — pick the match type for an existing rule.
        /// A non-empty `pathPrefix` means the rule was authored as a `.url`
        /// match, so the host and path are shown joined back together. The
        /// contains form is checked before the suffix form for the same
        /// reason the matchers do: a needle starting with "." (e.g.
        /// "*.git.*") also carries the "*." prefix.
        static func decode(host: String, pathPrefix: String?) -> (MatchType, String) {
            if let path = pathPrefix, !path.isEmpty {
                return (.url, host + path)
            }
            if host.count > 2, host.hasPrefix("*"), host.hasSuffix("*") {
                return (.domainContains, String(host.dropFirst().dropLast()))
            }
            if host.hasPrefix("*.") {
                return (.domainSuffix, String(host.dropFirst(2)))
            }
            return (.domain, host)
        }
    }

    struct Row: Identifiable {
        let id: UUID
        var targetSpaceId: String
        var matchType: MatchType
        var value: String
        /// When true, a matching navigation prompts for a Space instead of
        /// routing to `targetSpaceId` automatically.
        var askBeforeRouting: Bool
        var createdDate: Date

        init(defaultSpaceId: String) {
            self.id = UUID()
            self.targetSpaceId = defaultSpaceId
            self.matchType = .domainSuffix
            self.value = ""
            self.askBeforeRouting = false
            self.createdDate = Date()
        }

        init(from rule: SpaceURLRule) {
            self.id = UUID(uuidString: rule.id) ?? UUID()
            self.targetSpaceId = rule.spaceId
            let (matchType, value) = MatchType.decode(
                host: rule.host, pathPrefix: rule.pathPrefix)
            self.matchType = matchType
            self.value = value
            self.askBeforeRouting = rule.askBeforeRouting
            self.createdDate = rule.createdDate
        }
    }
}

private struct RuleRowView: View {
    @Binding var row: URLRulesEditor.Row
    let spaces: [SpaceModel]
    let onDelete: () -> Void

    // List rows on macOS swallow the first click so the underlying
    // NSTextField never becomes first responder and the focus ring fails
    // to appear. Tracking focus through @FocusState and forcing it on tap
    // makes the ring show reliably on the very first click.
    @FocusState private var valueFieldFocused: Bool

    /// Fixed width for the match-type picker — sized to the widest label
    /// ("Domain contains") so the menu button never truncates.
    private static let matchPickerWidth: CGFloat = 150
    private static let columnSpacing: CGFloat = 10
    /// Width reserved for the trailing delete button, so the second line's
    /// Space picker stops at the same x as the first line's value field.
    private static let deleteColumnWidth: CGFloat = 22

    /// Folds the ask-first action into the target-Space picker: the selection
    /// is a real `spaceId` for an auto-routed rule, or `askSpaceTag` for an
    /// "ask every time" rule. Picking "Ask every time" leaves the row's
    /// `targetSpaceId` intact so it stays the prompt's suggested default.
    private var targetSelection: Binding<String> {
        Binding(
            get: { row.askBeforeRouting ? URLRulesEditor.askSpaceTag : row.targetSpaceId },
            set: { newValue in
                if newValue == URLRulesEditor.askSpaceTag {
                    row.askBeforeRouting = true
                } else {
                    row.askBeforeRouting = false
                    row.targetSpaceId = newValue
                }
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            matchLine
            destinationLine
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    /// First line: the rule type (match-type) picker, the value field, and a
    /// trailing delete button.
    private var matchLine: some View {
        HStack(spacing: Self.columnSpacing) {
            Picker("", selection: $row.matchType) {
                ForEach(URLRulesEditor.MatchType.allCases) { type in
                    Text(type.label).tag(type)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: Self.matchPickerWidth)
            TextField(row.matchType.placeholder, text: $row.value)
                .textFieldStyle(.roundedBorder)
                .focused($valueFieldFocused)
                .onTapGesture { valueFieldFocused = true }
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .frame(width: Self.deleteColumnWidth)
            .help(NSLocalizedString("Remove rule", comment: "Tooltip for remove-rule button"))
        }
    }

    /// Second line: an "Open in" label and the target-Space chooser, right-
    /// aligned as a pair so the picker stops at the value field's trailing edge
    /// and the label hugs its leading side.
    private var destinationLine: some View {
        HStack(spacing: Self.columnSpacing) {
            Text(NSLocalizedString("Open in", comment: "Leading label for a URL rule's target Space"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
            Picker("", selection: targetSelection) {
                ForEach(spaces, id: \.spaceId) { space in
                    Label {
                        Text(Self.spaceMenuTitle(space))
                    } icon: {
                        Image(systemName: Self.iconSymbol(for: space))
                    }
                    .tag(space.spaceId)
                }
                Divider()
                Text(NSLocalizedString("Ask every time",
                    comment: "Special target in the URL rule Space picker: prompt for a Space on each match"))
                    .tag(URLRulesEditor.askSpaceTag)
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
        }
        // Stop the Space picker at the value field's trailing edge rather than
        // running under the delete button.
        .padding(.trailing, Self.deleteColumnWidth + Self.columnSpacing)
    }

    /// "Space name — Profile" for a Space option, so each entry shows which
    /// profile it routes into alongside the Space name. Falls back to just the
    /// name when the profile can't be resolved yet.
    private static func spaceMenuTitle(_ space: SpaceModel) -> String {
        let profileName = ProfileManager.shared.profile(for: space.profileId)?.displayName ?? space.profileId
        guard !profileName.isEmpty else { return space.name }
        return "\(space.name) \u{2014} \(profileName)"
    }

    /// SF Symbol shown beside each Space option; falls back to the generic
    /// stack glyph when a Space carries no custom icon.
    private static func iconSymbol(for space: SpaceModel) -> String {
        space.iconName.isEmpty ? "rectangle.stack" : space.iconName
    }
}
