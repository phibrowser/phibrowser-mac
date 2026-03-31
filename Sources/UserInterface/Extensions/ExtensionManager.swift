// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import Combine

class ExtensionManager: ObservableObject {
    @Published var extensions: [Extension] = []
    @Published var pinedExtensions: [Extension] = []
    @Published var phiExtensionVersions: [String: String] = [:]
    @Published var shouldDisplayExtensionsWithinSidebar: Bool = false
    private weak var browserState: BrowserState?
    init(browserState: BrowserState) {
        self.browserState = browserState
    }
    static let phiExtensionIds = ["pjlnhbfabokjejbhmgghmjiaknfhnima",
                                  "pjgdkljlcbjgedgeppodjijjphfcplno",
                                  "fenmfiepnpdlhplemgijlimpbebebljo"]
    
    func extensionChanged(_ info: [[String: Any]]) {
        let mapped = info.compactMap { Extension(from: $0) }
        phiExtensionVersions = Dictionary(uniqueKeysWithValues: mapped
            .filter { Self.phiExtensionIds.contains($0.id) }
            .map { ($0.name, $0.version) }
        )
        
        extensions = mapped
        #if NIGHTLY_BUILD || DEBUG
            .filter { $0.id != "fenmfiepnpdlhplemgijlimpbebebljo" }
        #else
            .filter { !Self.phiExtensionIds.contains($0.id) }
        #endif
            .sorted {
                if $0.isPinned != $1.isPinned {
                    return $0.isPinned && !$1.isPinned
                }
                if $0.isPinned && $1.isPinned {
                    return $0.pinnedIndex < $1.pinnedIndex
                }
                return $0.name < $1.name
            }
        pinedExtensions = extensions.filter { $0.isPinned }.sorted { $0.pinnedIndex < $1.pinnedIndex }
    }
    
    func refreshExtensions() {
        ChromiumLauncher.sharedInstance().bridge?.getAllExtensions(completion: { infos in
            if let typedInfos = infos as? [[String: Any]] {
                self.extensionChanged(typedInfos)
            }
        }, windowId: browserState?.windowId.int64Value ?? 0)
    }
    
    func togglePin(_ model: Extension) {
        if !model.isPinned {
            ChromiumLauncher.sharedInstance().bridge?.pinExtension(withId: model.id, windowId: Int64(browserState?.windowId ?? 0))
        } else {
            ChromiumLauncher.sharedInstance().bridge?.unpinExtension(withId: model.id, windowId: Int64(browserState?.windowId ?? 0))
        }
    }
    
    #if DEBUG
    func loadTestData(itemCount: Int) {
        guard itemCount >= 0 else { return }
        
        let mockData: [[String: Any]]
        if itemCount == 0 {
            mockData = []
        } else {
            mockData = (1...itemCount).map { i -> [String: Any] in
                let shouldPin = i <= min(4, max(1, itemCount / 4))
                return [
                    "id": "test_\(i)",
                    "name": "Test Extension \(i)",
                    "version": "1.0.0",
                    "isPinned": shouldPin,
                    "pinnedIndex": shouldPin ? i : -1
                ]
            }
        }
        extensionChanged(mockData)
    }
    #endif
}

