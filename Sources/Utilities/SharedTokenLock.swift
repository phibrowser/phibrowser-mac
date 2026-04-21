// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

final class SharedTokenLock {
    static let shared = SharedTokenLock()

    private let lockURL: URL = {
        guard let groupURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.phibrowser.shared"
        ) else {
            fatalError("App Group 'group.com.phibrowser.shared' is not configured in entitlements")
        }
        #if NIGHTLY_BUILD
        let filename = ".token-renew-canary.lock"
        #else
        let filename = ".token-renew.lock"
        #endif
        return groupURL.appendingPathComponent(filename)
    }()

    private var fd: Int32 = -1
    private let queue = DispatchQueue(label: "com.phibrowser.shared-token-lock")

    private init() {}

    func tryLock() -> Bool {
        queue.sync {
            guard fd == -1 else { return false }
            let newFD = openLockFD()
            guard newFD >= 0 else { return false }
            if flock(newFD, LOCK_EX | LOCK_NB) == 0 {
                fd = newFD
                return true
            }
            close(newFD)
            return false
        }
    }

    /// Busy-waits with exponential backoff. The usleep loop runs outside the
    /// serial queue so that tryLock/unlock from other threads are not blocked.
    func lockWithTimeout(_ timeout: TimeInterval) -> Bool {
        let newFD: Int32 = queue.sync {
            guard fd == -1 else { return -2 }
            return openLockFD()
        }
        guard newFD >= 0 else { return false }

        let deadline = Date().addingTimeInterval(timeout)
        var interval: useconds_t = 50_000
        while Date() < deadline {
            if flock(newFD, LOCK_EX | LOCK_NB) == 0 {
                queue.sync { fd = newFD }
                return true
            }
            usleep(interval)
            interval = min(interval * 2, 500_000)
        }
        close(newFD)
        return false
    }

    func unlock() {
        queue.sync {
            guard fd >= 0 else { return }
            flock(fd, LOCK_UN)
            close(fd)
            fd = -1
        }
    }

    private func openLockFD() -> Int32 {
        open(lockURL.path, O_RDWR | O_CREAT, 0o644)
    }
}
