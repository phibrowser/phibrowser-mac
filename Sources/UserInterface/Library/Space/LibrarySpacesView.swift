// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import SwiftUI

struct LibrarySpacesView: View {
    let browserState: BrowserState
    @ObservedObject private var manager = SpaceManager.shared
    @Environment(\.phiAppearance) private var appearance
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var orderedIDs: [String] = []
    @State private var draggingID: String?
    @State private var dragOriginIndex = 0
    @State private var dragTranslation: CGFloat = 0
    @State private var isCreating = false
    @State private var creationTheme: Theme?
    @State private var themeRevision = 0
    @State private var pendingCreatedID: String?
    private static let cardWidth: CGFloat = 240
    private static let creationID = "library.create-space"

    private var spaces: [Space] {
        manager.spaces.filter { !$0.isAgentSpace && !SpaceManager.isIncognitoSpaceId($0.spaceId) }
    }

    private var orderedSpaces: [Space] {
        let byID = Dictionary(uniqueKeysWithValues: spaces.map { ($0.spaceId, $0) })
        let known = Set(orderedIDs)
        return orderedIDs.compactMap { byID[$0] } + spaces.filter { !known.contains($0.spaceId) }
    }

    var body: some View {
        ScrollViewReader { proxy in
            GeometryReader { geometry in
                ScrollView(.horizontal) {
                    HStack(spacing: 22) {
                        ForEach(orderedSpaces) { space in
                            if let store = AccountController.shared.localDataAccount?.localStorage,
                               store.identifier == space.storeIdentifier {
                                card(space, store: store)
                                    .id(space.spaceId)
                            }
                        }
                        if isCreating {
                            creationCard
                                .id(Self.creationID)
                        }
                        Button {
                            AppLogInfo("[LibrarySpaces] create.open count=\(spaces.count)")
                            creationTheme = browserState.themeContext.currentTheme
                            isCreating = true
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 23, weight: .medium))
                                .frame(width: 48, height: 48)
                                .background(.thinMaterial, in: .circle)
                                .contentShape(.circle)
                        }
                        .buttonStyle(.plain)
                        .disabled(isCreating)
                        .help(NSLocalizedString("library.spaces.create", value: "New Space", comment: "Library Spaces - add card button"))
                        .accessibilityLabel(NSLocalizedString("library.spaces.create", value: "New Space", comment: "Library Spaces - add card button"))
                    }
                    .padding(12)
                    .frame(height: max(0, geometry.size.height - 14))
                }

            }
            .onChange(of: isCreating) { _, creating in
                if creating { scroll(proxy, to: Self.creationID) }
            }
            .onChange(of: spaces.map(\.spaceId)) { _, ids in
                AppLogInfo("[LibrarySpaces] order.received ids=\(ids) preview=\(orderedIDs) dragging=\(draggingID ?? "none")")
                // A changed collection invalidates any in-flight reorder snapshot.
                draggingID = nil
                orderedIDs = ids
                if let id = pendingCreatedID, ids.contains(id) {
                    pendingCreatedID = nil
                    scroll(proxy, to: id)
                }
            }
            .onChange(of: pendingCreatedID) { _, id in
                if let id, spaces.contains(where: { $0.spaceId == id }) {
                    pendingCreatedID = nil
                    scroll(proxy, to: id)
                }
            }
        }
        .onAppear {
            orderedIDs = spaces.map(\.spaceId)
            AppLogInfo("[LibrarySpaces] appear store=\(manager.storeIdentifier?.uuidString ?? "none") ids=\(orderedIDs)")
        }
        .onDisappear {
            AppLogInfo("[LibrarySpaces] disappear dragging=\(draggingID ?? "none")")
            draggingID = nil
            orderedIDs = spaces.map(\.spaceId)
        }
        .onChange(of: manager.storeIdentifier) { _, _ in
            AppLogInfo("[LibrarySpaces] store.changed store=\(manager.storeIdentifier?.uuidString ?? "none")")
            draggingID = nil
            orderedIDs = spaces.map(\.spaceId)
            isCreating = false
            pendingCreatedID = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: .spaceThemeDidChange)) { _ in themeRevision += 1 }
        .onReceive(NotificationCenter.default.publisher(for: .themeDidChange)) { _ in themeRevision += 1 }
    }

    func card(_ space: Space, store: LocalStore) -> some View {
        let _ = themeRevision
        let theme = manager.resolvedTheme(forSpaceId: space.spaceId)
        return LibrarySpaceCard(space: space, store: store, manager: manager, onDragBegin: {
            orderedIDs = spaces.map(\.spaceId)
            dragOriginIndex = orderedIDs.firstIndex(of: space.spaceId) ?? 0
            dragTranslation = 0
            draggingID = space.spaceId
            AppLogInfo("[LibrarySpaces] drag.begin space=\(space.spaceId) index=\(dragOriginIndex) ids=\(orderedIDs)")
        }, onDragMove: { delta in
            guard draggingID == space.spaceId else { return }
            dragTranslation = delta
            let target = min(max(0, Int((CGFloat(dragOriginIndex) + delta / (Self.cardWidth + 22)).rounded())), orderedIDs.count - 1)
            guard let current = orderedIDs.firstIndex(of: space.spaceId), target != current else { return }
            AppLogInfo("[LibrarySpaces] drag.target space=\(space.spaceId) from=\(current) to=\(target) deltaX=\(delta)")
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) {
                orderedIDs.move(fromOffsets: IndexSet(integer: current), toOffset: target > current ? target + 1 : target)
            }
            NSHapticFeedbackManager.defaultPerformer.perform(
                .alignment, performanceTime: .drawCompleted)
        }, onDragEnd: { didDrop in
            guard draggingID == space.spaceId else {
                AppLogInfo("[LibrarySpaces] drag.endIgnored space=\(space.spaceId) active=\(draggingID ?? "none")")
                return
            }
            draggingID = nil
            dragTranslation = 0
            if didDrop {
                AppLogInfo("[LibrarySpaces] order.commit space=\(space.spaceId) accepted=\(manager.acceptsStoreAction(from: space.storeIdentifier)) ids=\(orderedIDs)")
                manager.reorder(spaceIds: orderedIDs, expectedStoreIdentifier: space.storeIdentifier)
            } else {
                AppLogInfo("[LibrarySpaces] order.cancel space=\(space.spaceId)")
                orderedIDs = spaces.map(\.spaceId)
            }
        })
        // Recreate subscriptions when a Space is reassigned or an account changes.
        .id("\(store.identifier)/\(space.profileId)/\(space.spaceId)")
        .frame(width: Self.cardWidth)
        .frame(maxHeight: .infinity)
        .background(LibrarySpaceBackdrop(theme: theme, appearance: appearance))
        .clipShape(.rect(cornerRadius: 18))
        .shadow(color: .black.opacity(appearance.isDark ? 0.28 : 0.14), radius: 8, y: 4)
        .environment(\.phiTheme, theme)
        .offset(x: draggingID == space.spaceId
                ? dragTranslation + CGFloat(dragOriginIndex - (orderedIDs.firstIndex(of: space.spaceId) ?? dragOriginIndex)) * (Self.cardWidth + 22)
                : 0)
        .zIndex(draggingID == space.spaceId ? 1 : 0)

    }

    private var creationCard: some View {
        let theme = creationTheme ?? browserState.themeContext.currentTheme
        return CreateSpacePanel(style: .library, manager: manager, profileManager: .shared,
                                initialProfileId: browserState.profileId,
                                initialThemeId: browserState.themeContext.currentTheme.id,
                                onClose: { restorePreview in
                                    AppLogInfo("[LibrarySpaces] create.close restorePreview=\(restorePreview)")
                                    isCreating = false
                                },
                                onThemeSelectionChange: { creationTheme = $0 },
                                onCreated: {
                                    AppLogInfo("[LibrarySpaces] create.completed space=\($0)")
                                    pendingCreatedID = $0
                                })
            .frame(width: Self.cardWidth)
            .frame(maxHeight: .infinity)
            .background(LibrarySpaceBackdrop(theme: theme, appearance: appearance))
            .clipShape(.rect(cornerRadius: 18))
            .shadow(color: .black.opacity(appearance.isDark ? 0.28 : 0.14), radius: 8, y: 4)
            .environment(\.phiTheme, theme)
    }

    private func scroll(_ proxy: ScrollViewProxy, to id: String) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
            proxy.scrollTo(id, anchor: .trailing)
        }
    }
}
