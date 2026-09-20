// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import SwiftUI

/// Details of one filter list: description, source link and license.
struct ContentBlockingListInfoPopover: View {
    let list: ContentBlockingList

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(list.title)
                .font(.system(size: 13, weight: .semibold))
            if !list.description.isEmpty {
                Text(list.description)
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let sourceURL = list.sourceURL {
                Text(sourceURL.absoluteString)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            if let homepage = list.homepage {
                Link(NSLocalizedString("settings.privacy.contentBlocking.listInfo.source", value: "Source", comment: "Advanced ad block settings - Link label pointing at a filter list's home page"),
                     destination: homepage)
                    .font(.system(size: 12))
            }
            Text(Self.updateLine(for: list, now: Date()))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            if !list.license.isEmpty {
                Text(String(format: NSLocalizedString("settings.privacy.contentBlocking.listInfo.license", value: "License: %@", comment: "Advanced ad block settings - License line in a filter list's details; %@ is the license name"), list.license))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(width: 280, alignment: .leading)
    }

    /// "Updated 3 hours ago", "Not downloaded yet" or the last error.
    static func updateLine(for list: ContentBlockingList, now: Date) -> String {
        if !list.available {
            if list.lastError.isEmpty {
                return NSLocalizedString("settings.privacy.contentBlocking.listInfo.notDownloaded", value: "Not downloaded yet", comment: "Advanced ad block settings - Details line for a filter list that has not been downloaded")
            }
            return String(format: NSLocalizedString("settings.privacy.contentBlocking.list.downloadFailed", value: "Not downloaded: %@", comment: "Advanced ad block settings - Line under a filter list whose download failed; %@ is the error"), list.lastError)
        }
        guard let fetchedAt = list.fetchedAt else {
            return NSLocalizedString("settings.privacy.contentBlocking.listInfo.builtIn", value: "Built into Phi", comment: "Advanced ad block settings - Details line for a filter list shipped with the browser")
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        let relative = formatter.localizedString(for: fetchedAt, relativeTo: now)
        return String(format: NSLocalizedString("settings.privacy.contentBlocking.listInfo.updated", value: "Updated %@", comment: "Advanced ad block settings - Details line with when a filter list was last downloaded; %@ is a relative time like '3 hours ago'"), relative)
    }
}
