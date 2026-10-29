// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import CoreServices

/// The application that asked macOS to open URLs in Phi, read from the Apple
/// event AppKit is dispatching to `application(_:open:)`. App URL rules
/// (`SpaceRoutingRule.sourceAppBundleId`) match against `bundleId`.
///
/// `captureCurrent()` must run synchronously on the main thread inside
/// `application(_:open:)`, before anything else: `currentAppleEvent` is only
/// valid while AppKit dispatches the kAEGetURL / open-documents event.
/// Relayed opens (some sandboxed apps, Shortcuts, the `open` command) may
/// carry no usable sender; the result is then `.none` and App rules do not
/// apply. The frontmost application is never used as a fallback: it is often
/// not the sender. See docs/url-rules.md.
struct ExternalOpenSender: Equatable {
    enum Resolution: String {
        /// From the event's sender process id attribute.
        case senderPID
        /// From the event's original address attribute.
        case originalAddress
        /// No sender could be identified.
        case none
    }

    let bundleId: String?
    let processIdentifier: pid_t?
    let localizedName: String?
    let resolution: Resolution

    static let unresolved = ExternalOpenSender(bundleId: nil, processIdentifier: nil,
                                               localizedName: nil, resolution: .none)

    static func captureCurrent() -> ExternalOpenSender {
        assert(Thread.isMainThread)
        let sender = resolve(NSAppleEventManager.shared().currentAppleEvent)
        if sender.resolution == .none {
            AppLogInfo("[ExternalLinks] sender unresolved")
        } else {
            AppLogInfo(
                "[ExternalLinks] sender resolution=\(sender.resolution.rawValue) "
                    + "pid=\(sender.processIdentifier.map(String.init) ?? "none") "
                    + "bundleId=\(sender.bundleId ?? "none") "
                    + "name=\(sender.localizedName ?? "none")"
            )
        }
        return sender
    }

    /// The application a Kiosk opened from this link returns to on close: the
    /// sender, when it is a running regular app. The frontmost app is no
    /// fallback: macOS has already brought Phi forward when the link arrives.
    func returnApplication() -> NSRunningApplication? {
        guard let processIdentifier,
              let application = NSRunningApplication(processIdentifier: processIdentifier),
              application.activationPolicy == .regular,
              !application.isTerminated else { return nil }
        return application
    }

    private static func resolve(_ event: NSAppleEventDescriptor?) -> ExternalOpenSender {
        guard let event else { return .unresolved }
        let ownBundleId = Bundle.main.bundleIdentifier?.lowercased()
        func isForeign(_ sender: ExternalOpenSender) -> Bool {
            guard let bundleId = sender.bundleId, !bundleId.isEmpty else { return false }
            return bundleId.lowercased() != ownBundleId
        }

        if let pid = event.attributeDescriptor(forKeyword: AEKeyword(keySenderPIDAttr))?.int32Value,
           pid > 0 {
            let sender = runningApplicationSender(pid: pid, resolution: .senderPID)
            if isForeign(sender) { return sender }
        }
        if let address = event.attributeDescriptor(forKeyword: AEKeyword(keyOriginalAddressAttr)),
           let sender = originalAddressSender(address),
           isForeign(sender) {
            return sender
        }
        return .unresolved
    }

    /// The original address may be a kernel process id, a bundle id string,
    /// or another address form (signature, serial number) that is coerced
    /// to a process id when the Apple Event Manager can.
    private static func originalAddressSender(_ address: NSAppleEventDescriptor)
        -> ExternalOpenSender? {
        switch address.descriptorType {
        case DescType(typeApplicationBundleID):
            guard let bundleId = String(data: address.data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters)),
                  !bundleId.isEmpty else { return nil }
            let running = NSRunningApplication
                .runningApplications(withBundleIdentifier: bundleId).first
            return ExternalOpenSender(bundleId: bundleId,
                                      processIdentifier: running?.processIdentifier,
                                      localizedName: running?.localizedName,
                                      resolution: .originalAddress)
        case DescType(typeKernelProcessID):
            guard let pid = pidValue(address) else { return nil }
            return runningApplicationSender(pid: pid, resolution: .originalAddress)
        default:
            guard let coerced = address.coerce(toDescriptorType: DescType(typeKernelProcessID)),
                  let pid = pidValue(coerced) else { return nil }
            return runningApplicationSender(pid: pid, resolution: .originalAddress)
        }
    }

    private static func pidValue(_ descriptor: NSAppleEventDescriptor) -> pid_t? {
        let data = descriptor.data
        guard data.count == MemoryLayout<pid_t>.size else { return nil }
        let pid = data.withUnsafeBytes { $0.loadUnaligned(as: pid_t.self) }
        return pid > 0 ? pid : nil
    }

    private static func runningApplicationSender(pid: pid_t,
                                                 resolution: Resolution) -> ExternalOpenSender {
        let running = NSRunningApplication(processIdentifier: pid)
        return ExternalOpenSender(bundleId: running?.bundleIdentifier,
                                  processIdentifier: pid,
                                  localizedName: running?.localizedName,
                                  resolution: resolution)
    }
}

/// Where an external open came from. Both sources take the one external-open
/// path in `AppController`; `steps` is what tells them apart there.
enum ExternalOpenSource {
    /// macOS handed the URLs over: an Apple event from another application,
    /// or Handoff.
    case system
    /// The Phi Chat app opened them and Chromium handed them over
    /// (`openPhiChatLinks:`, chromium ADR 0019).
    case phiChat

    /// The steps of the external-open path a source takes. The browser-access
    /// gate is not one: every source waits behind it.
    struct Steps: Equatable {
        /// Offered to an in-flight browser sign-in as its callback.
        let resumesBrowserAuthentication: Bool
        /// Offered to `DeeplinkHandler` before it opens as a page.
        let handlesDeeplinks: Bool
        /// Lands after the session restore when every window is closed.
        let restoresWhenWindowless: Bool
        /// Activates Phi first and is forwarded once Phi is active. macOS
        /// activates Phi before it hands over another application's link,
        /// unless that link was opened in the background (`open -g`,
        /// AppleScript `open location` without `activate`, `NSWorkspace.open`
        /// with `activates` false). A Phi Chat link comes from Chromium with
        /// Phi not activated. Chromium picks the profile of the window that
        /// last became main while Phi was active, so this source activates
        /// Phi itself and waits for it before forwarding.
        let activatesPhi: Bool
    }

    /// Pure, so it is pinned by table (`ExternalOpenSourceTests`). Page
    /// content chooses a Phi Chat link, so it never acts as one of Phi's own
    /// URLs: no sign-in callback, no deeplink. That row is a security boundary.
    var steps: Steps {
        switch self {
        case .system:
            return Steps(resumesBrowserAuthentication: true,
                         handlesDeeplinks: true,
                         restoresWhenWindowless: true,
                         activatesPhi: false)
        case .phiChat:
            return Steps(resumesBrowserAuthentication: false,
                         handlesDeeplinks: false,
                         restoresWhenWindowless: true,
                         activatesPhi: true)
        }
    }
}

/// One URL from an external open, with its source and, for a system open,
/// the bundle id of the application that sent it. The association is per URL
/// so batches from different senders can coalesce while Phi waits for a
/// window or browser access.
struct ExternalOpenURL {
    let url: URL
    let sourceAppBundleId: String?
    let source: ExternalOpenSource
    /// Where a Kiosk this URL opens returns to when it closes
    /// (`KioskBrowserWindowController.returnApplication`).
    var returnApplication: NSRunningApplication? = nil
}

/// Return targets for the Kiosks Chromium opens for external links. A Kiosk
/// claims the entry for the URL its first tab opened: Chromium may create it
/// only after loading the profile, and a link it never turns into a Kiosk
/// must not hand its target to an unrelated one.
struct KioskReturnQueue {
    static let lifetime: TimeInterval = 30

    private var entries: [(pageKey: String, application: NSRunningApplication, deadline: Date)] = []

    mutating func add(_ url: URL, returningTo application: NSRunningApplication,
                      now: Date = Date()) {
        guard let pageKey = Self.pageKey(url) else { return }
        entries.append((pageKey, application, now.addingTimeInterval(Self.lifetime)))
    }

    mutating func claim(forTabURL urlString: String, now: Date = Date()) -> NSRunningApplication? {
        entries.removeAll { $0.deadline < now }
        guard let url = URL(string: urlString),
              let pageKey = Self.pageKey(url),
              let index = entries.firstIndex(where: { $0.pageKey == pageKey }) else {
            return nil
        }
        return entries.remove(at: index).application
    }

    /// The URL as Chromium reports a tab's: lowercase scheme and host, no
    /// default port, and `/` for an empty path.
    static func pageKey(_ url: URL) -> String? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        let scheme = components.scheme?.lowercased()
        components.scheme = scheme
        components.host = components.host?.lowercased()
        if (scheme == "http" && components.port == 80)
            || (scheme == "https" && components.port == 443) {
            components.port = nil
        }
        if components.host != nil, components.path.isEmpty {
            components.path = "/"
        }
        return components.string
    }
}
