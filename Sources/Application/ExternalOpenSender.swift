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

/// One URL from `application(_:open:)` with the bundle id of the application
/// that sent it. The association is per URL so batches from different
/// senders can coalesce while Phi waits for a window or browser access.
struct ExternalOpenURL {
    let url: URL
    let sourceAppBundleId: String?
}
