// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import Foundation

struct BrowserRestoreState: Codable {
    static let currentVersion = 2
    
    let version: Int
    let windows: [BrowserRestoreWindowState]
    let savedAt: Date
}

struct BrowserRestoreWindowState: Codable {
    let browserTypeRawValue: Int
    let profileId: String
    let frame: BrowserRestoreWindowFrame
    let tabs: [BrowserRestoreTabState]
    let selectedIndex: Int?

    init(browserTypeRawValue: Int,
         profileId: String,
         frame: BrowserRestoreWindowFrame,
         tabs: [BrowserRestoreTabState],
         selectedIndex: Int?) {
        self.browserTypeRawValue = browserTypeRawValue
        self.profileId = profileId
        self.frame = frame
        self.tabs = tabs
        self.selectedIndex = selectedIndex
    }

    private enum CodingKeys: String, CodingKey {
        case browserTypeRawValue
        case profileId
        case frame
        case tabs
        case selectedIndex
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        browserTypeRawValue = try container.decode(Int.self, forKey: .browserTypeRawValue)
        profileId = try container.decodeIfPresent(String.self, forKey: .profileId) ?? LocalStore.defaultProfileId
        frame = try container.decode(BrowserRestoreWindowFrame.self, forKey: .frame)
        tabs = try container.decode([BrowserRestoreTabState].self, forKey: .tabs)
        selectedIndex = try container.decodeIfPresent(Int.self, forKey: .selectedIndex)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(browserTypeRawValue, forKey: .browserTypeRawValue)
        try container.encode(profileId, forKey: .profileId)
        try container.encode(frame, forKey: .frame)
        try container.encode(tabs, forKey: .tabs)
        try container.encodeIfPresent(selectedIndex, forKey: .selectedIndex)
    }
}

struct BrowserRestoreTabState: Codable {
    let url: String
    let customGuid: String?
}

struct BrowserRestoreWindowFrame: Codable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

extension BrowserRestoreWindowFrame {
    init(frame: NSRect) {
        self.x = frame.origin.x
        self.y = frame.origin.y
        self.width = frame.size.width
        self.height = frame.size.height
    }
    
    var rect: NSRect {
        NSRect(x: x, y: y, width: width, height: height)
    }
}
