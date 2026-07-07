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
        // The table host is always mounted (even when empty), so deleting the
        // last rule doesn't tear down the NSView tree mid-animation and adding
        // the first rule doesn't rebuild it. The empty-state placeholder lives
        // inside the host (see RuleTableView.makeEmptyOverlay).
        RuleTableView(rows: $rows, spaces: visibleSpaces)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack {
            Button {
                addBlankRow()
            } label: {
                Label(NSLocalizedString("Add Rule", comment: "Footer button in URL rules editor"),
                      systemImage: "plus")
            }
            .disabled(visibleSpaces.isEmpty)
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

    /// Spaces the user can route a rule to. Agent Spaces are ephemeral
    /// background workspaces and must never appear as a routing target or in
    /// the target picker.
    private var visibleSpaces: [SpaceModel] {
        manager.spaces.filter { !$0.isAgentSpace }
    }

    private func addBlankRow() {
        guard let firstSpaceId = visibleSpaces.first?.spaceId else { return }
        rows.append(Row(defaultSpaceId: firstSpaceId))
    }

    private func save() {
        guard fingerprint(of: rows) != initialFingerprint else { return }
        let validSpaceIds = Set(visibleSpaces.map(\.spaceId))
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
            } else if row.askBeforeRouting, let fallback = visibleSpaces.first?.spaceId {
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

// MARK: - AppKit rule list

/// AppKit-backed list of URL rules. SwiftUI's `List` defers an embedded
/// NSTextField's first responder ~2s (the List/NSTableView wrapper runs
/// click-vs-drag disambiguation on mouse-down) and can't reconcile native
/// drag-reorder with instant field focus. A hand-built NSTableView gets all of
/// it natively: click a field → it focuses immediately; drag a row's empty area
/// → native reorder with live row-parting + a drop indicator; click empty →
/// focus resigns. The SwiftUI shell (header / footer / save) is unchanged.
private struct RuleTableView: NSViewRepresentable {
    @Binding var rows: [URLRulesEditor.Row]
    let spaces: [SpaceModel]

    /// Captures every Space field shown in the target popup, so a rename / icon
    /// / profile change (same `spaceId`) still triggers a reload — comparing ids
    /// alone would leave the already-built menus in displayed rows stale.
    private var spacesFingerprint: String {
        spaces.map { "\($0.spaceId)\u{1F}\($0.name)\u{1F}\($0.iconName)\u{1F}\($0.profileId)" }
            .joined(separator: "\u{1E}")
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSView {
        let tableView = NSTableView()
        let column = NSTableColumn(identifier: .ruleColumn)
        column.resizingMask = .autoresizingMask
        column.minWidth = 200
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .inset
        tableView.rowHeight = Coordinator.rowHeight
        tableView.intercellSpacing = NSSize(width: 0, height: 4)
        tableView.selectionHighlightStyle = .none
        tableView.allowsEmptySelection = true
        tableView.allowsMultipleSelection = false
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.dataSource = context.coordinator
        tableView.delegate = context.coordinator
        tableView.registerForDraggedTypes([.string])
        tableView.setDraggingSourceOperationMask(.move, forLocal: true)
        context.coordinator.tableView = tableView
        context.coordinator.displayedIDs = rows.map(\.id)
        context.coordinator.spacesFingerprint = spacesFingerprint

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let overlay = Self.makeEmptyOverlay()
        overlay.isHidden = !rows.isEmpty
        context.coordinator.emptyOverlay = overlay

        let container = NSView()
        container.addSubview(scrollView)
        container.addSubview(overlay)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            overlay.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            overlay.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            overlay.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 24),
            overlay.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -24),
        ])
        return container
    }

    /// Centered "no rules yet" placeholder shown inside the table host while
    /// there are no rows, so the empty state never swaps the NSView out (which
    /// would fight the delete/insert row animations).
    private static func makeEmptyOverlay() -> NSView {
        let title = NSTextField(labelWithString:
            NSLocalizedString("No rules yet.", comment: "Empty state label in the URL rules editor"))
        title.font = .preferredFont(forTextStyle: .body)
        title.textColor = .secondaryLabelColor
        title.alignment = .center
        let hint = NSTextField(labelWithString: NSLocalizedString(
            "Pick a target Space and enter a host like \u{201C}github.com\u{201D}.",
            comment: "Empty state hint in the universal URL rules editor"))
        hint.font = .preferredFont(forTextStyle: .caption1)
        hint.textColor = .secondaryLabelColor
        hint.alignment = .center
        hint.maximumNumberOfLines = 0
        let stack = NSStackView(views: [title, hint])
        stack.orientation = .vertical
        stack.spacing = 6
        stack.alignment = .centerX
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let tableView = coordinator.tableView else { return }
        coordinator.emptyOverlay?.isHidden = !rows.isEmpty

        let oldIDs = coordinator.displayedIDs
        let newIDs = rows.map(\.id)
        let newFingerprint = spacesFingerprint

        if oldIDs == newIDs {
            // No structural change. Content edits, delete and reorder were
            // applied in place by the coordinator; only a Space display change
            // needs a reload here (never mid-edit — the fingerprint is stable
            // while editing, so the field editor is never dropped).
            if coordinator.spacesFingerprint != newFingerprint {
                coordinator.spacesFingerprint = newFingerprint
                tableView.reloadData()
            }
            return
        }

        coordinator.displayedIDs = newIDs
        coordinator.spacesFingerprint = newFingerprint

        // A single blank row appended at the end is the "Add Rule" path: insert
        // incrementally, scroll it into view, and focus its value field. A saved
        // rule always has a non-empty value, so the initial load never matches
        // and won't steal focus. Anything else falls back to a full reload.
        if newIDs.count == oldIDs.count + 1,
           Array(newIDs.prefix(oldIDs.count)) == oldIDs,
           rows[newIDs.count - 1].value.isEmpty {
            let newRow = newIDs.count - 1
            let newID = newIDs[newRow]
            tableView.insertRows(at: IndexSet(integer: newRow), withAnimation: .effectFade)
            tableView.scrollRowToVisible(newRow)
            // Resolve the row by id when the async fires (matching the drag
            // path); the captured index could otherwise be stale if the row set
            // changes before this runs. firstIndex is bounds-safe — a removed
            // row just yields nil and we skip focusing.
            DispatchQueue.main.async { [weak coordinator, weak tableView] in
                guard let coordinator, let tableView,
                      let row = coordinator.displayedIDs.firstIndex(of: newID),
                      let cell = tableView.view(atColumn: 0, row: row,
                                                makeIfNecessary: true) as? RuleCellView
                else { return }
                cell.beginEditingValue()
            }
        } else {
            tableView.reloadData()
        }
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        static let rowHeight: CGFloat = 70
        var parent: RuleTableView
        weak var tableView: NSTableView?
        weak var emptyOverlay: NSView?
        var displayedIDs: [UUID] = []
        var spacesFingerprint: String = ""

        init(_ parent: RuleTableView) { self.parent = parent }

        func numberOfRows(in tableView: NSTableView) -> Int { parent.rows.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let cell = tableView.makeView(withIdentifier: .ruleCell, owner: self) as? RuleCellView
                ?? RuleCellView()
            cell.identifier = .ruleCell
            let id = parent.rows[row].id
            cell.configure(row: parent.rows[row], spaces: parent.spaces,
                           askSpaceTag: URLRulesEditor.askSpaceTag)
            cell.onValueChange = { [weak self] newValue in
                self?.mutate(id: id) { $0.value = newValue }
            }
            cell.onMatchTypeChange = { [weak self] newType in
                self?.mutate(id: id) { $0.matchType = newType }
            }
            cell.onTargetChange = { [weak self] selection in
                self?.mutate(id: id) { row in
                    if selection == URLRulesEditor.askSpaceTag {
                        row.askBeforeRouting = true
                    } else {
                        row.askBeforeRouting = false
                        row.targetSpaceId = selection
                    }
                }
            }
            cell.onDelete = { [weak self] in self?.deleteRow(id: id) }
            return cell
        }

        /// Applies a content edit in place — order/count unchanged, so the
        /// follow-up `updateNSView` is a no-op and the field keeps focus.
        private func mutate(id: UUID, _ change: (inout URLRulesEditor.Row) -> Void) {
            guard let index = parent.rows.firstIndex(where: { $0.id == id }) else { return }
            var updated = parent.rows
            change(&updated[index])
            parent.rows = updated
        }

        private func deleteRow(id: UUID) {
            guard let index = parent.rows.firstIndex(where: { $0.id == id }) else { return }
            var updated = parent.rows
            updated.remove(at: index)
            parent.rows = updated
            displayedIDs = updated.map(\.id)
            tableView?.removeRows(at: IndexSet(integer: index), withAnimation: .effectFade)
        }

        // MARK: Native drag-to-reorder

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            guard parent.rows.indices.contains(row) else { return nil }
            let item = NSPasteboardItem()
            // Serialize stable row identity (UUID), not the index — the index can
            // go stale and an unchecked remove(at:)/insert(at:) would trap.
            item.setString(parent.rows[row].id.uuidString, forType: .string)
            return item
        }

        func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo,
                       proposedRow row: Int,
                       proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
            guard (info.draggingSource as? NSTableView) === tableView else { return [] }
            // Coerce a drop ONTO a row into an insertion ABOVE it, so the whole
            // row body is a valid reorder target — not just the thin gap between
            // rows. acceptDrop then receives a `.above` row it already handles.
            if dropOperation == .on {
                tableView.setDropRow(row, dropOperation: .above)
            }
            return .move
        }

        func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo,
                       row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
            // Resolve the source by stable id (not the serialized index) and
            // bounds-check both ends, so a stale / out-of-range drop can't trap.
            guard (info.draggingSource as? NSTableView) === tableView,
                  let item = info.draggingPasteboard.pasteboardItems?.first,
                  let idString = item.string(forType: .string),
                  let sourceRow = parent.rows.firstIndex(where: { $0.id.uuidString == idString })
            else { return false }
            let target = max(0, min(row, parent.rows.count))
            let destination = sourceRow < target ? target - 1 : target
            guard destination != sourceRow else { return false }
            var updated = parent.rows
            let moved = updated.remove(at: sourceRow)
            updated.insert(moved, at: destination)
            parent.rows = updated
            displayedIDs = updated.map(\.id)
            tableView.beginUpdates()
            tableView.moveRow(at: sourceRow, to: destination)
            tableView.endUpdates()
            return true
        }
    }
}

/// One two-line rule row, built from AppKit controls. Exposes per-control
/// change closures that the table coordinator wires to the matching `Row` by
/// id, so reordering never desyncs a control from its rule.
private final class RuleCellView: NSTableCellView, NSTextFieldDelegate {
    var onValueChange: ((String) -> Void)?
    var onMatchTypeChange: ((URLRulesEditor.MatchType) -> Void)?
    var onTargetChange: ((String) -> Void)?
    var onDelete: (() -> Void)?

    private static let matchTypes = URLRulesEditor.MatchType.allCases

    private let matchTypePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let valueField = NSTextField()
    private let deleteButton = NSButton()
    private let openInLabel = NSTextField(labelWithString:
        NSLocalizedString("Open in", comment: "Leading label for a URL rule's target Space"))
    private let targetPopup = NSPopUpButton(frame: .zero, pullsDown: false)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildLayout()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func buildLayout() {
        matchTypePopup.addItems(withTitles: Self.matchTypes.map(\.label))
        matchTypePopup.target = self
        matchTypePopup.action = #selector(matchTypeChanged)

        valueField.isBezeled = true
        valueField.bezelStyle = .roundedBezel
        valueField.usesSingleLineMode = true
        valueField.lineBreakMode = .byTruncatingTail
        valueField.cell?.isScrollable = true
        valueField.delegate = self

        deleteButton.image = NSImage(systemSymbolName: "trash", accessibilityDescription:
            NSLocalizedString("Remove rule", comment: "Tooltip for remove-rule button"))
        deleteButton.isBordered = false
        deleteButton.contentTintColor = .secondaryLabelColor
        deleteButton.target = self
        deleteButton.action = #selector(deleteClicked)
        deleteButton.toolTip = NSLocalizedString("Remove rule", comment: "Tooltip for remove-rule button")

        openInLabel.textColor = .secondaryLabelColor
        openInLabel.font = .preferredFont(forTextStyle: .callout)

        targetPopup.target = self
        targetPopup.action = #selector(targetChanged)

        let line1 = NSStackView(views: [matchTypePopup, valueField, deleteButton])
        line1.orientation = .horizontal
        line1.spacing = 10
        line1.alignment = .centerY
        line1.distribution = .fill

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let line2 = NSStackView(views: [spacer, openInLabel, targetPopup])
        line2.orientation = .horizontal
        line2.spacing = 8
        line2.alignment = .centerY

        let vstack = NSStackView(views: [line1, line2])
        vstack.orientation = .vertical
        vstack.spacing = 8
        vstack.alignment = .leading
        vstack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(vstack)

        valueField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        valueField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        NSLayoutConstraint.activate([
            matchTypePopup.widthAnchor.constraint(equalToConstant: 150),
            deleteButton.widthAnchor.constraint(equalToConstant: 22),
            vstack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            vstack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            vstack.centerYAnchor.constraint(equalTo: centerYAnchor),
            line1.widthAnchor.constraint(equalTo: vstack.widthAnchor),
            line2.leadingAnchor.constraint(equalTo: vstack.leadingAnchor),
            // Stop the Space popup at the value field's trailing edge (delete
            // button width + spacing), matching the first line's columns.
            line2.trailingAnchor.constraint(equalTo: vstack.trailingAnchor, constant: -32),
        ])
    }

    func configure(row: URLRulesEditor.Row, spaces: [SpaceModel], askSpaceTag: String) {
        if let index = Self.matchTypes.firstIndex(of: row.matchType) {
            matchTypePopup.selectItem(at: index)
        }
        valueField.stringValue = row.value
        valueField.placeholderString = row.matchType.placeholder

        let menu = NSMenu()
        for space in spaces {
            let item = NSMenuItem(title: Self.spaceMenuTitle(space), action: nil, keyEquivalent: "")
            // Render through SpaceIconView so phi-icons / emoji (which
            // `NSImage(systemSymbolName:)` can't resolve) show here too, matching
            // the Spaces switcher menu — not just legacy SF Symbol icons.
            item.image = SpaceIconView.menuImage(for: space.iconName)
            item.representedObject = space.spaceId
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let askItem = NSMenuItem(
            title: NSLocalizedString("Ask every time",
                comment: "Special target in the URL rule Space picker: prompt for a Space on each match"),
            action: nil, keyEquivalent: "")
        askItem.representedObject = askSpaceTag
        menu.addItem(askItem)
        targetPopup.menu = menu

        let selectedTag = row.askBeforeRouting ? askSpaceTag : row.targetSpaceId
        if let match = menu.items.first(where: { ($0.representedObject as? String) == selectedTag }) {
            targetPopup.select(match)
        } else if row.askBeforeRouting {
            targetPopup.select(askItem)
        } else {
            // Auto-route rule whose target Space was deleted. Show an explicit
            // disabled "unavailable" item (NOT a false "Ask every time") so the
            // user must re-target it; if left as-is, save() drops it as before.
            let missing = NSMenuItem(
                title: NSLocalizedString("Target Space unavailable",
                    comment: "URL rule target whose Space no longer exists"),
                action: nil, keyEquivalent: "")
            missing.isEnabled = false
            missing.representedObject = row.targetSpaceId
            menu.insertItem(missing, at: 0)
            targetPopup.select(missing)
        }
    }

    @objc private func matchTypeChanged() {
        let type = Self.matchTypes[matchTypePopup.indexOfSelectedItem]
        valueField.placeholderString = type.placeholder
        onMatchTypeChange?(type)
    }

    @objc private func targetChanged() {
        guard let tag = targetPopup.selectedItem?.representedObject as? String else { return }
        onTargetChange?(tag)
    }

    @objc private func deleteClicked() { onDelete?() }

    func controlTextDidChange(_ obj: Notification) { onValueChange?(valueField.stringValue) }

    /// Focuses this row's value field — used to drop the cursor into a freshly
    /// added rule so the user can type immediately.
    func beginEditingValue() {
        window?.makeFirstResponder(valueField)
    }

    /// "Space name — Profile" so each entry shows which profile it routes into.
    private static func spaceMenuTitle(_ space: SpaceModel) -> String {
        let profileName = ProfileManager.shared.profile(for: space.profileId)?.displayName ?? space.profileId
        guard !profileName.isEmpty else { return space.name }
        return "\(space.name) \u{2014} \(profileName)"
    }
}

private extension NSUserInterfaceItemIdentifier {
    static let ruleCell = NSUserInterfaceItemIdentifier("PhiURLRuleCell")
    static let ruleColumn = NSUserInterfaceItemIdentifier("PhiURLRuleColumn")
}
