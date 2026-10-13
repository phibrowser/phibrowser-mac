// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Combine
import Foundation

/// A page tab's AI Chat panel as Chromium keeps it for undo close (chromium
/// ADR 0017): the conversation the panel shows and whether it is expanded.
/// Chromium stores the encoded string without reading it; the format and its
/// version belong to this client.
struct AIChatPanelRecord: Equatable {
    static let currentVersion = 1

    let isExpanded: Bool
    let conversationId: String?

    /// The record a page tab has: an expanded panel, or a collapsed one that
    /// shows a conversation. A collapsed panel without one has no record.
    init?(isExpanded: Bool, conversationId: String?) {
        guard isExpanded || conversationId != nil else { return nil }
        self.isExpanded = isExpanded
        self.conversationId = conversationId
    }

    private struct Encoding: Codable {
        let v: Int
        let expanded: Bool
        let conversationId: String?
    }

    var encoded: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let value = Encoding(v: Self.currentVersion, expanded: isExpanded, conversationId: conversationId)
        guard let data = try? encoder.encode(value) else {
            assertionFailure("AIChatPanelRecord did not encode")
            return ""
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// nil for a malformed record or one written in another version.
    init?(encoded: String) {
        guard let value = try? JSONDecoder().decode(Encoding.self, from: Data(encoded.utf8)),
              value.v == Self.currentVersion else {
            return nil
        }
        if let conversationId = value.conversationId, UUID(uuidString: conversationId) == nil {
            return nil
        }
        self.init(isExpanded: value.expanded, conversationId: value.conversationId)
    }

    /// The conversation a panel page shows, read off its URL. Chromium hands
    /// the page's `index.html?conv_id=<uuid>` over as
    /// `chrome://conversation/<uuid>`; both forms are read.
    static func conversationId(fromPanelURL url: String?) -> String? {
        guard let url, let components = URLComponents(string: url) else { return nil }
        let candidate: String?
        if components.scheme == "chrome", components.host == "conversation" {
            candidate = components.path.split(separator: "/").first.map(String.init)
        } else {
            candidate = components.queryItems?.first(where: { $0.name == "conv_id" })?.value
        }
        guard let candidate, UUID(uuidString: candidate) != nil else { return nil }
        return candidate
    }
}

extension BrowserState {
    /// Keeps Chromium's copy of each page tab's panel record current: it is
    /// recomputed when the tab expands or collapses, when its panel tab
    /// appears, and when the panel's URL names another conversation. Closing
    /// the page tab pushes nothing, so the record goes into its closed entry,
    /// unless a split pane hands its panel over (`handOffAIChatPanelRecord`).
    func watchAIChatPanelRecords() {
        $tabs
            .sink { [weak self] tabs in self?.watchAIChatCollapse(of: tabs) }
            .store(in: &aiChatPanelRecordSubscriptions)
        $aiChatTabs
            .sink { [weak self] chats in self?.watchAIChatPanelURLs(of: chats) }
            .store(in: &aiChatPanelRecordSubscriptions)
    }

    private func watchAIChatCollapse(of tabs: [Tab]) {
        let live = Set(tabs.map(ObjectIdentifier.init))
        for (id, watch) in aiChatCollapseWatches where !live.contains(id) {
            aiChatCollapseWatches[id] = nil
            aiChatPanelRecordsPushed[watch.tabId] = nil
        }
        for tab in tabs where aiChatCollapseWatches[ObjectIdentifier(tab)] == nil {
            let watch = tab.$aiChatCollapsed
                .dropFirst()
                .sink { [weak self, weak tab] collapsed in
                    guard let self, let tab else { return }
                    self.pushAIChatPanelRecord(of: tab, isExpanded: !collapsed)
                }
            aiChatCollapseWatches[ObjectIdentifier(tab)] = (tab.guid, watch)
        }
    }

    private func watchAIChatPanelURLs(of chats: [String: Tab]) {
        let live = Set(chats.values.map(ObjectIdentifier.init))
        for id in aiChatPanelURLWatches.keys where !live.contains(id) {
            aiChatPanelURLWatches[id] = nil
        }
        for (identifier, chat) in chats where aiChatPanelURLWatches[ObjectIdentifier(chat)] == nil {
            aiChatPanelURLWatches[ObjectIdentifier(chat)] = chat.$url
                .sink { [weak self, weak chat] url in
                    guard let self, let chat else { return }
                    // `aiChatTabs` publishes before it stores, so a panel that
                    // just appeared is found under the key it arrived with.
                    let key = self.aiChatTabs.first(where: { $0.value === chat })?.key ?? identifier
                    guard let owner = self.tab(forChatIdentifier: key) else { return }
                    self.pushAIChatPanelRecord(of: owner, panelURL: url)
                    // Before the panel existed, the other pane of a split
                    // resolved to itself and may have pushed a record.
                    if let partnerId = self.splitGroup(forTabId: owner.guid)?.partnerTabId(of: owner.guid),
                       let partner = self.tabs.first(where: { $0.guid == partnerId }),
                       self.aiChatTabs[self.getTabIdentifier(for: partner)] == nil {
                        self.sendAIChatPanelRecord(nil, of: partner)
                    }
                }
            // The panel exists now; its URL names the conversation from here on.
            pendingAIChatConversations[identifier] = nil
        }
    }

    /// Recomputes the panel record of the page tab `tab` and hands it to
    /// Chromium when it differs from the last one. `isExpanded` and
    /// `panelURL` carry values about to be stored: `@Published` publishes
    /// before it stores, so the tab and its panel still read the old ones.
    private func pushAIChatPanelRecord(of tab: Tab, isExpanded: Bool? = nil, panelURL: String? = nil) {
        let identifier = getTabIdentifier(for: tab)
        var record: AIChatPanelRecord?
        // In a split the record stays with the pane that holds the panel.
        if chatIdentifier(for: tab) == identifier {
            let url = panelURL ?? aiChatTabs[identifier]?.url
            // Once the panel exists its URL decides, even when it names none.
            let conversationId = url.map { AIChatPanelRecord.conversationId(fromPanelURL: $0) }
                ?? pendingAIChatConversations[identifier]
            record = AIChatPanelRecord(isExpanded: isExpanded ?? !tab.aiChatCollapsed,
                                       conversationId: conversationId)
        }
        sendAIChatPanelRecord(record, of: tab)
    }

    /// Hands `record` to Chromium as the page tab `tab`'s, unless it is the
    /// one handed over last.
    private func sendAIChatPanelRecord(_ record: AIChatPanelRecord?, of tab: Tab) {
        guard record != aiChatPanelRecordsPushed[tab.guid] else { return }
        aiChatPanelRecordsPushed[tab.guid] = record
        AppLogInfo("[AIChat] panel record tabId=\(tab.guid) record=\(record?.encoded ?? "none")")
        aiChatPanelBridge.setAIChatPanelRecord(record?.encoded, forTabId: tab.guid)
    }

    /// Chromium is about to remove the tab `tabId`, closing it or moving it to
    /// another window. It writes a closed tab's recently-closed entry as soon
    /// as this returns, before this window's `closeTab` runs, so the bridge
    /// callback calls this directly rather than through EventBus. Only a split
    /// pane has anything to do here: it is noted as leaving, and its panel
    /// record is handed over (`handOffAIChatPanelRecord`).
    func splitPaneWillBeRemoved(_ tabId: Int) {
        guard let tab = tabs.first(where: { $0.guid == tabId }),
              splitGroup(forTabId: tabId) != nil else { return }
        splitPaneIdsBeingRemoved.insert(tabId)
        handOffAIChatPanelRecord(of: tab)
    }

    /// When `tab` holds its split's panel and the other pane stays, `closeTab`
    /// hands the panel to that pane, and the record goes along: cleared on
    /// `tab`, set on the other pane. Pushed before Chromium writes `tab`'s
    /// closed entry, so undo close does not bring a second panel back. A pane
    /// Chromium is removing as well does not stay: when both panes close, the
    /// record stays with the one that closes last.
    func handOffAIChatPanelRecord(of tab: Tab) {
        guard let panel = aiChatTabs[getTabIdentifier(for: tab)],
              let partnerId = splitGroup(forTabId: tab.guid)?.partnerTabId(of: tab.guid),
              !splitPaneIdsBeingRemoved.contains(partnerId),
              let partner = tabs.first(where: { $0.guid == partnerId }) else { return }
        sendAIChatPanelRecord(nil, of: tab)
        sendAIChatPanelRecord(
            AIChatPanelRecord(isExpanded: !partner.aiChatCollapsed,
                              conversationId: AIChatPanelRecord.conversationId(fromPanelURL: panel.url)),
            of: partner)
    }

    /// `reconcileSplitChatBinding` closed `tab`'s panel as its split formed
    /// and kept the other pane's. The record goes with the closed panel, so
    /// undo close of `tab` does not bring that panel back.
    func splitPaneLostAIChatPanel(_ tab: Tab) {
        sendAIChatPanelRecord(nil, of: tab)
    }

    /// A tab undo close brought back arrived with the panel it had when it
    /// was closed, and its panel shows the same conversation once created.
    /// An expanded panel comes back expanded; the current tab asks for its
    /// panel tab right away, so the chat finds it already there and leaves
    /// focus on the page. A collapsed one stays collapsed until the user
    /// expands it. With the AI switch off, or in guest mode, the panel does
    /// not come back and the record is cleared in Chromium, so it does not
    /// come back later either.
    func restoreAIChatPanel(of tab: Tab, isActiveAtCreation: Bool) {
        guard let record = tab.restoredAIChatPanel else { return }
        tab.restoredAIChatPanel = nil
        let isAIEnabled = PhiPreferences.AISettings.phiAIEnabled.loadValue()
        let isGuest = guestModeOverrideForTesting ?? ApplicationState.shared.isGuest
        guard isAIEnabled, !isGuest else {
            AppLogInfo("[AIChat] dropped panel record tabId=\(tab.guid) aiEnabled=\(isAIEnabled) guest=\(isGuest)")
            aiChatPanelBridge.setAIChatPanelRecord(nil, forTabId: tab.guid)
            return
        }
        AppLogInfo("[AIChat] restored panel tabId=\(tab.guid) record=\(record.encoded) active=\(isActiveAtCreation)")
        // Pushing it back ends Chromium's hand-back, so moving the tab to
        // another window and back does not bring the panel again.
        aiChatPanelRecordsPushed[tab.guid] = record
        aiChatPanelBridge.setAIChatPanelRecord(record.encoded, forTabId: tab.guid)
        if let conversationId = record.conversationId {
            pendingAIChatConversations[getTabIdentifier(for: tab)] = conversationId
        }
        guard record.isExpanded else { return }
        setAIChatCollapsed(for: tab, collapsed: false)
        guard isActiveAtCreation, !tab.aiChatCollapsed else { return }
        createAIChatTab(for: chatIdentifier(for: tab), chromeTabId: tab.guid)
    }

    /// The AI switch turned off and every panel tab is gone: no page tab
    /// keeps a record or a conversation waiting for its panel tab, so undo
    /// close brings no panel back. Every tab is cleared, not only the ones
    /// pushed from here, since a tab moved in from another window carries
    /// its record along.
    func clearAIChatPanelRecords() {
        pendingAIChatConversations.removeAll()
        aiChatPanelRecordsPushed.removeAll()
        AppLogInfo("[AIChat] cleared panel records of \(tabs.count) tabs")
        for tab in tabs {
            aiChatPanelBridge.setAIChatPanelRecord(nil, forTabId: tab.guid)
        }
    }
}
