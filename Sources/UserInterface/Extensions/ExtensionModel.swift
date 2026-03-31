// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import AppKit

class Extension: ObservableObject, Identifiable {
    let id: String
    let name: String
    let icon: NSImage?
    let version: String
    @Published var isPinned: Bool
    let pinnedIndex: Int
    
    init(from dict: [String: Any]) {
        self.id = dict["id"] as? String ?? ""
        self.name = dict["name"] as? String ?? ""
        self.version = dict["version"] as? String ?? ""
        self.isPinned = dict["isPinned"] as? Bool ?? false
        self.pinnedIndex = dict["pinnedIndex"] as? Int ?? -1
        
        if let iconBase64 = dict["icon"] as? String,
           let image = Self.imageFromBase64(iconBase64) {
            self.icon = image
        } else {
            self.icon = nil
        }
    }
    
    // TODO: Move this into a shared image utility once extension icon handling stabilizes.
    static func imageFromBase64(_ base64String: String) -> NSImage? {
        // Strip optional `data:image/...;base64,` prefixes before decoding.
        let cleanBase64: String
        if let commaIndex = base64String.firstIndex(of: ",") {
            cleanBase64 = String(base64String[base64String.index(after: commaIndex)...])
        } else {
            cleanBase64 = base64String
        }

        guard let imageData = Data(base64Encoded: cleanBase64, options: .ignoreUnknownCharacters) else {
            return nil
        }
        return NSImage(data: imageData)
    }
}

extension Extension: Equatable {
    static func == (lhs: Extension, rhs: Extension) -> Bool {
        return lhs.name == rhs.name &&
        lhs.id == rhs.id &&
        lhs.pinnedIndex == rhs.pinnedIndex &&
        lhs.isPinned == rhs.isPinned
    }
}
