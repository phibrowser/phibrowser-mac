import CryptoKit
import Foundation

/// The engine's view of the domain key. `PhiDomainKeyManager` is a concrete final class with
/// no seam of its own, so the abstraction lives here — the same shape as
/// `protocol KeyEnvelopeAPI` / `extension KeyEnvelopeAPIClient: KeyEnvelopeAPI {}`.
protocol PhiDomainKeyProviding: AnyObject {
    func domainKey() async throws -> SymmetricKey
}

/// The witness is `@MainActor` (see `PhiDomainKeyManager`), which an `async` requirement
/// accepts: the engine's `await domainKeys.domainKey()` becomes a hop onto the main actor,
/// which is exactly the point — it keeps the M2 key layer main-actor-confined.
extension PhiDomainKeyManager: PhiDomainKeyProviding {}

/// Metadata-only rendering of an error for the shipped log (design §8 / ruling R12).
///
/// A bare `\(error)` is not safe here: `KeyAPIError.http(Int, String)` carries the server's
/// raw response body, and the key endpoints answer with sealed envelopes, so interpolating the
/// whole value would put payload bytes into a log file support asks users to send. The cases
/// enumerated below are all metadata by construction; everything else degrades to the error's
/// type plus its bridged domain/code rather than its description.
enum PhiSyncLog {
    static func describe(_ error: Error) -> String {
        switch error {
        case let error as KeyAPIError:
            switch error {
            case .http(let status, _): return "KeyAPIError.http(\(status))"
            case .transport(let underlying): return "KeyAPIError.transport(\(describe(underlying)))"
            case .decode: return "KeyAPIError.decode"
            case .lastActiveDevice: return "KeyAPIError.lastActiveDevice"
            }
        case let error as PhiSyncProtocolError:
            // Every case carries an HTTP status or a protocol enum, never content.
            return String(describing: error)
        case let error as CryptoKitError:
            return String(describing: error)
        case let error as ProfileKeyManagerError:
            return String(describing: error)
        default:
            let bridged = error as NSError
            return "\(type(of: error))(domain=\(bridged.domain) code=\(bridged.code))"
        }
    }
}

/// 配对向导第 2 步 Account 列的一行（R-D6-1）。**这是一次性的、只给 UI 看的东西，
/// 不是同步状态**。
struct PhiAccountSpaceSummary: Equatable, Sendable {
    let syncUuid: String
    let name: String
    let iconName: String
    let colorHex: String
    /// 账户级 profile uuid；默认 Space 为 `""`。
    let profileUuid: String
    /// 返回值里**恒为 false**：§4.3 第 6 条把账户里的默认 Space 整条丢掉了。保留这个
    /// 字段只为让那个过滤点在类型上可读，并让测试能直接断言它。
    let isDefault: Bool
    // D7 / R-D7-1：覆盖确认页比较的字段集比第 2 步的两列表多三个。第 2 步不渲染它们，
    // 确认页（§6.9）渲染由它们算出的账户侧值。一律保留**线上编码**，不在这里解释——
    // 归一化与显示是 `SpaceOverwriteDiff` 与视图的事，否则「什么算默认」要在两个地方
    // 各判一次。
    /// 线上 `theme_id`，`""` = 无主题 pin。
    let themeId: String
    /// 线上千分单位；**负数** = 无自定义透明度（本 build 发 -1，但落地那侧判的是 `< 0`）。
    let overlayOpacityLightMilli: Int64
    let overlayOpacityDarkMilli: Int64
}

enum PhiSpacePreviewError: Error, Equatable {
    /// 协调器手上没有引擎。
    case engineUnavailable
    case retired
    /// 页预算用尽，账户视图不完整。**不返回部分结果**。
    case truncated
    /// `PhiSyncLog.describe` 之后的元数据字符串（R12：不含任何载荷）。
    case transport(String)
}

/// One round of Phi settings sync: pull (GetUpdates -> decrypt -> field-level LWW merge ->
/// apply) and push (snapshot -> encrypt -> Commit), plus the conflict retry and the
/// account-scoped cursor state both need.
///
/// An `actor`, but actor isolation alone does **not** serialize the rounds: Swift actors are
/// reentrant, so every `await` inside a round (the domain key, the network) lets the next
/// message in. The debounced local-change push, the periodic pull, the foreground pull and the
/// conflict retry all mutate the same persisted cursor and the same `UserDefaults` snapshot, so
/// the three public entry points chain onto `roundQueue` and run strictly one after another —
/// see `serialized(_:)`. `PhiDomainKeyManager` is only ever touched from in here.
///
/// Zero knowledge: settings are sealed with the account's PhiBrowser domain key
/// (`PhiEntityCodec` -> `PhiKeyCrypto` AES-GCM) before they reach the protocol client. The
/// field-level last-writer-wins timestamps live inside that ciphertext, so the server orders
/// nothing and reads nothing.
///
/// The engine is single-account and single-use: sign-out must call `shutdown()` (see
/// `PhiChromiumCoordinator.stopPhiSync()`), because dropping the reference alone leaves the
/// rounds already on `roundQueue` running against the shared `phi.sync.*` cursor that the next
/// account is about to claim.
actor PhiSyncEngine {
    // MARK: - Persisted state
    //
    // All account-scoped, and they live in `UserDefaults.standard`, which is not — so account
    // A's progress marker and entity version must never be replayed against account B. What
    // enforces that is `PhiChromiumCoordinator.resetPhiSyncCursorIfAccountChanged`, which
    // compares the recorded owner against the account being mounted and wipes these keys
    // *before* the engine is built. Sign-out itself only calls `shutdown()`: the cursor is left
    // where it is and either re-adopted by the same account or dropped by that owner check.
    // (`resetSyncState()` below performs the same wipe on demand, but nothing in the app calls
    // it.)

    static let statePrefix = "phi.sync."
    /// Server-assigned entity id (`id_string`) for the settings entity.
    static let entityIdStateKey = statePrefix + "entityId"
    /// Version last seen for that entity; the `base_version` of the next commit.
    static let versionStateKey = statePrefix + "version"
    /// `store_birthday`, echoed back verbatim on every request once known.
    static let storeBirthdayStateKey = statePrefix + "storeBirthday"
    /// Opaque `DataTypeProgressMarker.token` for data type 2000.
    static let markerStateKey = statePrefix + "marker"
    /// Serialized `Phi_PhiSettingEntity` last known to be on the server. Also carries the keys
    /// this build does not know about, so a newer client's settings survive a round trip
    /// through this one.
    static let lastEntityStateKey = statePrefix + "lastEntity"
    /// Consecutive pulls that found the account's settings row tombstoned. Drives the heal
    /// below; persisted because a tombstone only this process happened to see twice is not
    /// evidence enough to re-create an account's settings.
    static let tombstoneRoundsStateKey = statePrefix + "tombstoneRounds"
    /// Set once this device has settings history for the account. Deliberately *not* part of
    /// the entity cursor: see `hasAdopted`.
    static let hasAdoptedStateKey = statePrefix + "hasAdopted"

    static let stateKeys = [entityIdStateKey, versionStateKey, storeBirthdayStateKey,
                            markerStateKey, lastEntityStateKey, tombstoneRoundsStateKey,
                            hasAdoptedStateKey]

    /// GetUpdates pages drained in one pull before the round gives up. 16 was enough for one
    /// settings entity; a first-time Space drain of a busy account is not. The budget still
    /// exists only to stop a pathological `changes_remaining` from spinning forever —
    /// exhausting it ends the ROUND, never the drain (§5.5 guard 1).
    private static let maxPullPages = 64

    /// A page-budget cut queues a follow-up round immediately instead of waiting out the 60 s
    /// timer; bounded so a misbehaving server cannot spin.
    private static let maxFollowUpRounds = 4

    /// Consecutive INVALID_MESSAGE rejections after which a tombstone is finalized anyway
    /// (§5.1). Same shape as `tombstoneHealAfterRounds`.
    private static let tombstoneRejectGiveUpRounds = 3

    /// The server's `MaxCommitEntries` default is 500; batching well under it keeps one bad
    /// round small.
    private static let maxCommitEntriesPerBatch = 25

    /// Consecutive tombstone pulls after which the entity cursor is dropped so a later local
    /// change can re-create the row. Refusing to publish over a tombstone is right (the delete
    /// must not be undone by the device that merely noticed it), but the refusal is otherwise
    /// account-wide and permanent: the server keeps returning the tombstoned row on every
    /// replay (`internal/data/entities_read.go` FetchUpdates has no `deleted = false` filter,
    /// and `internal/chromiumsync/getupdates.go` toSyncEntity emits it with a non-empty
    /// `id_string`), so `.absent`'s self-heal never fires and every device parks its pushes
    /// forever. Requiring several rounds first keeps a fresh delete sticky; requiring an
    /// explicit local change afterwards (this only clears the cursor, it never publishes)
    /// keeps a deliberate deletion from being resurrected by a device that is merely polling.
    private static let tombstoneHealAfterRounds = 3

    private let domainKeys: any PhiDomainKeyProviding
    private let client: PhiSyncProtocolClient
    private let defaults: UserDefaults
    private let deviceKeyId: String
    private let settings: [SyncableSetting]
    private let now: () -> Int64

    /// The Space section (M3-2). Both are `nil` on a build or an account that has no Space
    /// sync at all, and every Space branch below is gated on them being present, so the M3-1
    /// settings path is byte-for-byte what it was.
    private let spaceAccess: (any PhiSpaceLocalAccess)?
    private let spaceStore: (any PhiSpaceSyncStateStore)?

    /// Mirror of the table's `spaceSectionEnabled`, kept in memory so the shut -> open EDGE is
    /// detectable inside one process too.
    private var spaceSectionEnabled = false

    /// §3.6's per-round account profile refresh. `GET /keys/v1/profiles` is small, but App
    /// activation can fire `pullOnce()` far more often than the 60 s timer.
    private static let profileRefreshMinIntervalMs: Int64 = 30_000
    private var didRefreshProfilesThisRound = false
    private var lastProfileRefreshAtMs: Int64 = 0

    /// Follow-up rounds already queued after a page-budget cut, reset by the round that
    /// finally drains. Bounds `maxFollowUpRounds`.
    private var followUpRoundsUsed = 0

    /// Set around `SyncableSettings.apply` so a local-change notification raised by the engine's
    /// own write is not mistaken for a user edit. The load-bearing echo suppression is the
    /// `<key>.phiSyncTs` / `<key>.phiSyncVal` sidecars `apply` maintains; this flag only closes
    /// the window while the write is in flight.
    private var isApplyingRemote = false

    /// Tail of the round chain. Each public entry point appends its round to this task and
    /// awaits it, so a round that suspends in `getUpdates` or `commit` still finishes before
    /// the next one starts. Only the public entry points enqueue: the internal `pull` -> `push`
    /// and conflict `push` -> `pull` -> `push` calls run inside an already-queued round and
    /// would deadlock if they queued again.
    private var roundQueue: Task<Void, Never>?

    // MARK: - Shutdown

    /// One-way "this engine is retired" flag, set by `shutdown()` on sign-out / account
    /// switch. From then on no queued round runs, a round already in flight unwinds without
    /// writing anything, and no remote settings are applied.
    ///
    /// It lives in a lock-protected box rather than in actor state so `shutdown()` can be
    /// `nonisolated` and take effect *synchronously*. The sign-out path runs on the main
    /// actor while a round may be parked inside `getUpdates` (URLSession's default timeout is
    /// 60 s) with a debounced push chained behind it; an `await engine.shutdown()` would be
    /// just another message to a reentrant actor, with no ordering against that round's
    /// resumption. With the box, the moment `PhiChromiumCoordinator.stopPhiSync()` returns the
    /// dying round can no longer touch the shared `phi.sync.*` cursor — which the next account
    /// is about to reset and claim in the same `UserDefaults`.
    private final class StopSignal: @unchecked Sendable {
        private let lock = NSLock()
        private var stopped = false

        var isStopped: Bool {
            lock.lock()
            defer { lock.unlock() }
            return stopped
        }

        func stop() {
            lock.lock()
            stopped = true
            lock.unlock()
        }
    }

    private let stopSignal = StopSignal()
    private var isStopped: Bool { stopSignal.isStopped }

    /// Retires the engine for good: rounds queued behind an in-flight one never run, and the
    /// round already in flight skips every write it has left — the account-scoped cursor
    /// (`writeState`), the settings themselves and their `<key>.phiSync*` sidecars
    /// (`writeSettings` / `snapshotLocalSettings`).
    ///
    /// The exact guarantee, because `shutdown()` is genuinely concurrent with the round (it runs
    /// on the main actor at sign-out while the round runs on the actor's executor): the flag is
    /// read immediately before each of those writes, not only at the round's entry, so what a
    /// shutdown landing at the worst possible moment can still miss is one flag read rather than
    /// a whole round. Concretely, two things may still happen after `shutdown()` returns — a
    /// round that had just passed one of those checks completes that single write, and a commit
    /// already encrypted and handed to the transport still reaches the server (nothing it
    /// answers is persisted; the post-commit writes are checked again). Neither is harmful: at
    /// the instant `shutdown()` returns the account being torn down is still the mounted one, so
    /// those bytes are its own, and the sidecars are not account-scoped in the first place. What
    /// the guarantee rules out is the thing that matters — a round resuming *after* the next
    /// account has mounted and claiming its cursor or its settings.
    ///
    /// Idempotent, and deliberately not reversible — a new sign-in builds a new engine.
    nonisolated func shutdown() { stopSignal.stop() }

    /// 结果的一次性信箱（§4.3）。`final class` 而不是 `inout`：它要跨 `Task` 边界。
    final class PreviewBox {
        var result: Result<[PhiAccountSpaceSummary], PhiSpacePreviewError>?
    }

    /// What one queued round does. An enum rather than a closure so the body stays
    /// actor-isolated and needs no `@Sendable` gymnastics.
    private enum Round {
        case pull
        case push
        case localChange
        case localSpaceChange
        /// The Space gate's shut <-> open edge. Queued like every other round rather than
        /// applied in place, so it can never land *inside* a round that is parked in
        /// `getUpdates` — see `setSpaceSyncEnabled`.
        case spaceGate(Bool)
        /// §5.3: EVERY Space intent the main-thread facade delivers is a round.
        /// Running one "in place on the engine actor" is not exclusion — the
        /// engine is a reentrant actor, and the two long Space writers
        /// (`pull`'s apply section and `pushSpaces`) each hold one table copy
        /// across a main-actor hop or a whole network round trip and blind-write
        /// it back. An intent that lands inside either window is silently
        /// overwritten, which for `recordLocalDeletion` means the tombstone is
        /// never committed and the Space is later resurrected from a peer's
        /// entity. The queue is the only thing that makes the single writer real.
        case retentionSweep
        case recordLocalDeletion(String)
        /// 配对向导的只读账户预览（R-D6-1）。排同一条队列，所以它不可能与一轮设置
        /// 同步交错。
        case preview(PreviewBox)
    }

    init(domainKeys: any PhiDomainKeyProviding,
         client: PhiSyncProtocolClient,
         defaults: UserDefaults,
         deviceKeyId: String,
         settings: [SyncableSetting] = SyncableSettings.all,
         spaceAccess: (any PhiSpaceLocalAccess)? = nil,
         spaceStore: (any PhiSpaceSyncStateStore)? = nil,
         now: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        self.domainKeys = domainKeys
        self.client = client
        self.defaults = defaults
        self.deviceKeyId = deviceKeyId
        self.settings = settings
        self.spaceAccess = spaceAccess
        self.spaceStore = spaceStore
        self.now = now
        self.spaceSectionEnabled = spaceStore?.load().spaceSectionEnabled ?? false
    }

    // MARK: - Public surface

    /// GetUpdates -> decrypt -> merge -> apply, then publish anything the merge left the
    /// server behind on. Never throws: a failed round is logged and retried by the scheduler.
    func pullOnce() async {
        await serialized(.pull)
    }

    /// Snapshot -> encrypt -> Commit, with one pull-and-retry on CONFLICT.
    func pushLocalSettings() async {
        await serialized(.push)
    }

    /// Entry point for the debounced `UserDefaults.didChangeNotification` observer.
    func handleLocalDefaultsChange() async {
        await serialized(.localChange)
    }

    /// The Space section's gate (§3.5): account bound AND ARK unlocked AND the join-time
    /// pairing is finished. Driven by the coordinator, NOT by `needsPairing` — §3.6's
    /// auto-create makes that predicate flip true for a moment every time the account gains a
    /// profile, and hanging the gate on it would drop the shared marker and replay the whole
    /// data type each time.
    ///
    /// Queued through `serialized(_:)`, and that is not a detail: the engine is a reentrant
    /// actor, so a gate open awaited from the coordinator while a round is parked in
    /// `getUpdates` would otherwise land in the middle of that round — after it read the Space
    /// table and before it writes anything back — and the round would carry on with a stale
    /// `spaceLive` and re-establish the very marker this edge just dropped. Running it as a
    /// round means the edge happens strictly between rounds: the replay it arms is the next
    /// round's to perform.
    ///
    /// Must therefore be called from *outside* a round (the coordinator is the only caller);
    /// calling it from inside one would wait on the queue that round is holding. A redundant
    /// call is a no-op at the edge check inside the round, but it still queues behind whatever
    /// is in flight, so the coordinator should keep driving it on real state changes only.
    func setSpaceSyncEnabled(_ enabled: Bool) async {
        guard spaceStore != nil else { return }
        await serialized(.spaceGate(enabled))
    }

    /// 配对向导第 2 步的 Account 列（R-D6-1）。
    ///
    /// **它持久化的东西是：没有。** 不写 `storedMarker`、不写 `storedBirthday`、不建
    /// 也不改任何游标、不写任何基线、不动 `unreadableTagHashes`、不动
    /// `hasDrainedFullReplay` / `drainInProgress` / `hadRecords` /
    /// `didReplayForEmptyTable`、不写映射、不 commit 任何东西。它不是 `push`，
    /// `pushSpaces` 的四道守卫一处都没碰。`run(_:)` 的这一支还**提前返回**，所以
    /// §11 的 `logSpaceRound()` 也不跑：预览不是一轮 Space，不该在计数行里留下一条
    /// 全零记录，也不该为此多两次主 actor 往返。
    ///
    /// **它也不看 `spaceSectionEnabled`。** 这是唯一一条允许在门关着时执行的 Space
    /// 形状的读，允许的理由恰恰是「它什么都不写」。
    ///
    /// 拿到的东西是一次性的、只给 UI 看的，**不是同步状态**：它从不推进共享 marker，
    /// 所以门开边沿仍然会丢一次 marker 并重放整个 data type，账户里每一条 Space 都会
    /// 在门开后再走一遍正式路径。
    func previewAccountSpaces() async -> Result<[PhiAccountSpaceSummary], PhiSpacePreviewError> {
        let box = PreviewBox()
        await serialized(.preview(box))
        return box.result ?? .failure(.retired)
    }

    /// The gate edge itself. Runs as a queued round; never call it directly.
    private func applySpaceGate(_ enabled: Bool) {
        guard enabled != spaceSectionEnabled else { return }
        spaceSectionEnabled = enabled
        mutateSpaceTable { table in
            table.spaceSectionEnabled = enabled
            // Two triggers, one action. `markerMovedWhileGateShut` covers every shut episode this
            // build observed. `!hasDrainedFullReplay` covers the one it could not observe: the
            // M3-1 -> M3-2 UPGRADE, where the device already holds a non-nil `phi.sync.marker`
            // from months of settings sync, an empty `sync.phiSpaces` (so `hadRecords == false`
            // and guard 2's second trigger is disabled too), and no flag was ever set because the
            // flag did not exist. Without this disjunct nothing ever drops that marker: the pull
            // never sees `storedMarker == nil`, so `drainInProgress` is never armed,
            // `hasDrainedFullReplay` stays false forever, `pushSpaces` returns at its own guard,
            // and the device silently never publishes a single Space.
            // Idempotent: once a drain completes, only a real shut episode re-arms it.
            if enabled, table.markerMovedWhileGateShut || !table.hasDrainedFullReplay {
                // Both kinds share ONE progress marker for data type 2000, so every Space entity
                // the settings pulls walked past while the gate was shut will never be delivered
                // again. Replay the type, and re-arm guard 1 so nothing is committed until the
                // replay finishes.
                AppLogInfo("[phi-sync] space gate opened (marker_moved=\(table.markerMovedWhileGateShut) drained=\(table.hasDrainedFullReplay)); replaying data type \(PhiSyncEntity.dataTypeID)")
                storedMarker = nil
                table.markerMovedWhileGateShut = false
                table.hasDrainedFullReplay = false
                table.drainInProgress = true
                // Deliberately untouched: reconciled / server / entityId / version / hidden /
                // deletedAtMs / purgedAtMs. The ACCOUNT did not change; clearing them would
                // re-arm the wholesale adopt and silently drop local edits that were just
                // stamped.
            }
        }
    }

    /// Entry point for the debounced `spacesPublisher()` / `.spaceThemeDidChange` observers
    /// (§5.4). Same shape as `handleLocalDefaultsChange()`.
    func handleLocalSpacesChange() async {
        await serialized(.localSpaceChange)
    }

    /// Delivered by `PhiSpaceSyncState.shared` and executed as a QUEUED ROUND --
    /// the table has exactly one writer (§5.3: "全部 async, 全部排进同一条
    /// roundQueue").
    ///
    /// Running the read-modify-write "on the engine actor" is not enough, and
    /// the failure is the one §5.3 names: a round reads the table, the user
    /// deletes a Space during one of that round's suspensions, and the round
    /// then writes its pre-delete copy back. `pushSpaces` holds its copy across
    /// `client.commit` (a full network round trip) and `pull`'s apply section
    /// holds one across every landing's main-actor hop, so the window is wide
    /// and ordinary. The lost `pendingDelete` is permanent and silent: the uuid
    /// never enters `spaceCommitEntries`' union again, no tombstone is ever
    /// committed, and with no `deletedAtMs` on the cursor the anti-resurrection
    /// guard cannot fire either -- the next delivery of that entity re-creates
    /// the Space the user deleted.
    ///
    /// Must be called from *outside* a round, like `setSpaceSyncEnabled`.
    func recordLocalDeletion(spaceId: String) async {
        await serialized(.recordLocalDeletion(spaceId))
    }

    func runRetentionSweep() async {
        await serialized(.retentionSweep)
    }

    /// §9.2's 30-day sweep over expired soft deletes. Runs as a queued round
    /// (`case .retentionSweep`); never call it directly.
    ///
    /// Two phases, and the split is the point. `purgeExpired` trims the table
    /// and is persisted BEFORE any `await`; only then does the data cascade run.
    ///
    /// The straight version -- load the table, trim it, `await spaceAccess.purge`
    /// in a loop, write the trimmed copy back -- is a lost update: every `purge`
    /// is a main-actor hop, i.e. an actor suspension point, and the round queued
    /// behind it does its own read-modify-write of the same table. The final
    /// `writeSpaceTable` would then put back a snapshot taken before that round
    /// existed. This is exactly what §5.3's single-writer rule is for, so the
    /// sweep runs as a round AND keeps no stale copy across a suspension.
    private func applyRetentionSweep() async {
        guard let spaceAccess, spaceStore != nil else { return }
        var table = loadSpaceTable()
        let expired = table.purgeExpired(nowMs: now())
        guard !expired.isEmpty else { return }
        // Phase 1: persist the trimmed table with no suspension in between. The
        // cursors are now permanent tombstones -- §9.1's two promises (a
        // replayed tombstone is a no-op, snapshot never resurrects the uuid)
        // rest on the cursor being there with a `deletedAtMs`, so they hold even
        // if the cascade below is interrupted.
        writeSpaceTable(table)

        // Phase 2: cascade the data. No table copy is held across these awaits.
        for uuid in expired {
            guard !isStopped else { return }
            // D6：`purgeExpired` 返回的是 syncUuid，`purge` 收的是本地 id。解析不到
            // ⇒ 无事可做（本机本来就没有这条），游标留下的 tombstone 已经在 Phase 1
            // 写好了。
            guard let local = await spaceAccess.localSpaceId(forSyncUuid: uuid) else { continue }
            do {
                try await spaceAccess.purge(spaceId: local)
                // **purge 成功之后**才删映射行；游标留下（它是永久 tombstone 记录，
                // 这一点只有在按 syncUuid 键时才自洽）。
                await spaceAccess.dropSpaceMapping(forSpaceId: local)
            } catch {
                // 级联失败 ⇒ **映射必须留着**（R12：只记 describe 出来的那一串）。
                // 无条件删掉是一条复活路径：`currentSpaces()` 直读本地行、不经
                // `hiddenSpaceIds` 过滤，那条还在盘上的行会进下一趟 `pushSpaces`，
                // 懒铸造给它铸一个**全新的** syncUuid，账户里因此多出一条谁也合不掉
                // 的 Space；而 Phase 1 已经盖上 `purgedAtMs`，清理不会再来第二次。
                // 留着映射就留住了「syncUuid → 已 tombstone 的游标」这条链，
                // `snapshot` 的 eligible 过滤照旧把它排除在外。
                AppLogWarn("[phi-sync] retention purge failed; keeping the mapping so the row cannot be republished (\(PhiSyncLog.describe(error)))")
            }
        }
    }

    /// Drops every account-scoped cursor, `hasAdopted` included, so the next account's entity
    /// is adopted rather than merged against the previous account's timestamps.
    ///
    /// **Test and recovery helper — the app never calls this.** The account-scope reset that
    /// actually ships runs one layer up, in
    /// `PhiChromiumCoordinator.resetPhiSyncCursorIfAccountChanged(accountId:defaults:)`: it
    /// wipes the same `stateKeys` from outside, keyed on a recorded owner account, at the one
    /// moment the wipe is safe — before the engine for the new account exists. Doing it from
    /// in here cannot cover that case anyway: sign-out calls `shutdown()`, and the guard below
    /// then makes this a no-op, precisely because a retired engine's `UserDefaults` may already
    /// belong to the account mounted next.
    ///
    /// **Account scope only.** Nothing that happens *within* one account may call this:
    /// clearing `hasAdopted` re-arms the wholesale adopt in `apply`, and the account's own
    /// settings history is precisely what makes a field-level merge possible. The two
    /// same-account recoveries (a server row this device can no longer address, and a store
    /// birthday that no longer matches) go through `clearRemoteCursor()` and
    /// `resetForNewStoreBirthday()` instead.
    ///
    /// Deliberately synchronous and *not* queued: it runs to completion between the suspension
    /// points of any round, so it never tears a half-written cursor.
    func resetSyncState() {
        guard !isStopped else { return }
        for key in Self.stateKeys { defaults.removeObject(forKey: key) }
    }

    // MARK: - Round serialization

    /// Runs `round` after every round enqueued before it. Actor reentrancy means a round that
    /// is parked in `getUpdates` or `commit` would otherwise let the next one in and both would
    /// interleave their writes to `storedVersion` / `storedMarker` / `storedLastEntity`.
    private func serialized(_ round: Round) async {
        let previous = roundQueue
        let task = Task { [previous] in
            await previous?.value
            await self.run(round)
        }
        roundQueue = task
        await task.value
    }

    private func run(_ round: Round) async {
        // A round enqueued before sign-out but still waiting behind an in-flight one must not
        // start against the account that has since been mounted on the same defaults.
        guard !isStopped else { return }
        // §11's counters are per ROUND, not per pull: one round can contain a
        // NOT_MY_BIRTHDAY retry, the push's initial pull and a scoped conflict
        // retry, and `pushSpaces` runs after the pull's tail has already finished.
        spaceCounters = SpaceRoundCounters()
        // Same reason, same scope: the NOT_MY_BIRTHDAY recursion (:608), the push's initial
        // pull (:1160 / :1456) and the CONFLICT retry (:1250) are all pulls inside ONE round,
        // and none of them re-lists the account's profiles.
        didRefreshProfilesThisRound = false
        switch round {
        case .pull:
            _ = await pull(retryOnBirthday: true, thenPush: true)
        case .push:
            await push(retryOnConflict: true, allowInitialPull: true)
        case .localChange:
            guard !isApplyingRemote else { return }
            await push(retryOnConflict: true, allowInitialPull: true)
        case .localSpaceChange:
            guard !isApplyingRemote else { return }
            await push(retryOnConflict: true, allowInitialPull: true)
        case .spaceGate(let enabled):
            applySpaceGate(enabled)
        case .retentionSweep:
            await applyRetentionSweep()
        case .recordLocalDeletion(let localSpaceId):
            // 边界翻译（§3.4）：`SpaceManager` 交来的是**本地** id，游标按 syncUuid
            // 键。解析不到 = 从来没发布过 = 无 tombstone 可发，这与
            // `PhiSpaceSyncTable.recordLocalDeletion` 既有的 `entityId != nil` 判据
            // 是同一件事的两个说法。门面 `PhiSpaceSyncState.recordLocalDeletion(spaceId:)`
            // 的签名与语义**不变**，仍收本地 id。
            if let uuid = await spaceAccess?.syncUuid(forSpaceId: localSpaceId) {
                runSpaceIntent { table in table.recordLocalDeletion(spaceId: uuid) }
            } else {
                AppLogInfo("[phi-sync] a local Space delete has no account identity; nothing to tombstone")
            }
        case .preview(let box):
            await runPreview(into: box)
            return          // 预览不是 Space 轮：不参与 §11 的计数行
        }
        await logSpaceRound()
    }

    // MARK: - 配对向导的只读账户预览（§4）

    /// §4.3 的轮体。跑在引擎 actor 的同一条 round 队列上；never call it directly.
    private func runPreview(into box: PreviewBox) async {
        let startedAt = now()
        guard !isStopped else { box.result = .failure(.retired); return }
        let key: SymmetricKey
        do {
            key = try await domainKeys.domainKey()
        } catch {
            AppLogWarn("[phi-sync] space preview failed: domain key unavailable (\(PhiSyncLog.describe(error)))")
            box.result = .failure(.transport("domain_key"))
            return
        }
        guard !isStopped else { box.result = .failure(.retired); return }

        var summaries: [String: (entity: Phi_PhiSpaceEntity, version: Int64)] = [:]
        var pages = 0
        var entities = 0
        var refused = 0
        var unreadable = 0
        // **局部** marker：响应里的 marker 与 birthday 都不写回。首次加入时
        // `storedBirthday` 可能还是 ""（设置同步的第一轮尚未收尾），这是正常输入——
        // 服务端会回一个真的，预览照旧不写回。
        var marker: Data?
        var more = true
        do {
            while more, pages < Self.maxPullPages {
                let response = try await client.getUpdates(marker: marker, storeBirthday: storedBirthday)
                guard !isStopped else { box.result = .failure(.retired); return }
                marker = response.newMarker
                pages += 1
                more = response.changesRemaining
                for entity in response.entities {
                    entities += 1
                    // 设置实体不关它的事；tombstone 不需要（账户里已经删掉的 Space
                    // 不该出现在配对列表里）。
                    guard entity.clientTagHash != PhiSyncEntity.settingsClientTagHash,
                          !entity.deleted else { continue }
                    guard let decoded = try? PhiEntityCodec.decrypt(entity.ciphertext, key: key) else {
                        unreadable += 1     // 只计数，**不**记进 `unreadableTagHashes`
                        continue
                    }
                    guard case .space(let space)? = decoded.kind else { continue }
                    let expected = PhiSyncEntity.clientTagHash(
                        for: PhiSyncEntity.spaceClientTag(space.spaceUuid))
                    guard expected == entity.clientTagHash else { unreadable += 1; continue }
                    // 两条 agent 特征匹配的载荷绝不能出现在配对选项里；默认 Space 的
                    // 身份由 D1 固定，绝不可在配对列表里被选中。
                    guard !SyncableSpaces.refuses(space) else { refused += 1; continue }
                    guard space.spaceUuid != SyncableSpaces.defaultSpaceUuid else { continue }
                    // 一次全量重放里每个实体只出现一次；去重取 version 较大者是防御性的。
                    if let seen = summaries[space.spaceUuid], seen.version >= entity.version { continue }
                    summaries[space.spaceUuid] = (space, entity.version)
                }
            }
        } catch PhiSyncProtocolError.notMyBirthday {
            // 预览不做任何游标清理，那是正式 pull 的职责。**这不是死路**：设置同步照常
            // 按 60 s 跑，它自己的 birthday 重试会把 `storedBirthday` 修好，下一次
            // Retry 就能过。
            AppLogWarn("[phi-sync] space preview: pages=\(pages) error=not_my_birthday")
            box.result = .failure(.transport("not_my_birthday"))
            return
        } catch {
            AppLogWarn("[phi-sync] space preview: pages=\(pages) error=\(PhiSyncLog.describe(error))")
            box.result = .failure(.transport(PhiSyncLog.describe(error)))
            return
        }

        guard !more else {
            // **不返回部分结果**：Account 列缺一条，用户就可能把一个账户里已经存在的
            // Space 选成「Add as new」，铸出第二条实体——而那正是这个向导要消灭的状态。
            AppLogWarn("[phi-sync] space preview: pages=\(pages) error=truncated")
            box.result = .failure(.truncated)
            return
        }

        let out = summaries.values.map { item -> PhiAccountSpaceSummary in
            let entity = item.entity
            return PhiAccountSpaceSummary(
                syncUuid: entity.spaceUuid,
                name: entity.name.stringValue,
                iconName: entity.iconName.stringValue,
                colorHex: entity.colorHex.stringValue,
                profileUuid: entity.profileUuid.stringValue,
                isDefault: false,
                themeId: entity.themeID.stringValue,
                overlayOpacityLightMilli: entity.overlayOpacityLight.intValue,
                overlayOpacityDarkMilli: entity.overlayOpacityDark.intValue)
        }.sorted { $0.syncUuid < $1.syncUuid }   // 顺序确定，便于测试与两机对照
        // §9.1 第一条。R12：只有计数。
        AppLogInfo("[phi-sync] space preview: pages=\(pages) entities=\(entities) "
                   + "spaces=\(out.count) refused=\(refused) unreadable=\(unreadable) "
                   + "ms=\(now() - startedAt)")
        box.result = .success(out)
    }

    // MARK: - §11 round counters

    /// §11's one-line-per-round counter set. Metadata only (R12): counts and
    /// booleans, never a uuid, a name, an icon or a colour.
    ///
    /// `applied` counts entities that LANDED this round (creates, field updates,
    /// rebinds and remote soft deletes); `tombstones` counts the tombstones this
    /// device PUBLISHED, next to `pushed` and `conflicts`.
    private struct SpaceRoundCounters {
        var pulled = 0
        var applied = 0
        var refused = 0
        var pushed = 0
        var tombstones = 0
        var conflicts = 0
        var profilesCreated = 0
        /// ok | failed | skipped. `skipped` covers "already refreshed this
        /// round", "inside the 30 s interval" and "the gate is shut" -- §11 is
        /// explicit that it is NOT a failure. Filled in by Task 11's refresh hook;
        /// until that lands no refresh runs at all, so `skipped` is the true value.
        var profileRefresh = "skipped"
    }
    private var spaceCounters = SpaceRoundCounters()

    /// One info line per round, at the end of the round.
    private func logSpaceRound() async {
        guard spaceSectionEnabled, spaceStore != nil else { return }
        let table = loadSpaceTable()
        let held = table.cursors.values.filter { $0.heldProfileUuid != nil }.count
        let parked = table.cursors.values.filter { $0.pendingApply != nil }.count
        // §9.3：`mapped` 是映射表的行数（不含默认 Space 的隐式常量）；`unmapped` 是
        // 「本机同步合格、但还没有映射」的条数。**稳态应为 0**——长期非零 = 懒铸造
        // 一直失败，这是唯一能把「这台 Mac 的某个 Space 从来没上过账户」暴露出来的
        // 信号（D6 之前那个设置段落没了，这就是它的替代物：一个计数器，不是一个界面）。
        // R12：两个都是计数，不是 uuid 列表。
        // `filter` 的闭包里不能 `await`，所以映射表一次读完再在本地比。
        var mapped = 0
        var unmapped = 0
        if let spaceAccess {
            let mappings = await spaceAccess.allSpaceMappings()
            mapped = mappings.count
            unmapped = await spaceAccess.currentSpaces().filter {
                $0.spaceId != LocalStore.defaultSpaceId && mappings[$0.spaceId] == nil
            }.count
        }
        AppLogInfo("""
            [phi-sync] spaces pulled=\(spaceCounters.pulled) applied=\(spaceCounters.applied) \
            held=\(held) parked=\(parked) refused=\(spaceCounters.refused) \
            unreadable=\(table.unreadableTagHashes.count) pushed=\(spaceCounters.pushed) \
            tombstones=\(spaceCounters.tombstones) conflicts=\(spaceCounters.conflicts) \
            drained=\(table.hasDrainedFullReplay) drain_in_progress=\(table.drainInProgress) \
            profiles_created=\(spaceCounters.profilesCreated) \
            profile_refresh=\(spaceCounters.profileRefresh) \
            mapped=\(mapped) unmapped=\(unmapped)
            """)
    }

    // MARK: - Pull

    /// Why a pull could not turn the account's entity into settings. Only `.tombstone` is
    /// healable: the other two mean the server holds real content this build must not
    /// overwrite, and the refusal has to stand until a re-minted key or a newer build can read
    /// it. A tombstone carries nothing to protect, so it may eventually be re-created.
    private enum UnusableReason: String {
        case tombstone
        case foreignPayload = "payload is not settings"
        case undecryptable = "ciphertext could not be opened"
    }

    /// What one pull could make of the account's settings entity.
    private enum RemoteView {
        /// The server sent nothing under our client tag this round.
        case absent
        /// Decrypted settings this device can merge against.
        case usable(Phi_PhiSettingEntity)
        /// The entity is there but this build cannot turn it into settings (a tombstone, a
        /// ciphertext it cannot open, or a payload that is not `.setting`). Its bytes must
        /// survive: this device may not publish over them.
        case unusable(reason: UnusableReason)
    }

    /// Returns whether the round completed. The caller needs that: a first-ever push may only
    /// fall back to a `version = 0` create once it is sure the account holds nothing.
    private func pull(retryOnBirthday: Bool, thenPush: Bool) async -> Bool {
        guard !isStopped else { return false }
        let key: SymmetricKey
        do {
            key = try await domainKeys.domainKey()
        } catch {
            AppLogWarn("[phi-sync] pull skipped: domain key unavailable (\(PhiSyncLog.describe(error)))")
            return false
        }
        // Sign-out can land in any of this round's suspension points; from here the round is
        // holding the *previous* account's domain key, so everything below is off-limits.
        guard !isStopped else { return false }

        // Guard 1 (§5.5): the drain is a PROCESS, not the property of one pull. It is armed
        // only while the Space section is live — a gated-off pull hands the Space section
        // nothing, so letting it satisfy the guard would let a fresh device publish its
        // factory default Space over the account's.
        //
        // The whole Space side of this round obeys one rule: **no copy of the table spans a
        // suspension point, and every flag is persisted the moment it is observed**. The
        // shared marker is written page by page (`storedMarker = marker` below), so a flag
        // derived from it that is only written on the success path is simply gone when a
        // later page throws — with the marker left standing past whatever it walked over.
        let spaceTableAtEntry = loadSpaceTable()
        let spaceLive = spaceSectionEnabled && spaceStore != nil && spaceAccess != nil
        if spaceLive, storedMarker == nil, !spaceTableAtEntry.drainInProgress {
            // Persisted immediately, not at the tail: page 1 already makes the marker
            // non-nil, so a round that dies on page 2 would otherwise leave a non-nil marker
            // on disk beside `drainInProgress == false`. This precondition (`storedMarker ==
            // nil`) could then never be met again, `hasDrainedFullReplay` would stay false
            // for the rest of the session, and that flag is what Task 9's `pushSpaces` guard
            // reads before it publishes anything.
            mutateSpaceTable { table in
                table.drainInProgress = true
                table.hasDrainedFullReplay = false
            }
        }
        // Refresh the account profile list BEFORE the paging loop on purpose:
        // the bindings this round pulls must resolve against the mapping this
        // round just refreshed, or a Space a peer published seconds ago has to
        // park for a whole round.
        if spaceLive, !didRefreshProfilesThisRound, let spaceAccess {
            let elapsed = now() - lastProfileRefreshAtMs
            if lastProfileRefreshAtMs == 0 || elapsed >= Self.profileRefreshMinIntervalMs {
                didRefreshProfilesThisRound = true
                let outcome = await spaceAccess.refreshAccountProfiles()
                // The refresh is an `await`: retirement / sign-out / an account
                // switch can land inside it (§5.4 discipline).
                guard !isStopped else { return false }
                // A FAILED refresh does not arm the interval, or "retry next
                // round" would be contradicted by the throttle itself. `.skipped`
                // does not arm it either -- nothing ran.
                if outcome != .failed, outcome != .skipped { lastProfileRefreshAtMs = now() }
                // §11's two profile fields. `skipped` is the default the counter
                // struct starts with, so the branches that never reach here
                // (gate shut, already refreshed, inside the interval) report it
                // by construction -- and §11 is explicit that it is not a failure.
                switch outcome {
                case .failed: spaceCounters.profileRefresh = "failed"
                case .skipped: spaceCounters.profileRefresh = "skipped"
                case .unchanged, .changed: spaceCounters.profileRefresh = "ok"
                }
                spaceCounters.profilesCreated = await spaceAccess.profilesCreatedInLastRefresh()
            }
        }
        var batch = SpacePullBatch()
        // A snapshot, used for the cursor keys it carries and never written back.
        let tagIndex = spaceLive ? await spaceTagIndex(table: spaceTableAtEntry) : [:]

        // A pull with no marker replays the whole type, so "the entity was not in the response"
        // is only evidence of absence when we started from scratch and drained every page.
        let startedFromScratch = storedMarker == nil
        // What guard 2's first trigger compares against. `storedMarker`'s setter maps an empty
        // marker to *absent*, so "the marker did not move" is spelled "unchanged", never
        // "nil": the protocol client answers with `Data()` when the server sent no marker for
        // the type, and a response's `newMarker` is non-optional.
        let markerAtEntry = storedMarker
        // Only a gated-off round records marker movement, and only once per round: the flag
        // is a boolean, so the first page that moves the marker has already said everything
        // there is to say. `spaceStore != nil` keeps a settings-only engine (M3-1) out of the
        // Space table entirely.
        let recordsGatedMarkerMoves = !spaceLive && spaceStore != nil
        var markerMoveRecorded = false
        var view = RemoteView.absent
        var drained = false
        do {
            var marker = storedMarker
            var page = 0
            var more = true
            while more, page < Self.maxPullPages {
                let response = try await client.getUpdates(marker: marker, storeBirthday: storedBirthday)
                guard !isStopped else { return false }
                storedBirthday = response.storeBirthday
                marker = response.newMarker
                storedMarker = marker

                for entity in response.entities {
                    guard entity.clientTagHash == PhiSyncEntity.settingsClientTagHash else {
                        // Not the settings entity. With two kinds live on data type 2000 the
                        // response is no longer "our row or noise": everything else is routed
                        // to the Space section, and only while the gate is open.
                        guard spaceLive else { continue }
                        routeSpaceEntity(entity, key: key, tagIndex: tagIndex, into: &batch)
                        continue
                    }
                    if !entity.entityId.isEmpty { storedEntityId = entity.entityId }
                    storedVersion = entity.version
                    guard !entity.deleted else {
                        // A tombstone from another device: nothing to apply, and nothing to
                        // publish either — re-committing this device's snapshot on top of it
                        // would silently undelete the account's settings (the server's
                        // client_tag unique index reuses the tombstoned row).
                        view = .unusable(reason: .tombstone)
                        continue
                    }
                    do {
                        let decoded = try PhiEntityCodec.decrypt(entity.ciphertext, key: key)
                        guard case .setting(let setting)? = decoded.kind else {
                            AppLogWarn("[phi-sync] remote entity carries no settings payload; ignoring")
                            view = .unusable(reason: .foreignPayload)
                            continue
                        }
                        view = .usable(setting)
                    } catch {
                        // Wrong key (a re-mint this device has not caught up with, or a peer
                        // sealing with an envelope version this build rejects) or corrupt
                        // bytes. Never apply it, and never publish over it.
                        AppLogError("[phi-sync] cannot open remote entity version=\(entity.version) ciphertext_bytes=\(entity.ciphertext.count) (\(PhiSyncLog.describe(error)))")
                        view = .unusable(reason: .undecryptable)
                    }
                }
                more = response.changesRemaining
                page += 1
                if recordsGatedMarkerMoves, !markerMoveRecorded, storedMarker != markerAtEntry {
                    // A page that advanced the shared marker while the gate was shut.
                    // Recorded without inspecting its contents on purpose: deciding "did this
                    // page hold a Space?" needs a decrypt, and an entity this build cannot
                    // decrypt is exactly one of the things that gets missed.
                    //
                    // Written here rather than at the round's tail because the marker advance
                    // is already durable: if a later page throws, the record of the move must
                    // not go with it, or the next gate-open takes neither disjunct in
                    // `applySpaceGate`, never replays, and whatever this page walked past is
                    // lost on this device until some peer touches it again.
                    markerMoveRecorded = true
                    mutateSpaceTable { $0.markerMovedWhileGateShut = true }
                }
            }
            drained = !more
            if spaceLive, drained {
                mutateSpaceTable { table in
                    guard table.drainInProgress else { return }
                    table.drainInProgress = false
                    table.hasDrainedFullReplay = true
                    table.lastDrainedBirthday = storedBirthday
                }
            }
        } catch PhiSyncProtocolError.notMyBirthday {
            // Nothing to flush: the store those pages came from is gone, and
            // `resetForNewStoreBirthday()` clears the Space table's server-side state and its
            // unreadable-tag record wholesale.
            resetForNewStoreBirthday()
            guard retryOnBirthday else { return false }
            return await pull(retryOnBirthday: false, thenPush: thenPush)
        } catch {
            AppLogError("[phi-sync] pull failed device=\(deviceKeyId) (\(PhiSyncLog.describe(error)))")
            // The pages that did land advanced the shared marker for good, so what this round
            // learned about them has to outlive the failure.
            if spaceLive {
                flushSpaceObservations(batch)
                // ...and what it did NOT persist has to invalidate the drain. A round that
                // threw mid-way consumed its pages — the marker moved past them — while
                // everything the routing decoded from them (`batch.decoded` /
                // `batch.tombstones`, the apply path's input) died with the throw. That is a
                // GAP in the replay, not progress through it. Left alone, a later round would
                // resume from the advanced marker, reach `drained == true` and stamp
                // `hasDrainedFullReplay = true` over the hole; from that point neither
                // disjunct in `applySpaceGate` can ever re-arm the replay
                // (`markerMovedWhileGateShut` is false because the gate never shut, and
                // `hasDrainedFullReplay` is true), so the entities this round dropped would be
                // missing on this device until some peer touched them again — and the guard
                // that reads `hasDrainedFullReplay` before publishing would be answering for a
                // Space set this device never fully received.
                //
                // Dropping the marker restarts the replay from scratch instead. It is the
                // self-healing direction: `drainInProgress` deliberately stays true, so no
                // round in between may declare the drain complete, and the only cost of a
                // false positive is re-reading pages this device has already seen.
                if loadSpaceTable().drainInProgress {
                    AppLogWarn("[phi-sync] a drain of data type \(PhiSyncEntity.dataTypeID) was interrupted; replaying it rather than resuming past the gap")
                    storedMarker = nil
                }
            }
            return false
        }

        var maySettingsPublish = true
        switch view {
        case .usable(let remote):
            tombstoneRounds = 0
            // Wholesale only until this device has settings history of its own — which is
            // `hasAdopted`, not "do we know which row they live in": a cursor dropped by the
            // tombstone heal or the full-replay branch below must not cost this device its
            // local timestamps. See `apply` and `hasAdopted`.
            apply(remote, adopt: !hasAdopted)
        case .unusable(let reason):
            // The server holds bytes under our client tag that this build cannot read. Not
            // applying them is only half the job: the trailing push must not run either,
            // because it would commit this device's snapshot against the id and version we
            // just harvested from that very entity and replace it for every other device —
            // including the keys of a newer client that this build does not understand.
            // Rewinding the marker makes the next round see the entity again, so a re-minted
            // domain key or a newer build heals this instead of it being terminal.
            storedMarker = nil
            // The baseline goes with the marker, and that is what makes the refusal durable
            // rather than a one-round suppression. `push`'s guard reads "an entity id with no
            // baseline" as "the server holds bytes this device has not read"; a device that
            // had synced before would otherwise keep the baseline it decrypted at an older
            // version, and the next debounced local change — or the conflict retry, which
            // reaches `push` with `allowInitialPull: false` and never sees `maySettingsPublish` —
            // would commit over the unreadable entity using the id and version harvested from
            // it right here. `storedEntityId` survives (the server always sends a non-empty
            // `id_string`: internal/chromiumsync/getupdates.go toSyncEntity, from the UUID
            // commit.go assigns on create), so `hasSyncedBefore` stays true and no
            // `version = 0` create can slip past the guard either. `apply` re-establishes the
            // baseline as soon as a pull can read the entity again.
            storedLastEntity = nil
            maySettingsPublish = false
            noteUnusable(reason)
        case .absent:
            tombstoneRounds = 0
            if drained, startedFromScratch, storedEntityId != nil {
                // A full replay carried no settings entity: the row this device points at is
                // gone (a namespace change, a targeted delete, a partial restore). Keeping the
                // id would make every later commit an update the server answers with
                // INVALID_MESSAGE forever; dropping it lets the next push create instead.
                AppLogWarn("[phi-sync] full replay carried no settings entity; dropping the stale entity cursor")
                clearEntityCursor()
            }
        }

        if spaceLive {
            flushSpaceObservations(batch)
            mutateSpaceTable { table in
                // Guard 2, trigger 2: the account plist was lost or restored from a backup.
                // Guarded by a ONE-SHOT flag, never by `hadRecords` / `hasDrainedFullReplay`:
                // an account whose Space entities all fail to decrypt keeps `cursors` empty
                // and `hadRecords` true forever, and would drop the marker and replay on every
                // single round.
                if table.cursors.isEmpty, table.hadRecords, !table.didReplayForEmptyTable {
                    AppLogWarn("[phi-sync] space table is empty but had records; replaying data type \(PhiSyncEntity.dataTypeID) once")
                    table.didReplayForEmptyTable = true
                    storedMarker = nil
                    table.hasDrainedFullReplay = false
                    table.drainInProgress = true
                }
                if !table.cursors.isEmpty { table.hadRecords = true }
            }

            // The apply path is the one Space write that cannot be expressed as a
            // `mutateSpaceTable` delta: `applySpaces` hops to the main actor on
            // every landing, so its table copy necessarily spans suspension
            // points. One load / apply / write is safe *here* and only here —
            // rounds are serialized (`serialized(_:)` chains them; the gate edge
            // and BOTH main-thread Space intents are themselves rounds), and
            // this is the last Space work of the round, so nothing can touch the
            // table between the load and the write.
            //
            // It MUST sit after `flushSpaceObservations(batch)` and after the
            // block above, and both orderings are load-bearing:
            //  1. `applySpaces` clears `unreadableTagHashes` for every uuid it
            //     lands. Loading after the flush is what makes "the refusal lifts
            //     by itself" true instead of racing this round's own record of
            //     the same hash.
            //  2. `applySpaces` writes cursors, so running it before guard 2
            //     would make `table.cursors.isEmpty` false and silently disable
            //     the one-shot empty-table replay. The cost is that cursors
            //     created this round only set `hadRecords` on the NEXT round,
            //     which is harmless: `hadRecords` exists to describe a table that
            //     was populated and then lost.
            var spaceTable = loadSpaceTable()
            spaceCounters.pulled += batch.decoded.count + batch.tombstones.count
            await applySpaces(batch, table: &spaceTable)
            await applySpaceTombstones(batch, table: &spaceTable)
            writeSpaceTable(spaceTable)
        }
        // The gated-off round's `markerMovedWhileGateShut` needs no write here: it was
        // persisted by the page that observed it.

        // Publish whatever the merge left the server short of (a locally newer value, or a
        // registered key the remote entity did not carry). `push` decides by comparison, so a
        // pure remote apply commits nothing. Settings only: whether the Space section may
        // publish is its own question (§5.5 guard 1), and the two must not be able to silence
        // each other — an unreadable settings entity says nothing about the Spaces.
        // So the two halves are called separately here rather than through the `push` wrapper:
        // `maySettingsPublish == false` means "the SETTINGS row on the server is bytes this
        // build cannot read", and letting it gate the Space section too is exactly the coupling
        // §5.2 改动三 forbids. `pushSpaces` carries every Space-side guard of its own (the gate,
        // the drain, guard 3), so calling it unconditionally is safe — on a settings-only
        // engine (`spaceStore == nil`) it returns on its first line.
        if thenPush {
            if maySettingsPublish {
                await pushSettings(retryOnConflict: false, allowInitialPull: false)
            }
            await pushSpaces(retryOnConflict: false)
        }

        if !drained, followUpRoundsUsed < Self.maxFollowUpRounds {
            // The page budget ran out with `changes_remaining` still set. Wait out the 60 s
            // timer and a first sync turns into minutes; the follow-up continues from the
            // marker this round already advanced.
            followUpRoundsUsed += 1
            Task { [weak self] in await self?.pullOnce() }
        } else if drained {
            followUpRoundsUsed = 0
        }
        return true
    }

    /// What one pull collected for the Space section.
    private struct SpacePullBatch {
        var decoded: [(uuid: String, entity: Phi_PhiSpaceEntity, entityId: String, version: Int64)] = []
        var tombstones: [(uuid: String, entityId: String, version: Int64)] = []
        var unreadableHashes: [String] = []
        var unknownTombstoneHashes: [String] = []
    }

    /// Persists what this round's routing learned about entities the shared marker has
    /// already moved past. Called on the pull's tail *and* from its failure path, because the
    /// marker advance those observations describe is durable either way: a hash recorded only
    /// on the success path is lost by the throw that follows it, and nothing will ever deliver
    /// that entity again.
    private func flushSpaceObservations(_ batch: SpacePullBatch) {
        guard !batch.unreadableHashes.isEmpty else { return }
        let seenAt = now()
        mutateSpaceTable { table in
            for hash in batch.unreadableHashes { table.unreadableTagHashes[hash] = seenAt }
        }
    }

    /// `client_tag_hash -> space_uuid`, rebuilt once per pull. A tombstone carries no
    /// ciphertext and no `space_uuid`, and SHA1 is one-way, so a remote delete can only be
    /// identified by looking its hash up in a table this device builds from the uuids it
    /// already knows.
    ///
    /// D6：种子是**游标键 ∪ 映射表的值 ∪ 常量 `"default-space"`**。映射值那一项是
    /// 必须的：一个刚被向导映射、还没 commit 过的 Space 没有游标，而账户里那条实体
    /// 的 tombstone 随时可能先到。**本地 Space 列表不再进种子**——D6 之后它塞进去的
    /// 是永远不会出现在线上的本地 id，只会让索引变大且误导读者。
    private func spaceTagIndex(table: PhiSpaceSyncTable) async -> [String: String] {
        var uuids = Set(table.cursors.keys)
        uuids.insert(SyncableSpaces.defaultSpaceUuid)
        if let spaceAccess {
            for uuid in await spaceAccess.allSpaceMappings().values { uuids.insert(uuid) }
        }
        var index: [String: String] = [:]
        for uuid in uuids {
            index[PhiSyncEntity.clientTagHash(for: PhiSyncEntity.spaceClientTag(uuid))] = uuid
        }
        return index
    }

    /// §5.2 steps 2-5, in this exact order.
    private func routeSpaceEntity(_ entity: PhiRemoteEntity,
                                  key: SymmetricKey,
                                  tagIndex: [String: String],
                                  into batch: inout SpacePullBatch) {
        let shortHash = String(entity.clientTagHash.prefix(8))

        // 2. Tombstone FIRST, before any decrypt attempt. A deleted row's specifics are the
        // type's default value the server backfilled, so its ciphertext is empty and
        // decrypting it necessarily throws — routing it after the decrypt would classify every
        // remote delete as "unreadable" and, since the marker has already moved past this
        // page, lose it forever.
        guard !entity.deleted else {
            guard let uuid = tagIndex[entity.clientTagHash] else {
                // Nothing to hide: this device has neither the row nor a cursor, and the
                // server has already replaced the specifics, so no create for that row can
                // ever arrive again.
                AppLogInfo("[phi-sync] ignoring a tombstone for an unknown tag hash=\(shortHash)")
                batch.unknownTombstoneHashes.append(entity.clientTagHash)
                return
            }
            batch.tombstones.append((uuid: uuid, entityId: entity.entityId, version: entity.version))
            return
        }

        // 3. Decrypt.
        let decoded: Phi_PhiEntity
        do {
            decoded = try PhiEntityCodec.decrypt(entity.ciphertext, key: key)
        } catch {
            AppLogWarn("[phi-sync] cannot open a space entity tag=\(shortHash) ciphertext_bytes=\(entity.ciphertext.count) (\(PhiSyncLog.describe(error)))")
            batch.unreadableHashes.append(entity.clientTagHash)
            return
        }

        // 4. Unknown kind: ignore ONLY this entity. With two kinds live, a newer client's
        // third kind is normal traffic — the settings path's `.foreignPayload` reaction
        // (rewind the marker, drop the baseline, suppress the trailing push) would drag
        // settings down with it.
        guard case .space(let space)? = decoded.kind else { return }

        // 5. The payload must hash back to the tag it arrived under.
        let expected = PhiSyncEntity.clientTagHash(for: PhiSyncEntity.spaceClientTag(space.spaceUuid))
        guard expected == entity.clientTagHash else {
            AppLogError("[phi-sync] space payload does not hash back to its tag=\(shortHash)")
            batch.unreadableHashes.append(entity.clientTagHash)
            return
        }
        batch.decoded.append((uuid: space.spaceUuid, entity: space,
                              entityId: entity.entityId, version: entity.version))
    }

    // MARK: - Space apply (§6.2 A0-A3)

    /// Lands everything one pull collected. Never throws: a failed landing parks
    /// its entity and the round moves on.
    private func applySpaces(_ batch: SpacePullBatch, table: inout PhiSpaceSyncTable) async {
        guard !isStopped, let spaceAccess else { return }

        // §3.5 fallback A is transient by design. As soon as a held binding
        // resolves -- §3.6 created the profile, or a dead mapping was rebuilt --
        // re-land the baseline so the row actually moves onto that profile.
        // Without this the hold survives (no new entity for that uuid will ever
        // arrive: the shared marker has moved past it) and the Space stays bound
        // to the wrong profile forever.
        //
        // These entities go to the loop below DIRECTLY rather than through
        // `cursor.pendingApply`, and carry `fromServer: false`. A re-park is this
        // device's own baseline, NOT something the server sent, and `pendingApply`
        // holds bytes with no room for that distinction. Landing one must
        // therefore leave `server` alone: recording the local baseline as "what
        // the server holds" makes `spaceCommitEntries`' `toSend == server`
        // permanently true for every field this device still owes the account,
        // and the owed value is never published again.
        var reparked: [String: Phi_PhiSpaceEntity] = [:]
        for (uuid, cursor) in table.cursors {
            guard let held = cursor.heldProfileUuid,
                  cursor.pendingApply == nil,
                  let bytes = cursor.reconciled,
                  let entity = try? Phi_PhiSpaceEntity(serializedBytes: bytes),
                  await spaceAccess.localProfileId(forGlobalUuid: held) != nil else { continue }
            reparked[uuid] = entity
        }

        // Everything parked earlier is retried alongside this round's arrivals,
        // oldest cursor first so ordering is device-independent.
        var pending: [(uuid: String, entity: Phi_PhiSpaceEntity, entityId: String,
                       version: Int64, fromServer: Bool)] = []
        for (uuid, cursor) in table.cursors.sorted(by: { $0.key < $1.key }) {
            if let entity = reparked[uuid] {
                pending.append((uuid: uuid, entity: entity, entityId: cursor.entityId ?? "",
                                version: cursor.version, fromServer: false))
                continue
            }
            guard let bytes = cursor.pendingApply,
                  let entity = try? Phi_PhiSpaceEntity(serializedBytes: bytes) else { continue }
            pending.append((uuid: uuid, entity: entity, entityId: cursor.entityId ?? "",
                            version: cursor.version, fromServer: true))
        }
        let incoming = batch.decoded.sorted { $0.uuid < $1.uuid }
            .map { (uuid: $0.uuid, entity: $0.entity, entityId: $0.entityId,
                    version: $0.version, fromServer: true) }
        let all = pending.filter { p in !incoming.contains { $0.uuid == p.uuid } } + incoming

        var landedAny = false
        for item in all {
            guard !isStopped else { return }
            var cursor = table.cursors[item.uuid] ?? PhiSpaceCursor()
            // R12: every Space log line names the entity by its client tag hash
            // prefix, never by the `space_uuid` it was derived from.
            let tag = PhiSyncEntity.clientTagHash(for: PhiSyncEntity.spaceClientTag(item.uuid))

            // §6.5: refuse to materialize agent / incognito payloads. Refusing is
            // NOT a claim the account should not hold it, so no tombstone is ever
            // pushed back; `refusedAtMs` only stops the re-decrypt every round.
            if SyncableSpaces.refuses(item.entity) {
                cursor.refusedAtMs = now()
                cursor.pendingApply = nil
                table.cursors[item.uuid] = cursor
                spaceCounters.refused += 1
                continue
            }
            // A soft-deleted uuid is never resurrected by a replayed create.
            if cursor.deletedAtMs != nil { cursor.pendingApply = nil; table.cursors[item.uuid] = cursor; continue }

            // A0: resolve the binding. From Task 11 on the mapping is refreshed
            // earlier in the SAME round (§5.2), so a Space bound to a profile the
            // peer just created lands without waiting for the next one.
            let isDefault = item.uuid == SyncableSpaces.defaultSpaceUuid
            // D6：把线上 uuid 翻成本机的行 id。解析不到 = 账户里有、本机没有，
            // 落地时新建一行并回写映射（R-D6-7）。
            var localSpaceId = await spaceAccess.localSpaceId(forSyncUuid: item.uuid)
            // 默认 Space 的身份是 resolver 里的常量分支（SpaceSyncMappingManager.swift:53-60），
            // 没有映射行可丢；对它跑自愈只会把它当成新 Space 重铸一个本地 id。
            if !isDefault, let resolved = localSpaceId, await !spaceAccess.isKnownLocalSpace(resolved) {
                // 死映射：反查命中，但本地那一行已经没了（用户删了 Space 而清理路径
                // 被打断）。就地丢掉并按「无映射」处理，下一轮当作新 Space 落地。
                // 形状与 profile 侧的 A0 逐字对应。
                AppLogInfo("[phi-sync] dropping a dead space mapping; the entity will land as a new Space")
                await spaceAccess.dropSpaceMapping(forSpaceId: resolved)
                localSpaceId = nil
            }
            var profileId: String?
            if !isDefault {
                let remoteUuid = item.entity.profileUuid.stringValue
                profileId = await spaceAccess.localProfileId(forGlobalUuid: remoteUuid)
                if let resolved = profileId, await !spaceAccess.isKnownLocalProfile(resolved) {
                    // A DEAD MAPPING: the reverse lookup resolved, but the local
                    // Chromium profile behind it was deleted (§3.6's "唯一的例外,
                    // 也是死映射的唯一自愈路径"). The criterion has to be "is it
                    // still in `userAssignableProfiles`" -- asking
                    // `globalUuid(forProfileId:)` would read back the very mapping
                    // the reverse lookup just resolved FROM and always say yes,
                    // i.e. never fire.
                    //
                    // Drop the entry here and treat the binding as unresolved.
                    // Next round §3.6's `missing` set contains that uuid again and
                    // rebuilds the profile under its registered name; without the
                    // drop, every landing throws on a profileId that no longer
                    // exists, the entity parks forever, and `parked` sits non-zero
                    // with no self-heal path at all.
                    AppLogInfo("[phi-sync] dropping a dead profile mapping; the account profile will be rebuilt next round")
                    await spaceAccess.dropMapping(forProfileId: resolved)
                    profileId = nil
                }
                if profileId == nil {
                    if cursor.reconciled == nil {
                        // Fallback B: never a row, never a baseline, never
                        // `refusedAtMs` -- park the whole entity and retry.
                        cursor.pendingApply = try? item.entity.serializedData()
                        cursor.entityId = item.entityId.isEmpty ? cursor.entityId : item.entityId
                        cursor.version = max(cursor.version, item.version)
                        table.cursors[item.uuid] = cursor
                        continue
                    }
                    // Fallback A: already landed. Keep the local binding, record
                    // the remote value, and echo it back with the BASELINE's
                    // timestamp (see `SyncableSpaces.snapshot`) so this device
                    // neither wins the field nor pings the binding back and forth.
                    // The local profile the hold is taken against is recorded with
                    // it: a later LOCAL rebind must be publishable (§3.5).
                    cursor.heldProfileUuid = remoteUuid
                    cursor.heldForLocalProfileId =
                        await spaceAccess.currentSpaces().first { $0.spaceId == localSpaceId }?.profileId
                } else {
                    // The binding resolves: any hold is obsolete. Clearing it here
                    // is the other half of §3.5 -- a stale hold would keep winning
                    // the snapshot's held branch over the mapping-derived value.
                    cursor.heldProfileUuid = nil
                    cursor.heldForLocalProfileId = nil
                }
            }

            // A1: no baseline -> adopt wholesale. A device with no timestamp
            // history that merged field by field would stamp its factory defaults
            // `now` and push them over the account's real values.
            let existing = await spaceAccess.currentSpaces().first { $0.spaceId == localSpaceId }
            let merged: Phi_PhiSpaceEntity
            if let bytes = cursor.reconciled,
               let baseline = try? Phi_PhiSpaceEntity(serializedBytes: bytes) {
                merged = SyncableSpaces.merge(local: baseline, remote: item.entity)
            } else {
                merged = item.entity
            }

            // A2 + A3: land in order, await every step, and only THEN write the
            // baselines. The reverse order leaves the shadow ahead of the row and
            // the next snapshot stamps the stale value `now` for the whole account.
            let landed: String
            do {
                landed = try await SyncableSpaces.land(merged, existing: existing,
                                                       localSpaceId: localSpaceId,
                                                       profileId: profileId, access: spaceAccess)
            } catch {
                AppLogWarn("[phi-sync] space landing failed tag=\(String(tag.prefix(8))) (\(PhiSyncLog.describe(error)))")
                // A re-parked baseline is deliberately NOT written to
                // `pendingApply`: next round it would be indistinguishable from a
                // server entity and would be recorded as `server` on the retry.
                // Discarding this round's cursor edits instead leaves the hold
                // exactly as it was, so the re-park pass above picks it up again.
                if item.fromServer {
                    cursor.pendingApply = try? item.entity.serializedData()
                    table.cursors[item.uuid] = cursor
                }
                continue
            }
            guard !isStopped else { return }
            // **落地成功之后、写基线之前**才写映射（§5.6 同一条规则）：`create` 抛错
            // 时既不写基线也不写映射，下一轮从 `pendingApply` 重试，重试会再次走
            // create 分支——因为没有映射行，不会撞上一个半成品。
            if localSpaceId == nil {
                do {
                    try await spaceAccess.mapSpace(landed, toSyncUuid: item.uuid)
                } catch {
                    AppLogWarn("[phi-sync] could not map a landed space tag=\(String(tag.prefix(8))) (\(PhiSyncLog.describe(error)))")
                    if item.fromServer {
                        cursor.pendingApply = try? item.entity.serializedData()
                        table.cursors[item.uuid] = cursor
                    }
                    continue
                }
            }

            // §5.6 again, for the one write that can report success without
            // having happened: `SpaceManager.applyRemoteRebind` optional-chains
            // through `boundAccount`, so a nil account returns normally and
            // writes nothing, and `prepareProfileChange` is documented to refuse
            // silently (an import in flight, an agent Space) with "the entity is
            // retried next round" -- which is only true if this round declines to
            // write a baseline. Verify the field that has that out-of-band
            // refusal path rather than trusting the return, and park otherwise.
            if !isDefault, let profileId, let existing, existing.profileId != profileId,
               await spaceAccess.currentSpaces().first(
                   where: { $0.spaceId == landed })?.profileId != profileId {
                AppLogWarn("[phi-sync] space rebind did not take effect tag=\(String(tag.prefix(8))); parking the entity")
                if item.fromServer {   // same reason as the landing-failure park above
                    cursor.pendingApply = try? item.entity.serializedData()
                    table.cursors[item.uuid] = cursor
                }
                continue
            }

            cursor.reconciled = try? merged.serializedData()
            // `remote`, NOT `merged`: this is "what the server holds", the
            // comparison that decides whether anything still needs publishing.
            // And only for an entity that actually CAME from the server: the
            // held re-park above re-lands this device's own baseline, which says
            // nothing about the server's copy and must leave it untouched.
            if item.fromServer { cursor.server = try? item.entity.serializedData() }
            if !item.entityId.isEmpty { cursor.entityId = item.entityId }
            cursor.version = max(cursor.version, item.version)
            cursor.pendingApply = nil
            table.cursors[item.uuid] = cursor
            table.unreadableTagHashes.removeValue(forKey: tag)
            landedAny = true
            spaceCounters.applied += 1
        }

        // One account-wide reorder after every entity landed (§7).
        if landedAny {
            // D6 的翻译点在这里，不在 `plannedOrder` 里：`ranks` 由游标键构建
            // （syncUuid），而 `plannedOrder` 拿 `syncedRanks[spaceId]` 与**本地** id
            // 比。半翻译是静默失效——每次查表都是 nil，账户级重排整体变成 no-op。
            var ranks: [String: String] = [:]
            for (uuid, cursor) in table.cursors {
                guard cursor.hidden == false, cursor.deletedAtMs == nil,
                      let bytes = cursor.reconciled,
                      let entity = try? Phi_PhiSpaceEntity(serializedBytes: bytes) else { continue }
                guard let local = await spaceAccess.localSpaceId(forSyncUuid: uuid) else { continue }
                ranks[local] = entity.rank.stringValue
            }
            // `allSpacesForOrdering()`, NOT `currentSpaces()`: the result goes
            // straight to `LocalStore.reorderSpaces`, which renumbers exactly the
            // ids it is given and leaves every other row's `sortOrder` untouched.
            // Handing it the §6.5-filtered view would renumber the synced Spaces
            // 0..n-1 while agent Spaces and Spaces on unmapped profiles kept stale
            // values and interleaved arbitrarily -- the opposite of §7's "keep
            // their own slots".
            let order = SyncableSpaces.plannedOrder(
                localOrder: await spaceAccess.allSpacesForOrdering(), syncedRanks: ranks)
            try? await spaceAccess.applyOrder(order)
        }
    }

    /// Remote deletes (§9.2): the pull routes them into `batch.tombstones` and
    /// this is where they are hidden locally and the cursor becomes a tombstone
    /// record.
    ///
    /// A remote delete is a first-class product event for Spaces, not the hazard
    /// the settings path treats it as: no `tombstoneRounds`, no three-round heal,
    /// no suppression of the trailing push.
    private func applySpaceTombstones(_ batch: SpacePullBatch, table: inout PhiSpaceSyncTable) async {
        guard !isStopped, let spaceAccess else { return }
        // Everything deferred by an import lock is retried alongside this round's
        // arrivals: the shared marker has already moved past those pages, so the
        // same tombstone will never be delivered again.
        var work = batch.tombstones
        for (uuid, cursor) in table.cursors.sorted(by: { $0.key < $1.key })
        where cursor.pendingTombstone && !work.contains(where: { $0.uuid == uuid }) {
            work.append((uuid: uuid, entityId: cursor.entityId ?? "", version: cursor.version))
        }

        for item in work {
            guard !isStopped else { return }
            // D1: the default Space cannot be deleted locally (`deleteSpace`
            // refuses at SpaceManager.swift:1362) and by definition cannot be
            // deleted remotely either. `item.uuid` is a syncUuid, so the constant
            // it is compared against is the syncUuid-space one (§2.4).
            guard item.uuid != SyncableSpaces.defaultSpaceUuid else {
                AppLogInfo("[phi-sync] ignoring a tombstone for the default Space")
                continue
            }
            var cursor = table.cursors[item.uuid] ?? PhiSpaceCursor()
            if let entityId = cursor.entityId, !item.entityId.isEmpty, entityId != item.entityId {
                // The server never rewrites `client_tag_hash` on an update
                // (`internal/data/entities_write.go:243-244`), so the hash is the
                // stable identity and the id is only a cross-check.
                AppLogError("[phi-sync] tombstone entity id disagrees with the cursor; trusting the tag hash")
            }
            guard cursor.deletedAtMs == nil else {
                cursor.pendingTombstone = false
                table.cursors[item.uuid] = cursor
                continue
            }

            // D6：先把线上 uuid 翻成本机的行 id。**解析不到就跳过导入锁检查与
            // hide**，直接走游标收尾——账户里那条确实被删了，这台机器只是本来就没有
            // 它，游标必须记住，否则同一条实体的 create 重放会把它复活。
            let localSpaceId = await spaceAccess.localSpaceId(forSyncUuid: item.uuid)
            if let localSpaceId {
                if await spaceAccess.isImporting(intoSpaceId: localSpaceId) {
                    // No modal: nobody is there to see it. Persist the intent instead.
                    cursor.pendingTombstone = true
                    table.cursors[item.uuid] = cursor
                    continue
                }
                do {
                    // Windows first, so a window parked on this Space retreats along
                    // the existing fallback path instead of vanishing under the user.
                    try await spaceAccess.hide(spaceId: localSpaceId)
                } catch {
                    cursor.pendingTombstone = true
                    table.cursors[item.uuid] = cursor
                    continue
                }
            }
            // R-D6-10：**这里不删映射行**。远端软删保留映射——它是那 30 天里「这一行
            // 属于账户的哪条实体」的唯一记录，也是 `snapshot` 的 eligible 过滤能把这
            // 一行排除在外的唯一依据；30 天清理成功之后才删（`applyRetentionSweep`）。
            cursor.hidden = true
            cursor.deletedAtMs = now()
            cursor.pendingTombstone = false
            // The landing is TERMINAL for this uuid, so it writes the same
            // finished state §6.2 writes for a tombstone of our own: a local
            // delete queued a moment earlier (`recordLocalDeletion`) is owed to
            // nobody now that the account already holds the tombstone.
            // `spaceCommitEntries` unions EVERY `pendingDelete` cursor into the
            // next batch, so a flag left standing here ships a redundant
            // `deleted: true` commit whose `.applied` outcome re-stamps
            // `deletedAtMs = now()` -- restarting §9.2's 30-day window from the
            // echo instead of from the delete.
            cursor.pendingDelete = false
            cursor.deleteRejectRounds = 0
            cursor.pendingApply = nil
            cursor.heldProfileUuid = nil
            cursor.heldForLocalProfileId = nil
            if !item.entityId.isEmpty { cursor.entityId = item.entityId }
            cursor.version = max(cursor.version, item.version)
            table.cursors[item.uuid] = cursor
            spaceCounters.applied += 1   // §11: a remote soft delete is a landing
            // A soft delete IS a successful interpretation of that tag.
            table.unreadableTagHashes.removeValue(forKey:
                PhiSyncEntity.clientTagHash(for: PhiSyncEntity.spaceClientTag(item.uuid)))
            // Deliberately silent: a local delete has a confirmation dialog, a
            // remote one has no alert, no toast and no hint. And no data is
            // touched -- SpaceModel, bookmarks, pin tabs, URL rules and both theme
            // maps stay on disk for the whole retention window.
            AppLogInfo("[phi-sync] space soft-deleted by a remote tombstone")
        }
    }

    /// Records a pull that could not read the account's entity, and — for a tombstone only —
    /// arms the heal once the row has been gone for `tombstoneHealAfterRounds` consecutive
    /// pulls. Arming just drops the entity cursor: this never publishes anything, so a
    /// deliberate deletion survives until some device actually changes a setting, and only then
    /// does the commit go out as a create (`baseVersion = 0`, no entity id) that the server
    /// resolves through its `ON CONFLICT (client_tag_hash) DO UPDATE` path.
    ///
    /// Logged at error level: both refusals leave settings sync dead for the whole account, and
    /// `AppLogWarn`/`AppLogError` are the only levels that reach the shipped log file (release
    /// installs the loggers at `.info`, `Logging.swift`), so this is the one support-visible
    /// trace of a state the user cannot see or fix.
    private func noteUnusable(_ reason: UnusableReason) {
        guard reason == .tombstone else {
            // Real content this build must not overwrite; nothing here may re-create it, and a
            // non-tombstone round breaks the streak.
            tombstoneRounds = 0
            AppLogError("[phi-sync] settings entity is unusable (\(reason.rawValue)); not applying it and not publishing over it")
            return
        }
        let rounds = tombstoneRounds + 1
        tombstoneRounds = rounds
        guard rounds >= Self.tombstoneHealAfterRounds else {
            AppLogWarn("[phi-sync] settings entity is a tombstone (round \(rounds)/\(Self.tombstoneHealAfterRounds)); not applying it and not publishing over it")
            return
        }
        AppLogError("[phi-sync] settings entity has been a tombstone for \(rounds) consecutive pulls; dropping the entity cursor so the next local change re-creates it")
        clearEntityCursor()
    }

    private func apply(_ remote: Phi_PhiSettingEntity, adopt: Bool) {
        // A retired engine decrypted these settings with the signed-out account's domain key;
        // writing them now would hand the account mounted next the previous account's values.
        // This entry check only saves the merge work — `shutdown()` is concurrent with this
        // round, so what actually stops the writes is the check each of them makes for itself
        // (`snapshotLocalSettings`, `writeSettings`, `writeState`).
        guard !isStopped else { return }
        // A device with no settings history has no timestamps to compare against: every key it
        // snapshots would be stamped `now` and beat the account's real edits. So the first pull
        // adopts the account's entity wholesale; later pulls merge field by field.
        let merged: Phi_PhiSettingEntity
        if adopt {
            merged = remote
        } else {
            guard let local = snapshotLocalSettings() else { return }
            merged = SyncableSettings.merge(local: local, remote: remote)
        }

        guard writeSettings(merged) else { return }

        // What the server holds, not what we now hold locally: `push` compares against this to
        // decide whether anything still needs publishing.
        storedLastEntity = remote
        // `apply` leaves a `<key>.phiSyncTs` sidecar behind for every key it wrote, so from
        // here on this device has timestamps a merge can compare — no later pull may adopt.
        hasAdopted = true
        AppLogInfo("[phi-sync] applied remote settings keys=\(merged.values.count)")
    }

    // MARK: - Push

    /// One round's publish step: the settings half first (unchanged M3-1
    /// behaviour), then the Space half — unconditionally, whatever the settings
    /// half decided.
    ///
    /// The two must be siblings rather than one appended to the other. Every
    /// early return in `pushSettings` is a statement about the SETTINGS entity,
    /// and one of them is the steady state: `if let last, outgoing == last` fires
    /// on almost every round, because the user changed a Space and not a setting.
    /// A Space push hanging off the end of that function would therefore never
    /// run in exactly the case it exists for (§5.2 改动三).
    private func push(retryOnConflict: Bool, allowInitialPull: Bool) async {
        await pushSettings(retryOnConflict: retryOnConflict, allowInitialPull: allowInitialPull)
        await pushSpaces(retryOnConflict: retryOnConflict)
    }

    /// The settings half: M3-1's `push`, renamed and otherwise untouched.
    private func pushSettings(retryOnConflict: Bool, allowInitialPull: Bool) async {
        guard !isStopped else { return }
        // A `version = 0` commit takes the server's ON CONFLICT (client_tag_hash) DO UPDATE
        // path, which overwrites whatever is there. A device that has never synced must
        // discover the account's entity first or it silently clobbers every other device.
        if allowInitialPull, !hasSyncedBefore {
            guard await pull(retryOnBirthday: true, thenPush: false) else {
                AppLogWarn("[phi-sync] first push aborted: the account's current settings could not be read")
                return
            }
        }

        // A round that knows the server holds bytes it could not decode must not overwrite
        // them. `storedLastEntity` is the decrypted baseline of what the server has; an entity
        // id with no baseline means the last pull saw the entity but could not read it (bad
        // key, foreign payload, tombstone — that pull drops the baseline precisely so this
        // guard fires; a tombstone that has outlasted `tombstoneHealAfterRounds` pulls drops
        // the id too, so this guard lets that one create), or the baseline was lost with the
        // process. Committing here would
        // replace the entire entity — every key, including a newer client's — with this
        // device's snapshot. Rewind the marker so the next pull re-reads the entity and can
        // re-establish the baseline.
        //
        // This returns before `SyncableSettings.snapshot` runs, so a local change made while
        // the entity is unreadable leaves no `<key>.phiSyncTs` sidecar and never sets
        // `hasAdopted`. That is deliberate, and it has a cost on the one device that has no
        // other settings history — see `hasAdopted` for the window and why stamping here would
        // lose more than it saves.
        if storedEntityId != nil, storedLastEntity == nil {
            AppLogWarn("[phi-sync] push skipped: no readable baseline for the settings entity the server holds")
            storedMarker = nil
            return
        }

        let key: SymmetricKey
        do {
            key = try await domainKeys.domainKey()
        } catch {
            AppLogWarn("[phi-sync] push skipped: domain key unavailable (\(PhiSyncLog.describe(error)))")
            return
        }
        // Nothing below suspends before `client.commit`, so this check is the last thing that
        // can keep a retired round from publishing the signed-out account's settings — the
        // token provider behind the client now mints the *new* account's bearer token. It
        // cannot be airtight (a `shutdown()` landing between here and URLSession's send is not
        // seen), which `shutdown()` documents; what it does rule out is a round that resumed
        // from the network long after sign-out going on to commit.
        guard !isStopped else { return }

        let last = storedLastEntity
        // A snapshot is a write too — it stamps the sidecars — so it makes its own check.
        guard let local = snapshotLocalSettings() else { return }
        // Merging against the last known server entity keeps keys this build does not know
        // about (a newer client's settings) instead of deleting them on every push.
        let outgoing = SyncableSettings.merge(local: local, remote: last ?? Phi_PhiSettingEntity())
        if let last, outgoing == last { return }

        var wrapper = Phi_PhiEntity()
        wrapper.setting = outgoing

        do {
            let ciphertext = try PhiEntityCodec.encrypt(wrapper, key: key)
            // The settings entity is still exactly one entry: a one-element batch, committed
            // under `phi-settings` as before. `name` moved from the client into the entry, so
            // it is spelled out here rather than defaulted.
            let outcomes = try await client.commit(entries: [
                PhiCommitEntry(entityId: storedEntityId,
                               clientTagHash: PhiSyncEntity.settingsClientTagHash,
                               name: PhiSyncEntity.clientTag,
                               ciphertext: ciphertext,
                               deleted: false,
                               baseVersion: storedVersion ?? 0),
            ], storeBirthday: storedBirthday)
            guard !isStopped else { return }
            guard let outcome = outcomes.first else {
                throw PhiSyncProtocolError.malformedResponse
            }
            switch outcome {
            case .applied(let entityId, let version, let storeBirthday):
                if !entityId.isEmpty { storedEntityId = entityId }
                storedVersion = version
                storedBirthday = storeBirthday
                storedLastEntity = outgoing
                // Whatever the row was before, it now holds bytes this device wrote and can
                // read: any tombstone streak is over.
                tombstoneRounds = 0
                // A published snapshot is settings history too — `SyncableSettings.snapshot`
                // stamped a sidecar timestamp for every registered key on the way here, and
                // those are exactly what a later merge compares against.
                hasAdopted = true
                AppLogInfo("[phi-sync] pushed settings keys=\(outgoing.values.count) version=\(version)")
            case .conflict(let serverVersion):
                guard retryOnConflict else {
                    AppLogWarn("[phi-sync] commit still conflicting server_version=\(serverVersion.map(String.init) ?? "unknown"); abandoning this round")
                    return
                }
                _ = await pull(retryOnBirthday: true, thenPush: false)
                // `pushSettings`, not `push`: this retry is the settings entity's
                // own, and the Space half of this round has not run yet.
                await pushSettings(retryOnConflict: false, allowInitialPull: false)
            case .invalidMessage:
                // The same rejection as the `commitRejected(.invalidMessage)` catch below, only
                // reported per entry instead of thrown for the whole batch. Both paths exist:
                // a peer that fails the round still throws.
                dropTheEntityCursorAfterInvalidMessage()
            case .rejected(let responseType):
                AppLogError("[phi-sync] commit rejected response_type=\(responseType); abandoning this round")
                return
            }
        } catch PhiSyncProtocolError.notMyBirthday {
            resetForNewStoreBirthday()
        } catch PhiSyncProtocolError.commitRejected(.invalidMessage) {
            dropTheEntityCursorAfterInvalidMessage()
        } catch {
            AppLogError("[phi-sync] push failed device=\(deviceKeyId) (\(PhiSyncLog.describe(error)))")
        }
    }

    /// INVALID_MESSAGE on the settings commit, however it was reported — as this batch entry's
    /// outcome, or as a thrown `commitRejected(.invalidMessage)` for the whole round.
    ///
    /// The server could not find the row this commit names: the update path returns
    /// INVALID_MESSAGE on pgx.ErrNoRows and on a data_type mismatch
    /// (internal/data/entities_write.go), and NOT_MY_BIRTHDAY never fires because the
    /// account row — and with it store_birthday — is untouched. An incremental
    /// GetUpdates cannot tell us either: it simply returns nothing. Without dropping the
    /// cursor the device would send the same stale id and version forever and never sync
    /// again. Drop the row identity and the marker so the next round replays the type
    /// from scratch and either re-discovers the entity or creates it through the
    /// client_tag_hash unique index.
    ///
    /// `clearRemoteCursor()`, never `resetSyncState()`: the account is unchanged, and
    /// the snapshot taken a few statements above has just stamped `now` on the key the
    /// user edited. Clearing `hasAdopted` here would make the very next pull adopt a
    /// peer's entity wholesale over that edit — and, because `apply` also writes the
    /// remote timestamp into the key's sidecar, the edit would never be re-pushed
    /// either. That is the same distinction the `.absent` full-replay branch makes.
    private func dropTheEntityCursorAfterInvalidMessage() {
        AppLogWarn("[phi-sync] commit rejected as INVALID_MESSAGE; dropping the entity cursor and the marker so the next round rediscovers the entity")
        clearRemoteCursor()
    }

    // MARK: - Space push (§5.1 / §5.5 guard 3 / §9.1)

    /// Assembles this round's Space commit batch. Returns the uuid alongside each
    /// entry so per-entry outcomes can be applied without re-deriving anything.
    private func spaceCommitEntries(
        from table: PhiSpaceSyncTable,
        outgoing: [String: Phi_PhiSpaceEntity]
    ) -> [(uuid: String, entry: PhiCommitEntry, outgoing: Phi_PhiSpaceEntity?)] {
        var result: [(uuid: String, entry: PhiCommitEntry, outgoing: Phi_PhiSpaceEntity?)] = []
        for uuid in Set(outgoing.keys).union(table.cursors.filter { $0.value.pendingDelete }.keys).sorted() {
            let cursor = table.cursors[uuid]
            let tagHash = PhiSyncEntity.clientTagHash(for: PhiSyncEntity.spaceClientTag(uuid))

            // Guard 3 (§5.5): the server holds a row under this tag that this
            // build cannot read. A create would take the server's
            // `ON CONFLICT (client_tag_hash) DO UPDATE` path, which has NO version
            // check, and overwrite it irrecoverably -- not a delete, so M1's
            // 30-day window does not apply either.
            guard table.unreadableTagHashes[tagHash] == nil else {
                AppLogWarn("[phi-sync] refusing to commit over an unreadable row tag=\(String(tagHash.prefix(8)))")
                continue
            }

            if let cursor, cursor.pendingDelete {
                // §9.1's second gate: a tombstone with no entityId / version 0 is
                // illegal server-side and can only loop.
                guard let entityId = cursor.entityId, cursor.version > 0 else { continue }
                result.append((uuid: uuid,
                               entry: PhiCommitEntry(entityId: entityId, clientTagHash: tagHash,
                                                     name: PhiSyncEntity.spaceEntityName,
                                                     ciphertext: nil, deleted: true,
                                                     baseVersion: cursor.version),
                               outgoing: nil))
                continue
            }

            guard let snapshot = outgoing[uuid] else { continue }
            // Merge against what the server holds so a newer client's reserved
            // fields 11-14 survive a round trip through this build.
            var toSend = snapshot
            if let bytes = cursor?.server,
               let server = try? Phi_PhiSpaceEntity(serializedBytes: bytes) {
                toSend = SyncableSpaces.merge(local: snapshot, remote: server)
                if toSend == server { continue }   // nothing to publish
            }
            result.append((uuid: uuid,
                           entry: PhiCommitEntry(entityId: cursor?.entityId, clientTagHash: tagHash,
                                                 name: PhiSyncEntity.spaceEntityName,
                                                 ciphertext: nil, deleted: false,
                                                 baseVersion: cursor?.version ?? 0),
                           outgoing: toSend))
        }
        return result
    }

    /// `onlyUuids == nil` publishes everything this round's snapshot produced;
    /// a non-nil set restricts the batch to those uuids, which is what the
    /// CONFLICT retry passes so one conflicting Space cannot drag the other
    /// twenty back through the wire.
    private func pushSpaces(retryOnConflict: Bool, onlyUuids: Set<String>? = nil) async {
        guard !isStopped, spaceSectionEnabled, let spaceAccess, spaceStore != nil else { return }
        // The one Space read-modify-write that is not a `mutateSpaceTable` delta,
        // for the same reason as the apply path's: per-entry outcomes have to be
        // carried across the batch loop's suspension points. Safe here because
        // EVERY writer of this table is a round (`recordLocalDeletion` included)
        // and rounds are serialized, and because `pushSpaces` is the last Space
        // work of the round -- `applySpaces` has already written by the time
        // this loads.
        var table = loadSpaceTable()
        // Guard 1: not one commit -- tombstones included -- until a full replay
        // has finished, or a device that has not seen the account's Spaces yet can
        // overwrite `default-space` with its factory defaults.
        guard table.hasDrainedFullReplay else {
            if table.drainInProgress {
                AppLogInfo("[phi-sync] space push held: drain_in_progress")
            }
            return
        }

        let spaces = await spaceAccess.currentSpaces()
        guard !isStopped else { return }
        var uuidByProfile: [String: String] = [:]
        for space in spaces {
            if uuidByProfile[space.profileId] == nil {
                uuidByProfile[space.profileId] = await spaceAccess.globalUuid(forProfileId: space.profileId)
            }
        }
        // R-D6-7 的懒铸造。`currentSpaces()` 已经在源头排除 incognito / 两种 agent
        // 特征 / profile 未映射的 Space，所以这里铸的每一个 uuid 都属于一个该发布的
        // Space。铸造失败（`alreadyMapped` 不可能，`defaultSpaceIsImplicit` 由
        // resolver 的常量分支吸收）只会让该 Space 本轮不发布，下一轮重试——这就是
        // 「至多一轮无映射」。
        var syncUuidBySpaceId: [String: String] = [:]
        for space in spaces {
            syncUuidBySpaceId[space.spaceId] = try? await spaceAccess.ensureMapped(spaceId: space.spaceId)
        }
        guard !isStopped else { return }
        let outgoing = SyncableSpaces.snapshot(spaces: spaces, table: table,
                                               globalUuid: { uuidByProfile[$0] ?? nil },
                                               syncUuid: { syncUuidBySpaceId[$0] ?? nil },
                                               now: now())
        var work = spaceCommitEntries(from: table, outgoing: outgoing)
        if let onlyUuids { work = work.filter { onlyUuids.contains($0.uuid) } }
        // §9.1 second gate's bookkeeping half: an unpublished pendingDelete is
        // finalized here rather than sent.
        for (uuid, var cursor) in table.cursors where cursor.pendingDelete {
            guard cursor.entityId == nil || cursor.version == 0 else { continue }
            cursor.pendingDelete = false
            cursor.reconciled = nil
            cursor.server = nil
            cursor.deletedAtMs = now()
            table.cursors[uuid] = cursor
        }
        guard !work.isEmpty else { writeSpaceTable(table); return }

        var conflicted: Set<String> = []
        // R-D6-10：这一轮被账户接受的自发 tombstone。收集在
        // `applySpaceCommitOutcome` 里，删映射在批处理循环之后——那个方法是同步的，
        // 而映射写在主 actor 上。
        var tombstonedThisRound: Set<String> = []
        var encryptionFailed = false
        while !work.isEmpty {
            let slice = Array(work.prefix(Self.maxCommitEntriesPerBatch))
            work.removeFirst(slice.count)
            var entries: [PhiCommitEntry] = []
            var payloads: [(uuid: String, entry: PhiCommitEntry, outgoing: Phi_PhiSpaceEntity?)] = []
            for item in slice {
                guard let payload = item.outgoing else {
                    entries.append(item.entry); payloads.append(item); continue
                }
                var wrapper = Phi_PhiEntity()
                wrapper.space = payload
                guard let key = try? await domainKeys.domainKey(),
                      let ciphertext = try? PhiEntityCodec.encrypt(wrapper, key: key) else {
                    // `break`, not `return`: outcomes already applied for earlier
                    // slices in this round are in `table` and must still be
                    // persisted by the `writeSpaceTable` below, or an accepted
                    // commit's baselines are silently thrown away and the next
                    // round republishes what the server already has.
                    encryptionFailed = true
                    break
                }
                entries.append(PhiCommitEntry(entityId: item.entry.entityId,
                                              clientTagHash: item.entry.clientTagHash,
                                              name: item.entry.name, ciphertext: ciphertext,
                                              deleted: false, baseVersion: item.entry.baseVersion))
                payloads.append(item)
            }
            if encryptionFailed {
                AppLogError("[phi-sync] space commit aborted: the domain key or the seal failed")
                break
            }
            guard !isStopped else { break }
            let outcomes: [PhiCommitOutcome]
            do {
                outcomes = try await client.commit(entries: entries, storeBirthday: storedBirthday)
            } catch PhiSyncProtocolError.notMyBirthday {
                resetForNewStoreBirthday()
                return   // the reset rewrote the table itself; do not write the stale copy back
            } catch {
                AppLogError("[phi-sync] space commit failed (\(PhiSyncLog.describe(error)))")
                break    // keep the outcomes earlier slices already produced
            }
            guard !isStopped else { return }
            for (item, outcome) in zip(payloads, outcomes) {
                applySpaceCommitOutcome(outcome, for: item, table: &table,
                                        conflicted: &conflicted,
                                        tombstoned: &tombstonedThisRound)
            }
        }
        // R-D6-10：这一轮被账户接受的自发 tombstone，映射行随之删除（本地行已经没
        // 了，映射留着只会让下一次反查交出一个不存在的 spaceId）。游标留下：它是永久
        // tombstone 记录。收集在 `applySpaceCommitOutcome` 里，删除在这里——那个方法
        // 是同步的，而映射写在主 actor 上。
        for uuid in tombstonedThisRound {
            guard let local = await spaceAccess.localSpaceId(forSyncUuid: uuid) else { continue }
            await spaceAccess.dropSpaceMapping(forSpaceId: local)
        }
        writeSpaceTable(table)

        // One pull, then re-send ONLY the entities that conflicted -- the retry
        // is scoped by `onlyUuids`, so a single conflicting Space never drags
        // the other twenty back through the wire (§5.1: "一次 pull 后只重发冲突的
        // 那几条; 二次冲突放弃这几条, 本轮其余已生效").
        if retryOnConflict, !conflicted.isEmpty {
            _ = await pull(retryOnBirthday: true, thenPush: false)
            await pushSpaces(retryOnConflict: false, onlyUuids: conflicted)
        }
    }

    /// The five baseline write points of §6.2, in one place.
    ///
    /// `tombstoned` collects the uuids whose OWN tombstone the account accepted this
    /// round (R-D6-10). It is an out-parameter for the same reason `conflicted` is:
    /// this method is synchronous, and dropping the mapping row is a main-actor hop
    /// the caller makes after the batch loop.
    private func applySpaceCommitOutcome(
        _ outcome: PhiCommitOutcome,
        for item: (uuid: String, entry: PhiCommitEntry, outgoing: Phi_PhiSpaceEntity?),
        table: inout PhiSpaceSyncTable,
        conflicted: inout Set<String>,
        tombstoned: inout Set<String>
    ) {
        var cursor = table.cursors[item.uuid] ?? PhiSpaceCursor()
        let isTombstone = item.entry.deleted
        switch outcome {
        case .applied(let entityId, let version, let storeBirthday):
            if !entityId.isEmpty { cursor.entityId = entityId }
            cursor.version = version
            storedBirthday = storeBirthday
            if isTombstone {
                cursor.pendingDelete = false
                cursor.deleteRejectRounds = 0
                cursor.reconciled = nil
                cursor.server = nil
                cursor.deletedAtMs = now()
                cursor.hidden = true
                spaceCounters.tombstones += 1
                tombstoned.insert(item.uuid)
            } else if let outgoing = item.outgoing {
                // BOTH baselines: updating only `server` would let the next
                // snapshot decide the field still differs from `reconciled`,
                // stamp `now` again, and win the account's LWW every round.
                cursor.reconciled = try? outgoing.serializedData()
                cursor.server = cursor.reconciled
                cursor.deleteRejectRounds = 0
                spaceCounters.pushed += 1
            }
        case .conflict:
            conflicted.insert(item.uuid)
            spaceCounters.conflicts += 1
        case .invalidMessage:
            guard isTombstone else {
                // "The server has no such row": drop the server-side triple and
                // let the next round re-create through the client_tag unique
                // index. `reconciled` survives -- it is this device's timestamp
                // history, not a statement about the server.
                cursor.entityId = nil
                cursor.version = 0
                cursor.server = nil
                break
            }
            // A rejected tombstone proves nothing: the server resolves a
            // tombstone's data type with a query OUTSIDE the commit transaction,
            // so any transient failure returns the same code as "no such row".
            // Keep the intent and re-send it unchanged; give up only after three.
            cursor.deleteRejectRounds += 1
            if cursor.deleteRejectRounds >= Self.tombstoneRejectGiveUpRounds {
                AppLogError("[phi-sync] giving up on a tombstone after \(cursor.deleteRejectRounds) rejections tag=\(String(item.entry.clientTagHash.prefix(8)))")
                cursor.pendingDelete = false
                cursor.reconciled = nil
                cursor.server = nil
                cursor.deletedAtMs = now()
                cursor.hidden = true
            }
        case .rejected(let type):
            AppLogError("[phi-sync] space commit rejected response_type=\(type) tag=\(String(item.entry.clientTagHash.prefix(8)))")
        }
        table.cursors[item.uuid] = cursor
    }

    // MARK: - Guarded writes
    //
    // Everything this engine writes into the shared `UserDefaults` goes through one of the
    // three functions here or in the section below, each of which reads the retirement flag
    // immediately before its write. The guards at the rounds' entry and suspension points are
    // an optimisation on top of that (they stop useless work and useless network), not the
    // mechanism: `shutdown()` runs concurrently with the round, so a check taken at the top of
    // `apply` or `push` says nothing about the flag's value a few statements later. See
    // `shutdown()` for the exact guarantee this buys and the residue it leaves.

    /// Single write path for the settings themselves. Returns whether the write happened, so a
    /// caller can skip the cursor bookkeeping that only makes sense once the values landed.
    @discardableResult
    private func writeSettings(_ entity: Phi_PhiSettingEntity) -> Bool {
        guard !isStopped else { return false }
        isApplyingRemote = true
        SyncableSettings.apply(entity, to: defaults, settings: settings)
        isApplyingRemote = false
        return true
    }

    private func loadSpaceTable() -> PhiSpaceSyncTable {
        spaceStore?.load() ?? PhiSpaceSyncTable()
    }

    /// Single write path for `sync.phiSpaces`, with the same retirement check every other
    /// engine write takes — a round that resumes after `shutdown()` must not write the previous
    /// account's Space shadow back over a freshly cleared table (§3.3 step 2.0).
    private func writeSpaceTable(_ table: PhiSpaceSyncTable) {
        guard !isStopped, let spaceStore else { return }
        spaceStore.save(table)
        Task { @MainActor in PhiSpaceSyncState.shared.refreshCaches(from: table) }
    }

    /// Read-modify-write against `sync.phiSpaces`, and the only way a round is allowed to
    /// change it. Two reasons, both of which a load-once/write-once round gets wrong:
    ///
    /// 1. **Durability.** A pull persists the shared marker page by page. Anything derived
    ///    from that marker therefore has to be persisted page by page too, or an error on
    ///    page 2 throws away the record of what page 1 already walked past — while the marker
    ///    itself stays advanced. Small deltas written where they are observed, never a whole
    ///    table written at the end.
    /// 2. **Freshness.** `body` sees the table as it is *now*, not as it was before the last
    ///    suspension point, so a round can only overwrite the fields it actually touches.
    ///    The gate edge runs as its own round (`setSpaceSyncEnabled`) so it cannot interleave
    ///    in the first place; this is the belt to that suspenders, and it is what keeps
    ///    Task 9's apply path from having to think about either question again.
    ///
    /// Writes only when `body` changed something, so a no-op mutation costs no plist write and
    /// no main-actor cache refresh.
    private func mutateSpaceTable(_ body: (inout PhiSpaceSyncTable) -> Void) {
        var table = loadSpaceTable()
        let before = table
        body(&table)
        guard table != before else { return }
        writeSpaceTable(table)
    }

    /// `mutateSpaceTable`'s sibling for the §5.3 intents delivered by
    /// `PhiSpaceSyncState`: the same read-modify-write against `sync.phiSpaces`,
    /// except that the intent itself reports whether it changed anything, so the
    /// caller can decide to queue a push instead of the engine guessing from a
    /// `!=` comparison.
    ///
    /// `body` may not suspend, so the read-modify-write itself cannot be torn.
    /// That is NOT what makes the intent safe, though: exclusion against the
    /// rounds that hold a table copy across their own suspensions comes from the
    /// queue, and every caller of this helper is already a `Round` body
    /// (`.recordLocalDeletion`). Never call it from a public entry point.
    @discardableResult
    private func runSpaceIntent(_ body: (inout PhiSpaceSyncTable) -> Bool) -> Bool {
        // Redundant with `writeSpaceTable`'s own `guard let spaceStore`, but it
        // avoids a pointless `PhiSpaceSyncTable()` round trip on a settings-only
        // engine.
        guard spaceStore != nil else { return false }
        var table = loadSpaceTable()
        let changed = body(&table)
        if changed { writeSpaceTable(table) }
        return changed
    }

    /// `SyncableSettings.snapshot` is a write as much as a read: for every registered key whose
    /// value differs from `<key>.phiSyncVal` it stamps `<key>.phiSyncTs = now()` and refreshes
    /// the sidecar. So it takes the same check as the settings and the cursor. `nil` means the
    /// engine was retired and nothing was stamped.
    private func snapshotLocalSettings() -> Phi_PhiSettingEntity? {
        guard !isStopped else { return nil }
        return SyncableSettings.snapshot(defaults, now: now(), settings: settings)
    }

    // MARK: - Persisted state accessors

    /// Single write path for the account-scoped cursor, so the shutdown check cannot be
    /// forgotten at one of the seven accessors below. `nil` removes the key.
    private func writeState(_ value: Any?, forKey key: String) {
        guard !isStopped else { return }
        guard let value else { return defaults.removeObject(forKey: key) }
        defaults.set(value, forKey: key)
    }

    /// True once this device knows *which row* the account's settings live in — either it has
    /// seen the entity or it has committed its own. Answers "may a `version = 0` create go
    /// out?", nothing else; `clearEntityCursor()` makes it false again. The merge-vs-adopt
    /// decision deliberately does not read it — that is `hasAdopted`.
    private var hasSyncedBefore: Bool { storedEntityId != nil || storedLastEntity != nil }

    /// True once this device has settings history for the account: a pull applied the account's
    /// entity, or this device committed a snapshot of its own. Either way `<key>.phiSyncTs`
    /// sidecars now exist for the registered keys, which is what makes a field-level merge
    /// meaningful — so this, not `hasSyncedBefore`, is what gates the wholesale adopt in
    /// `apply`. The two used to be the same predicate, and the coupling was a silent data
    /// loss: `clearEntityCursor()` (the tombstone heal, the full-replay branch) forgets which
    /// row the settings live in, and the next readable entity was then adopted wholesale over
    /// local edits whose debounced push had not run yet.
    ///
    /// Not derived from the sidecars themselves: those sit next to the preference keys and are
    /// not account-scoped, so they outlive the cursor wipe and would stop a device from
    /// adopting the settings of an account it has just switched to. This is cleared only by an
    /// account-scope reset of `stateKeys` — in the app that is
    /// `PhiChromiumCoordinator.resetPhiSyncCursorIfAccountChanged`, run before the new
    /// account's engine is built; `resetSyncState()` does the same wipe from in here.
    ///
    /// One known window, accepted rather than closed. The two predicates disagree the other way
    /// when a device's only sight of the entity was `.unusable`: the pull records
    /// `storedEntityId` from that entity before dropping the baseline, so `hasSyncedBefore` is
    /// true while `hasAdopted` is false, and `push` then returns at its "an entity id with no
    /// baseline" guard *before* `SyncableSettings.snapshot` can stamp anything. A setting the
    /// user changes in that window is therefore adopted over — not merged — once the entity
    /// becomes readable, with no log line of its own.
    ///
    /// Merging there instead would cost more. `snapshot` treats a key with no `<key>.phiSyncVal`
    /// as locally changed, so on a device with no sidecar history at all it stamps *every*
    /// registered key `now`: the merge would hand this device's whole local default set the
    /// newest timestamps in the account and the trailing push would publish it over every other
    /// device. Stamping the sidecars inside the guard to "give the merge real timestamps" has
    /// the same defect — the fabricated timestamps would be `now` for every key, not just the
    /// one the user touched, because nothing here knows which key changed. So the guard leaves
    /// no trace on purpose, and the smaller loss stands.
    /// `testAnUnreadableEntityLaterAdoptsWholesaleOverAnEditMadeInThatWindow` pins the choice.
    private var hasAdopted: Bool {
        get { defaults.bool(forKey: Self.hasAdoptedStateKey) }
        set {
            let stored: Bool? = newValue ? true : nil
            writeState(stored, forKey: Self.hasAdoptedStateKey)
        }
    }

    /// Forgets which entity the account's settings live in, keeping the progress marker, the
    /// store birthday and `hasAdopted` — this says the row is gone, never that this device has
    /// no settings history. Used when the server proves that entity is gone; the next round
    /// takes the create path, which the server resolves by `client_tag_hash`.
    private func clearEntityCursor() {
        storedEntityId = nil
        storedVersion = nil
        storedLastEntity = nil
    }

    /// `clearEntityCursor()` plus the progress marker, so the next pull replays the whole type
    /// instead of asking for changes after a watermark that describes a row the server no
    /// longer has. Same-account recovery — the store birthday and `hasAdopted` stay.
    private func clearRemoteCursor() {
        clearEntityCursor()
        storedMarker = nil
    }

    /// The store this device was tracking is gone (NOT_MY_BIRTHDAY): every cursor that
    /// describes it is void, birthday included, and any tombstone streak counted against the
    /// old store means nothing.
    ///
    /// `hasAdopted` survives, because the *account* did not change — only the server's store
    /// identity did. The `<key>.phiSyncTs` sidecars this device has been keeping still describe
    /// this account's settings, so the next readable entity must be merged against them, not
    /// adopted over them. (Only an account-scope reset of `stateKeys` clears it — see
    /// `hasAdopted`.) The Space table's *server-side* triples are cleared alongside for the
    /// same reason and with the same exception: what describes the store goes, what describes
    /// this account's own history stays.
    private func resetForNewStoreBirthday() {
        clearRemoteCursor()
        storedBirthday = ""
        tombstoneRounds = 0
        guard spaceStore != nil else { return }
        // The server holds a different data set now, so every server-side triple and every
        // loss guard has to be re-armed. `reconciled` / `hidden` / `deletedAtMs` / `purgedAtMs`
        // survive: the ACCOUNT did not change, and clearing them would re-arm the wholesale
        // adopt and silently drop edits this device has just stamped.
        mutateSpaceTable { table in
            for (uuid, var cursor) in table.cursors {
                cursor.entityId = nil
                cursor.version = 0
                cursor.server = nil
                cursor.deleteRejectRounds = 0
                table.cursors[uuid] = cursor
            }
            table.hasDrainedFullReplay = false
            table.drainInProgress = false
            table.markerMovedWhileGateShut = false
            table.didReplayForEmptyTable = false
            table.lastDrainedBirthday = nil
            table.unreadableTagHashes = [:]
        }
    }

    private var storedEntityId: String? {
        get { defaults.string(forKey: Self.entityIdStateKey) }
        set { writeState(newValue, forKey: Self.entityIdStateKey) }
    }

    private var storedVersion: Int64? {
        get { (defaults.object(forKey: Self.versionStateKey) as? NSNumber)?.int64Value }
        set { writeState(newValue.map { NSNumber(value: $0) }, forKey: Self.versionStateKey) }
    }

    /// The empty string is "not known yet" on the wire, so it is stored as *absent* rather
    /// than as an empty value — same convention as `storedMarker`, and it keeps `stateKeys` a
    /// clean "nothing persisted" set after a reset.
    private var storedBirthday: String {
        get { defaults.string(forKey: Self.storeBirthdayStateKey) ?? "" }
        set { writeState(newValue.isEmpty ? nil : newValue, forKey: Self.storeBirthdayStateKey) }
    }

    private var storedMarker: Data? {
        get { defaults.data(forKey: Self.markerStateKey) }
        set {
            let stored: Data? = (newValue?.isEmpty ?? true) ? nil : newValue
            writeState(stored, forKey: Self.markerStateKey)
        }
    }

    /// Consecutive pulls that found the account's settings row tombstoned. Zero is stored as
    /// "absent" so `stateKeys` stays a clean "nothing persisted" set after a cursor wipe.
    private var tombstoneRounds: Int {
        get { defaults.integer(forKey: Self.tombstoneRoundsStateKey) }
        set {
            let stored: Int? = newValue > 0 ? newValue : nil
            writeState(stored, forKey: Self.tombstoneRoundsStateKey)
        }
    }

    private var storedLastEntity: Phi_PhiSettingEntity? {
        get {
            guard let bytes = defaults.data(forKey: Self.lastEntityStateKey) else { return nil }
            return try? Phi_PhiSettingEntity(serializedBytes: bytes)
        }
        set { writeState(newValue.flatMap { try? $0.serializedData() }, forKey: Self.lastEntityStateKey) }
    }
}
