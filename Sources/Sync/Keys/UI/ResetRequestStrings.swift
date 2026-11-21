// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

/// The user-facing copy for starting sync over from a Mac that is not set up for sync
/// (docs/sync.md, "Starting over from a Mac that is not set up for sync"). The setup window's
/// pages and the Settings → Sync row both read it, so the two never describe the request
/// differently.
enum ResetRequestStrings {
    // MARK: Join method page

    static let joinMethodChoice = NSLocalizedString("sync.resetRequest.joinMethod.startOver",
        value: "Start over without the old data",
        comment: "Sync setup - third option on the page that asks how this Mac joins the account, shown when the account exists but no Mac can approve this one; opens the explanation of deleting the account's sync data")

    // MARK: Explanation page

    static let explanationTitle = NSLocalizedString("sync.resetRequest.explanation.title",
        value: "Start over without the old data?",
        comment: "Sync setup - title of the page that explains deleting the account's sync data so sync can start over from this Mac")

    /// The five statements of the explanation page, in the order the design requires.
    static let explanationStatements: [String] = [
        NSLocalizedString("sync.resetRequest.explanation.dataDeleted",
            value: "The data stored for this account on the sync server will be deleted. It can’t be recovered.",
            comment: "Sync setup - start over explanation, first statement: what is deleted and that it is permanent"),
        NSLocalizedString("sync.resetRequest.explanation.inactivity",
            value: "This is only possible when every Mac set up for sync has been unused for 30 days.",
            comment: "Sync setup - start over explanation, second statement: the inactivity condition"),
        NSLocalizedString("sync.resetRequest.explanation.signIn",
            value: "You’ll sign in again to confirm it’s you.",
            comment: "Sync setup - start over explanation, third statement: a fresh sign-in is required"),
        NSLocalizedString("sync.resetRequest.explanation.delay",
            value: "The data is deleted 48 hours after you ask.",
            comment: "Sync setup - start over explanation, fourth statement: the waiting period before deletion"),
        NSLocalizedString("sync.resetRequest.explanation.otherMacsAsked",
            value: "If a Mac set up for sync comes online before then, it’s asked whether this was you.",
            comment: "Sync setup - start over explanation, fifth statement: other Macs are asked first"),
    ]

    static let explanationLearnMore = NSLocalizedString("sync.resetRequest.explanation.learnMore",
        value: "Learn more",
        comment: "Sync setup - link on the start over explanation page; opens the Help Center article about starting over without the old data")

    static let explanationContinue = NSLocalizedString("sync.resetRequest.explanation.continue",
        value: "Continue",
        comment: "Sync setup - button on the start over explanation page that starts the fresh sign-in")

    static let back = NSLocalizedString("sync.resetRequest.back",
        value: "Back",
        comment: "Sync setup - button on the start over pages that returns to the choice of how this Mac joins the account")

    // MARK: Fresh sign-in

    static let signInTitle = NSLocalizedString("sync.resetRequest.signIn.title",
        value: "Sign in to continue",
        comment: "Sync setup - title shown while the user completes a fresh sign-in in the browser before asking to start over")

    static let signInMessage = NSLocalizedString("sync.resetRequest.signIn.message",
        value: "Finish signing in in your browser. This window continues when you’re done.",
        comment: "Sync setup - message shown while the user completes a fresh sign-in in the browser before asking to start over")

    static let signInCancel = NSLocalizedString("sync.resetRequest.signIn.cancel",
        value: "Cancel",
        comment: "Sync setup - button that stops waiting for the fresh sign-in and returns to the start over explanation")

    static let signInFailed = NSLocalizedString("sync.resetRequest.signIn.failed",
        value: "Couldn’t confirm your sign-in. Try again.",
        comment: "Sync setup - error on the start over explanation page when the fresh sign-in did not complete")

    static let signInWrongAccount = NSLocalizedString("sync.resetRequest.signIn.wrongAccount",
        value: "Sign in with the account you’re setting up sync for.",
        comment: "Sync setup - error on the start over explanation page when the fresh sign-in used a different account")

    static let staleSignIn = NSLocalizedString("sync.resetRequest.error.staleSignIn",
        value: "Couldn’t confirm a recent sign-in. Try again in a few minutes.",
        comment: "Sync setup - error shown when the sync server still did not accept the fresh sign-in after signing in twice")

    // MARK: Waiting page

    static let waitingTitle = NSLocalizedString("sync.resetRequest.waiting.title",
        value: "Start over requested",
        comment: "Sync setup - title of the page shown while a request to start sync over waits for its date")

    /// "Sync will start over on <date>. ..."
    static func waitingMessage(executeAfter: Date) -> String {
        String(format: NSLocalizedString("sync.resetRequest.waiting.message",
            value: "Sync will start over on %@. You can keep using this Mac. Any Mac set up for sync that comes online before then is asked whether this was you.",
            comment: "Sync setup - message on the page shown while a request to start sync over waits; %@ is the date and time the account's sync data will be deleted"),
            formatted(executeAfter))
    }

    static let cancelRequest = NSLocalizedString("sync.resetRequest.cancelRequest",
        value: "Cancel request",
        comment: "Button that withdraws this Mac's pending request to start sync over, on the setup waiting page and in Settings → Sync")

    static let close = NSLocalizedString("sync.resetRequest.waiting.close",
        value: "Close",
        comment: "Sync setup - button that closes the window and keeps the pending request to start sync over")

    static let cancelFailed = NSLocalizedString("sync.resetRequest.cancelFailed",
        value: "Couldn’t cancel the request. Check your connection and try again.",
        comment: "Error shown when withdrawing this Mac's pending request to start sync over failed, on the setup waiting page and in Settings → Sync")

    // MARK: Refusals

    static let devicesActiveTitle = NSLocalizedString("sync.resetRequest.devicesActive.title",
        value: "A Mac set up for sync is still in use",
        comment: "Sync setup - title shown when the request to start over was refused because a Mac set up for sync was used recently")

    static func devicesActiveMessage(lastActiveAt: Date?) -> String {
        guard let lastActiveAt else {
            return NSLocalizedString("sync.resetRequest.devicesActive.messageNoDate",
                value: "A Mac set up for sync was used recently. Use that Mac to approve this one, or remove it there.",
                comment: "Sync setup - shown when the request to start over was refused because a Mac set up for sync was used recently and the time is unknown")
        }
        return String(format: NSLocalizedString("sync.resetRequest.devicesActive.message",
            value: "A Mac set up for sync was used on %@. Use that Mac to approve this one, or remove it there.",
            comment: "Sync setup - shown when the request to start over was refused because a Mac set up for sync was used recently; %@ is the date and time it was last used"),
            formatted(lastActiveAt))
    }

    static let requestExistsTitle = NSLocalizedString("sync.resetRequest.requestExists.title",
        value: "Another Mac already asked",
        comment: "Sync setup - title shown when another Mac already asked to start sync over for this account")

    static func requestExistsMessage(executeAfter: Date?) -> String {
        guard let executeAfter else {
            return NSLocalizedString("sync.resetRequest.requestExists.messageNoDate",
                value: "Another Mac already asked to start over. Try again later.",
                comment: "Sync setup - shown when another Mac already asked to start sync over and its date is unknown")
        }
        return String(format: NSLocalizedString("sync.resetRequest.requestExists.message",
            value: "Another Mac already asked to start over. It can finish from %1$@; if it never does, you can ask again from %2$@.",
            comment: "Sync setup - shown when another Mac already asked to start sync over; %1$@ is when that Mac can finish, %2$@ is when this Mac can ask again (7 days later)"),
            formatted(executeAfter), formatted(executeAfter.addingTimeInterval(pendingExpiry)))
    }

    static let deniedTitle = NSLocalizedString("sync.resetRequest.denied.title",
        value: "Request declined",
        comment: "Sync setup - title shown when a Mac set up for sync declined this Mac's request to start over")

    static let deniedMessage = NSLocalizedString("sync.resetRequest.denied.message",
        value: "Another Mac declined this request.",
        comment: "Sync setup - shown when a Mac set up for sync declined this Mac's request to start over")

    static let expiredTitle = NSLocalizedString("sync.resetRequest.expired.title",
        value: "Request ran out",
        comment: "Sync setup - title shown when this Mac's request to start over expired before it was finished")

    static let expiredMessage = NSLocalizedString("sync.resetRequest.expired.message",
        value: "This request ran out. You can start over again.",
        comment: "Sync setup - shown when this Mac's request to start over expired before it was finished")

    static let startOverAgain = NSLocalizedString("sync.resetRequest.expired.startOverAgain",
        value: "Start over again",
        comment: "Sync setup - button on the expired start over request page that returns to the start over explanation")

    // MARK: Errors

    static let requestFailed = NSLocalizedString("sync.resetRequest.error.requestFailed",
        value: "Couldn’t send the request to start over. Try again.",
        comment: "Sync setup - error shown when the request to start sync over could not be sent or was not accepted")

    static let executeFailed = NSLocalizedString("sync.resetRequest.error.executeFailed",
        value: "Couldn’t start sync over. Try again.",
        comment: "Sync setup - error shown when deleting the account's sync data at the end of the waiting period failed")

    static let retry = NSLocalizedString("sync.resetRequest.error.retry",
        value: "Try again",
        comment: "Sync setup - button on a start over error page that retries the request")

    // MARK: Settings → Sync

    static let settingsPendingTitle = NSLocalizedString("sync.resetRequest.settings.pendingTitle",
        value: "Start over pending",
        comment: "Settings → Sync - title of the row shown while this Mac's request to start sync over is pending")

    static func settingsPendingDetail(executeAfter: Date?) -> String {
        guard let executeAfter else {
            return NSLocalizedString("sync.resetRequest.settings.pendingDetailNoDate",
                value: "Open sync setup to see when sync starts over.",
                comment: "Settings → Sync - detail of the start over pending row when the date is not known yet")
        }
        return String(format: NSLocalizedString("sync.resetRequest.settings.pendingDetail",
            value: "Sync will start over on %@.",
            comment: "Settings → Sync - detail of the start over pending row; %@ is the date and time the account's sync data will be deleted"),
            formatted(executeAfter))
    }

    // MARK: Dates

    /// How long after `execute_after` a request nobody finished expires (`PendingExpiry`, fixed
    /// by the server design).
    static let pendingExpiry: TimeInterval = 7 * 24 * 60 * 60

    /// A date in the user's locale, never the wire's RFC 3339.
    static func formatted(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
