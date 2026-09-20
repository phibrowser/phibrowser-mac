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
            if let homepage = list.homepage {
                Link(NSLocalizedString("settings.privacy.contentBlocking.listInfo.source", value: "Source", comment: "Advanced ad block settings - Link label pointing at a filter list's home page"),
                     destination: homepage)
                    .font(.system(size: 12))
            }
            if !list.license.isEmpty {
                Text(String(format: NSLocalizedString("settings.privacy.contentBlocking.listInfo.license", value: "License: %@", comment: "Advanced ad block settings - License line in a filter list's details; %@ is the license name"), list.license))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(width: 280, alignment: .leading)
    }
}
