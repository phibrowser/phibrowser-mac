// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

enum PhiBuildCapabilities {
    #if PHI_OSS_BUILD
    static let supportsAuthentication = false
    static let supportsAI = false
    #else
    static let supportsAuthentication = true
    static let supportsAI = true
    #endif
}

enum BrowserAccessState: Equatable {
    case loginRequired
    case guest
    case signedIn

    var canUseBrowser: Bool {
        self != .loginRequired
    }

    var isAuthenticated: Bool {
        self == .signedIn
    }
}

final class ApplicationState {
    static let shared = ApplicationState()

    private static let guestModeEnabledKey = "guestModeEnabled"

    private let defaults: UserDefaults
    private let notificationCenter: NotificationCenter
    private let supportsAuthentication: Bool
    private let stateLock = NSLock()
    private var storedBrowserAccessState: BrowserAccessState
    /// In-memory fence spanning authenticated-account publication and Native
    /// controller rebinding. It deliberately is not persisted: on a relaunch,
    /// a fully published authenticated account must outrank a stale Guest
    /// marker, while a staged account that was never published remains Guest.
    private var guestAccountPromotionInProgress = false
    /// Synchronous launch fence for an interrupted Guest migration. The
    /// persisted state remains Guest, but browser access and local-data binding
    /// stay suspended until the identity-bound journal has been resumed.
    private var guestMigrationRecoveryInProgress = false

    var browserAccessState: BrowserAccessState {
        stateLock.lock()
        defer { stateLock.unlock() }
        return storedBrowserAccessState
    }

    var isGuest: Bool {
        browserAccessState == .guest
    }

    var canUseBrowser: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return storedBrowserAccessState.canUseBrowser
            && !guestMigrationRecoveryInProgress
    }

    var isAuthenticated: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return storedBrowserAccessState.isAuthenticated
            && !guestAccountPromotionInProgress
            && !guestMigrationRecoveryInProgress
    }

    var isGuestAccountPromotionInProgress: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return guestAccountPromotionInProgress
    }

    var isGuestMigrationRecoveryInProgress: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return guestMigrationRecoveryInProgress
    }

    init(
        defaults: UserDefaults = .standard,
        notificationCenter: NotificationCenter = .default,
        supportsAuthentication: Bool = PhiBuildCapabilities.supportsAuthentication
    ) {
        self.defaults = defaults
        self.notificationCenter = notificationCenter
        self.supportsAuthentication = supportsAuthentication
        if supportsAuthentication {
            storedBrowserAccessState = defaults.bool(forKey: Self.guestModeEnabledKey)
                ? .guest
                : .loginRequired
        } else {
            storedBrowserAccessState = .guest
            defaults.set(true, forKey: Self.guestModeEnabledKey)
        }
    }

    /// Resolves the synchronous launch state before Chromium asks whether its
    /// browser UI may be shown. A persisted Guest choice stays active while a
    /// login is staged but onboarding or local-data migration is incomplete.
    func resolveInitialAccess(
        isAuthenticationBlocked: Bool,
        hasRecoverableLoginSession: Bool,
        isAuthenticated: Bool
    ) {
        guard supportsAuthentication else {
            transition(
                to: .guest,
                persistedGuestChoice: true,
                guestPromotionInProgress: false,
                guestMigrationRecoveryInProgress: false
            )
            return
        }

        let transitionSnapshot = guestTransitionSnapshot()
        if isAuthenticationBlocked && persistedGuestChoice {
            // The fence blocks authenticated access, not local browsing. A
            // Guest choice that survives to here was made after the deletion
            // armed the fence — the deletion drops any earlier one as it arms
            // — so it is an ordinary choice and must outlive a relaunch like
            // any other. Clearing it on every fenced launch would strand the
            // user on the login gate with no way to get past it.
            transition(to: .guest)
        } else if isAuthenticationBlocked {
            transition(
                to: .loginRequired,
                persistedGuestChoice: false,
                guestPromotionInProgress: false,
                guestMigrationRecoveryInProgress: false
            )
        } else if transitionSnapshot.isRecovering && persistedGuestChoice {
            // Keep the durable Guest identity while temporarily withholding
            // browser/local-store access. This branch must outrank a recovered
            // credential until the journal has been resumed.
            transition(to: .guest)
        } else if transitionSnapshot.isPromoting && persistedGuestChoice {
            // Account publication can synchronously trigger Chromium and app
            // observers. Keep those automatic probes from committing the
            // promotion or exposing authenticated capabilities before Native
            // controllers and the source directory have committed.
            transition(to: .guest)
        } else if isAuthenticated {
            transition(
                to: .signedIn,
                persistedGuestChoice: false,
                guestPromotionInProgress: false,
                guestMigrationRecoveryInProgress: false
            )
        } else if persistedGuestChoice {
            transition(to: .guest)
        } else if hasRecoverableLoginSession {
            transition(to: .loginRequired)
        } else {
            transition(to: .loginRequired)
        }
    }

    /// Enters the explicit, persistent local-access mode selected by the user.
    func enterGuestMode() {
        transition(
            to: .guest,
            persistedGuestChoice: true,
            guestPromotionInProgress: false,
            guestMigrationRecoveryInProgress: false
        )
    }

    /// Persists the user's attempted Guest entry while withholding browser and
    /// local-store access in the same state transition. This avoids a transient
    /// writable Guest binding when a pending migration journal requires the
    /// original target account to recover first.
    func enterGuestMigrationRecovery() {
        transition(
            to: .guest,
            persistedGuestChoice: true,
            guestPromotionInProgress: false,
            guestMigrationRecoveryInProgress: true
        )
    }

    /// Suspends Guest browser access before Chromium can create a window or
    /// open the default-account store for an interrupted migration.
    @discardableResult
    func beginGuestMigrationRecovery(
        notifyBrowserAccessChange: Bool = true
    ) -> Bool {
        guard supportsAuthentication else { return false }
        stateLock.lock()
        guard storedBrowserAccessState == .guest,
              defaults.bool(forKey: Self.guestModeEnabledKey) else {
            stateLock.unlock()
            return false
        }
        let didChange = !guestMigrationRecoveryInProgress
        guestMigrationRecoveryInProgress = true
        stateLock.unlock()

        if didChange && notifyBrowserAccessChange {
            notificationCenter.post(
                name: .browserAccessStateDidChange,
                object: self
            )
        }
        return true
    }

    /// Restores ordinary Guest access when recovery stops before account
    /// publication and the source directory remains authoritative.
    func endGuestMigrationRecovery() {
        stateLock.lock()
        let didChange = guestMigrationRecoveryInProgress
        guestMigrationRecoveryInProgress = false
        stateLock.unlock()

        if didChange {
            notificationCenter.post(
                name: .browserAccessStateDidChange,
                object: self
            )
        }
    }

    /// Arms the deterministic publication fence before a migrated account is
    /// assigned to `AccountController.account`.
    ///
    /// Returns false outside Guest Mode so callers cannot accidentally fence a
    /// regular login or account refresh.
    @discardableResult
    func beginGuestAccountPromotion() -> Bool {
        guard supportsAuthentication else { return false }
        stateLock.lock()
        defer { stateLock.unlock() }
        guard storedBrowserAccessState == .guest,
              defaults.bool(forKey: Self.guestModeEnabledKey) else {
            return false
        }
        guestAccountPromotionInProgress = true
        return true
    }

    /// Cancels a promotion that failed before authenticated account
    /// publication. Guest access and its persisted marker remain unchanged.
    func cancelGuestAccountPromotion() {
        stateLock.lock()
        guestAccountPromotionInProgress = false
        stateLock.unlock()
    }

    /// Releases the launch recovery gate only after the target account has
    /// been published behind the promotion fence. Browser controllers may now
    /// bind to target local data, while authenticated APIs remain unavailable
    /// until `markSignedIn()` commits the transaction.
    @discardableResult
    func resumeBrowserAccessForGuestAccountPromotion() -> Bool {
        guard supportsAuthentication else { return false }
        stateLock.lock()
        guard storedBrowserAccessState == .guest,
              guestAccountPromotionInProgress,
              defaults.bool(forKey: Self.guestModeEnabledKey) else {
            stateLock.unlock()
            return false
        }
        let didChange = guestMigrationRecoveryInProgress
        guestMigrationRecoveryInProgress = false
        stateLock.unlock()

        if didChange {
            notificationCenter.post(
                name: .browserAccessStateDidChange,
                object: self
            )
        }
        return true
    }

    /// Marks completed account onboarding and Guest-data cleanup as ready for
    /// authenticated browser capabilities.
    func markSignedIn() {
        transition(
            to: .signedIn,
            persistedGuestChoice: false,
            guestPromotionInProgress: false,
            guestMigrationRecoveryInProgress: false
        )
    }

    /// Returns the app to the login gate after logout, destructive auth flows,
    /// or unrecoverable session loss. These paths must never silently fall back
    /// to a Guest choice from an earlier session.
    func requireLogin() {
        transition(
            to: .loginRequired,
            persistedGuestChoice: false,
            guestPromotionInProgress: false,
            guestMigrationRecoveryInProgress: false
        )
    }

    /// Drops the persisted Guest choice without touching browser access or
    /// notifying observers. The account deletion calls this while arming its
    /// durable credential fence, so a Guest choice made before the deletion
    /// cannot outlive it even when the finalize crashes before the local-data
    /// removal drops the whole preferences domain.
    func clearPersistedGuestChoice() {
        stateLock.lock()
        defaults.set(!supportsAuthentication, forKey: Self.guestModeEnabledKey)
        stateLock.unlock()
    }

    private var persistedGuestChoice: Bool {
        defaults.bool(forKey: Self.guestModeEnabledKey)
    }

    private func transition(
        to newState: BrowserAccessState,
        persistedGuestChoice: Bool? = nil,
        guestPromotionInProgress: Bool? = nil,
        guestMigrationRecoveryInProgress: Bool? = nil
    ) {
        stateLock.lock()
        let effectiveState = supportsAuthentication ? newState : .guest
        if supportsAuthentication {
            if let persistedGuestChoice {
                defaults.set(persistedGuestChoice, forKey: Self.guestModeEnabledKey)
            }
            if let guestPromotionInProgress {
                self.guestAccountPromotionInProgress = guestPromotionInProgress
            }
        } else {
            defaults.set(true, forKey: Self.guestModeEnabledKey)
            self.guestAccountPromotionInProgress = false
        }
        let oldRecoveryState = self.guestMigrationRecoveryInProgress
        if !supportsAuthentication {
            self.guestMigrationRecoveryInProgress = false
        } else if let guestMigrationRecoveryInProgress {
            self.guestMigrationRecoveryInProgress =
                guestMigrationRecoveryInProgress
        }
        let didChange = storedBrowserAccessState != effectiveState
            || oldRecoveryState != self.guestMigrationRecoveryInProgress
        storedBrowserAccessState = effectiveState
        stateLock.unlock()

        guard didChange else { return }
        notificationCenter.post(name: .browserAccessStateDidChange, object: self)
    }

    private func guestTransitionSnapshot() -> (
        state: BrowserAccessState,
        isPromoting: Bool,
        isRecovering: Bool
    ) {
        stateLock.lock()
        defer { stateLock.unlock() }
        return (
            storedBrowserAccessState,
            guestAccountPromotionInProgress,
            guestMigrationRecoveryInProgress
        )
    }
}

extension Notification.Name {
    static let browserAccessStateDidChange = Notification.Name(
        "BrowserAccessStateDidChange"
    )
}
