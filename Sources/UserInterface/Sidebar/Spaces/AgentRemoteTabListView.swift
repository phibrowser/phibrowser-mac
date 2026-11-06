// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import SwiftUI

/// The tab list of an agent Space running on the user's other Mac, drawn
/// with the sidebar's own `SideTabView` rows. Shown in place of this
/// window's tabs while the strip's remote pip is selected. Rows only switch
/// the tab the agent window shows; closing and reordering stay with the host.
struct AgentRemoteTabListView: View {
    @ObservedObject var slot: SpaceWindowSlot
    @ObservedObject private var presence = AgentRemotePresence.shared
    @State private var models: [Int: TabViewModel] = [:]

    var body: some View {
        if let target = slot.remoteMirror, let task = presence.task(for: target) {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(task.tabs, id: \.id) { tab in
                        Button {
                            presence.send(.activateTab(spaceId: target.spaceId, tabId: tab.id),
                                          to: target.peerId)
                        } label: {
                            SideTabView(model: model(for: tab))
                                .frame(height: 36)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(tab.title.isEmpty ? tab.url : tab.title)
                    }
                }
                .padding(.top, 2)
            }
            // Claims the whole band, so clicks never reach the hidden local tabs.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
    }

    private func model(for tab: AgentRemoteTab) -> TabViewModel {
        let model = models[tab.id] ?? TabViewModel()
        // No hover close button: closing stays with the Mac running the agent.
        model.setHoverSuppressed(true)
        model.title = tab.title
        model.url = tab.url
        model.isActive = tab.isActive
        if models[tab.id] == nil {
            DispatchQueue.main.async { models[tab.id] = model }
        }
        return model
    }
}
