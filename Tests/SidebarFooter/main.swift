// Copyright 2026 Phinomenon Inc.
import AppKit
import SwiftUI

@main
struct FooterTests {
    @MainActor static func main() {
        setbuf(stdout, nil)
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let state = SidebarBottomBarState()
        let cards = NotificationCardManager()
        let root = SidebarBottomBarSwiftUI(state: state, downloadViewModel: DownloadButtonViewModel(),
            cardManager: cards, onFeedbackTap: {}, onBookmarkTap: {},
            onChatTap: {}, onCardEntryTap: {}, onMemoryTap: {}, onDownloadTap: {})
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 193, height: 24),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Phi Sidebar Footer Fixture"
        var cases = 0
        for width: CGFloat in [193, 217, 218, 260, 500] {
            for mask in 0..<16 {
                state.isMemoryHidden = mask & 1 != 0
                state.isFeedbackHidden = mask & 2 != 0
                state.isChatHidden = mask & 4 != 0
                cards.latestCard = mask & 8 != 0 ? nil : 1
                Probe.frames = [:]
                let host = NSHostingView(rootView: root)
                host.sizingOptions = []
                window.contentView = host
                window.setContentSize(NSSize(width: width, height: 24))
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
                let frames = Probe.frames
                let expectedCount = 2 + (state.isMemoryHidden ? 0 : 1) + (state.isFeedbackHidden ? 0 : 1)
                    + (state.isChatHidden ? 0 : 1) + (cards.latestCard == nil ? 0 : 1)
                precondition(frames.count == expectedCount, "Missing controls: \(frames)")
                for (name, frame) in frames {
                    precondition(frame.minX >= 8 - 0.01 && frame.maxX <= width - 8 + 0.01,
                                 "\(name) overflows at \(width), mask \(mask): \(frame)")
                    for (otherName, other) in frames where name != otherName {
                        precondition(!frame.intersects(other), "\(name) overlaps \(otherName)")
                    }
                }
                if mask == 0, width == 193 {
                    precondition(frames["chat"]?.width == 24, "Narrow footer must use icon-only Chat")
                    print("193pt all controls: \(frames)")
                }
                if mask == 0, width >= 260 {
                    precondition(frames["chat"]!.width > 24, "Wide footer must retain the localized Chat title")
                }
                cases += 1
            }
        }
        state.isMemoryHidden = false
        state.isFeedbackHidden = false
        state.isChatHidden = false
        cards.latestCard = 1
        let liveHost = NSHostingView(rootView: root)
        liveHost.sizingOptions = []
        window.contentView = liveHost
        for width: CGFloat in [193, 260, 193] {
            window.setContentSize(NSSize(width: width, height: 24))
            liveHost.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03))
            precondition(width == 193 ? Probe.frames["chat"]?.width == 24 : Probe.frames["chat"]!.width > 24,
                         "Chat must adapt while the same host is resized")
        }
        let fiveEntryWidth = ChatButton.preferredContentWidth + 132
        window.setContentSize(NSSize(width: fiveEntryWidth, height: 24))
        for hasCard in [false, true, false] {
            cards.latestCard = hasCard ? 1 : nil
            liveHost.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03))
            precondition(hasCard ? Probe.frames["chat"]?.width == 24 : Probe.frames["chat"]!.width > 24,
                         "Chat must adapt when a notification entry appears or disappears")
        }
        print("PASS: \(cases) rendered layouts plus live resize/card updates; title \(NSLocalizedString("sidebar.chatButton.title", comment: "")); language \(Locale.preferredLanguages.first ?? "unknown")")
        if CommandLine.arguments.contains("--preview") {
            state.isMemoryHidden = false
            state.isFeedbackHidden = false
            state.isChatHidden = false
            cards.latestCard = 1
            window.contentView = NSHostingView(rootView: VStack(alignment: .leading, spacing: 20) {
                Text("Sidebar footer · all six entries").font(.headline)
                Text("193 pt · compact Chat")
                root.frame(width: 193, height: 24).border(Color.gray.opacity(0.4))
                Text("260 pt · full Chat title")
                root.frame(width: 260, height: 24).border(Color.gray.opacity(0.4))
                Text("Local fixture · actions disabled").font(.caption).foregroundStyle(.secondary)
            }.padding(24))
            window.setContentSize(NSSize(width: 340, height: 280))
            window.center()
            window.makeKeyAndOrderFront(nil)
            app.activate(ignoringOtherApps: true)
            app.run()
        }
    }
}
