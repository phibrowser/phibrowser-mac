// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

/// Fills in the icons of the rows a Migration or a browser-data import just
/// wrote. Bookmarks and pinned tabs land without bytes, and the display path
/// only reads the Profile's favicon database, so a site the user never
/// visited in the source browser would stay a globe until opened. The
/// backfill asks the Chromium side for each page's icon — the bridge fetches
/// the site's own `/favicon.ico` into the Profile's favicon database when it
/// holds none — and writes the answer onto the row through the store's
/// favicon update. The in-memory models pick the bytes up through the store's
/// publishers, so a row on screen refreshes on its own, and the icon survives
/// a restart. The first real visit replaces the cheap icon with the page's
/// own: that is Chromium's on-demand favicon contract, not code here.
///
/// One shared queue for the whole app: every trigger enqueues onto it and
/// never awaits it; batches are worked in arrival order and rows in their
/// order within a batch, with at most `maxInFlight` requests out across
/// everything enqueued. In memory only — nothing is persisted, nothing
/// resumes after a quit, nothing retries.
///
/// The rules, applied when a row's turn comes: a row that holds bytes, or is
/// gone, is skipped; an internal page (the kinds `FaviconConfiguration` draws
/// with Phi's own icon) is not asked; both pages of a Split Bookmark are
/// asked, the second page before the first — the second icon is not on the
/// row but in the Profile's favicon database, so its answer is handed to
/// the favicon repository every view reads it from, which tells a view
/// showing it to look again, and asking it first has both icons appear
/// together when the row's bytes land; a nothing answer leaves the row
/// alone; an answer for a page the row no longer points at is not written.
@MainActor
final class FaviconBackfill {
    static let shared = FaviconBackfill(fetcher: ChromiumBridgeOnDemandFaviconFetcher())

    /// Requests out at once across every batch enqueued: a Migration of
    /// hundreds of entries must not open hundreds of connections. A slot
    /// freed by `requestDeadline` may leave its download running a moment
    /// longer — the Chromium side caps each at 30 s of its own — so the
    /// true count can briefly exceed this by that tail, never unboundedly.
    static let maxInFlight = 4

    private struct Job {
        let profileId: String
        let guid: String
        let store: LocalStore
    }

    private let fetcher: any ProfileScopedFaviconFetching
    private let resolveStore: () -> LocalStore?
    private let requestDeadline: TimeInterval
    private let repository: ProfileScopedFaviconRepository
    private var queue: [Job] = []
    private var inFlight = 0

    /// `fetcher` answers "the icon for this page URL in this Profile" with
    /// bytes or nothing. `store` resolves the local store a batch's rows live
    /// in, when the batch arrives. `requestDeadline` bounds how long a slot
    /// waits for an answer: the bridge drops a call whose Profile shut down
    /// mid-flight without ever answering, and a slot must not wait on that
    /// forever. `repository` is the display-side favicon cache a Split
    /// Bookmark's second icon is announced through.
    init(
        fetcher: any ProfileScopedFaviconFetching,
        store: @escaping () -> LocalStore? = { AccountController.shared.localDataAccount?.localStorage },
        requestDeadline: TimeInterval = 30,
        repository: ProfileScopedFaviconRepository = .shared
    ) {
        self.fetcher = fetcher
        self.resolveStore = store
        self.requestDeadline = requestDeadline
        self.repository = repository
    }

    /// Queues the rows with these identifiers, in this order, and returns at
    /// once. A batch that arrives with no store to write to is dropped.
    func enqueue(profileId: String, guids: [String]) {
        guard !guids.isEmpty else { return }
        guard let store = resolveStore() else {
            AppLogWarn("[FaviconBackfill] no local store; dropping \(guids.count) rows")
            return
        }
        AppLogInfo("[FaviconBackfill] queued \(guids.count) rows for Profile \(profileId)")
        queue.append(contentsOf: guids.map { Job(profileId: profileId, guid: $0, store: store) })
        pump()
    }

    /// The Bookmarks under `rows` that `included` accepts — every one by
    /// default — folders walked in place, in the order the sidebar lists
    /// them: what a trigger hands `enqueue` for a Space's tree read back
    /// from the store. Only the walk is decided here; whether a row is
    /// asked is settled at its turn.
    static func bookmarkGUIDs(
        under rows: [TabDataModel],
        where included: (TabDataModel) -> Bool = { _ in true }
    ) -> [String] {
        rows.flatMap { row -> [String] in
            switch row.dataType {
            case .bookmark:
                return included(row) ? [row.guid] : []
            case .bookmarkFolder:
                return bookmarkGUIDs(
                    under: row.children.sorted { $0.index < $1.index }, where: included)
            case .tab, .pinnedTab:
                return []
            }
        }
    }

    private func pump() {
        while inFlight < Self.maxInFlight, !queue.isEmpty {
            let job = queue.removeFirst()
            guard let row = job.store.getTab(by: job.guid),
                  row.dataType == .bookmark || row.dataType == .pinnedTab,
                  row.favicon == nil else {
                continue
            }
            let first = Self.asksFor(row.url) ? row.url : nil
            let second = row.secondaryUrl.flatMap { Self.asksFor($0) ? $0 : nil }
            guard first != nil || second != nil else { continue }
            inFlight += 1
            askSecond(second, thenFirst: first, for: job)
        }
    }

    private static func asksFor(_ pageURL: URL) -> Bool {
        !FaviconConfiguration.shouldUseDefaultFavicon(for: pageURL)
    }

    private func askSecond(_ second: URL?, thenFirst first: URL?, for job: Job) {
        guard let second else {
            askFirstAndWrite(first, for: job)
            return
        }
        fetch(second, profileId: job.profileId, answered: { [repository] data in
            // Not on the row: the repository the views read the second icon
            // from is told, and a view showing it resolves it again.
            guard let data else { return }
            repository.store(data, profileId: job.profileId, pageURLString: second.absoluteString)
        }, settled: { [weak self] in
            self?.askFirstAndWrite(first, for: job)
        })
    }

    private func askFirstAndWrite(_ first: URL?, for job: Job) {
        guard let first else {
            releaseSlot()
            return
        }
        fetch(first, profileId: job.profileId, answered: { data in
            // Only onto a row still without bytes and still at this page,
            // decided on the store's serial writer rather than here: a visit
            // in the meantime may have put the page's own icon on the row —
            // or queued the write that will — and a fetched icon never
            // replaces it; an edit may have pointed the row elsewhere, and
            // this page's icon does not belong there.
            if let data {
                job.store.updateTabFavicon(
                    job.guid, favicon: data,
                    sourceURLString: first.absoluteString, onlyIfMissing: true)
            }
            AppLogDebug("[FaviconBackfill] \(first.absoluteString): "
                + (data.map { "\($0.count) bytes" } ?? "nothing"))
        }, settled: { [weak self] in
            self?.releaseSlot()
        })
    }

    private func releaseSlot() {
        inFlight -= 1
        pump()
    }

    /// Asks the fetcher. `answered` runs with the answer whenever it comes;
    /// `settled` runs exactly once — right after the answer, or with no
    /// answer once `requestDeadline` has passed — and is what moves the
    /// slot on. An answer after the deadline is still acted on: the icon is
    /// in the Profile's database by then, and the row or the views are
    /// told the same way.
    private func fetch(
        _ pageURL: URL,
        profileId: String,
        answered: @escaping (Data?) -> Void,
        settled: @escaping () -> Void
    ) {
        var isSettled = false
        let settleOnce = {
            guard !isSettled else { return }
            isSettled = true
            settled()
        }
        let deadline = DispatchWorkItem(block: settleOnce)
        fetcher.getFavicon(profileId: profileId, pageURLString: pageURL.absoluteString) { data in
            DispatchQueue.main.async {
                answered(data)
                deadline.cancel()
                settleOnce()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + requestDeadline, execute: deadline)
    }
}

/// The production fetch: the bridge's fetch-on-miss lookup, addressed by
/// Profile (`getOrFetchFaviconForURL:profileId:completion:`). Answers nothing
/// when the bridge is not up.
@MainActor
private final class ChromiumBridgeOnDemandFaviconFetcher: ProfileScopedFaviconFetching {
    func getFavicon(profileId: String, pageURLString: String, completion: @escaping (Data?) -> Void) {
        guard let bridge = ChromiumLauncher.sharedInstance().bridge else {
            AppLogDebug("[FaviconBackfill] bridge unavailable for \(pageURLString)")
            completion(nil)
            return
        }
        bridge.getOrFetchFavicon(forURL: pageURLString, profileId: profileId) { data in
            completion(data)
        }
    }
}
