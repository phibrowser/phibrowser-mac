// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

/// Earlier builds linked a Pi companion extension at
/// `~/.pi/agent/extensions/phi-browser` next to the phi-browser skill. The
/// extension loads `scripts/lib/mirror-pi-bridge.mjs` through the skill link,
/// and current builds ship neither, so a link that outlives its bridge makes
/// Pi report a missing module on every start.
enum PiCompanionExtensionCleanup {
    /// Removes the companion extension link once it can no longer load.
    ///
    /// Only a symlink into a phi-browser skill tree is ever removed; a real
    /// folder or an unrelated link is the user's own. A link whose entry point
    /// and bridge both still resolve belongs to a working older build that is
    /// installed alongside this one, and is left alone.
    static func removeBrokenLink() {
        let fm = FileManager.default
        let agentDirectory = fm.homeDirectoryForCurrentUser
            .appendingPathComponent(".pi/agent", isDirectory: true)
        let link = agentDirectory
            .appendingPathComponent("extensions/phi-browser", isDirectory: true)
        guard let dest = try? fm.destinationOfSymbolicLink(atPath: link.path) else { return }
        let resolved = dest.hasPrefix("/")
            ? dest
            : link.deletingLastPathComponent().appendingPathComponent(dest).path
        guard URL(fileURLWithPath: resolved).standardizedFileURL.path
            .hasSuffix("/phi-browser-skill/extensions/pi") else { return }

        let entryPoint = link.appendingPathComponent("index.ts")
        let bridge = agentDirectory.appendingPathComponent(
            "skills/phi-browser/scripts/lib/mirror-pi-bridge.mjs")
        if fm.fileExists(atPath: entryPoint.path), fm.fileExists(atPath: bridge.path) {
            return
        }
        do {
            try fm.removeItem(at: link)
            AppLogInfo("Removed the leftover Pi companion extension link")
        } catch {
            AppLogWarn("Could not remove the leftover Pi companion extension link: \(error.localizedDescription)")
        }
    }
}
