// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import Combine
import CryptoKit
import Foundation
import Network

// MARK: - Wire model

/// One live agent task as the user's other Macs see it. Only agent Spaces
/// travel: the user's own tabs never leave the Mac they are open on.
struct AgentRemoteTask: Codable, Equatable {
    enum Status: Codable, Equatable {
        case starting, running, idle, completed
        case failed(String)
    }

    let spaceId: String
    let taskId: String
    let number: Int
    let agentName: String
    let isPhiAgent: Bool
    let ownedByUser: Bool
    let status: Status
    let caption: String
    /// The device that took control from afar, while it holds it.
    let remoteController: String?
    /// The agent's handoff message while the host's handoff prompt is up.
    let handoffMessage: String?
    let tabs: [AgentRemoteTab]

    /// The record the control pill renders, built from what the host sent.
    var displayTask: AgentTask {
        let taskStatus: AgentTaskStatus
        switch status {
        case .starting: taskStatus = .starting
        case .running: taskStatus = .running
        case .idle: taskStatus = .idle
        case .completed: taskStatus = .completed
        case .failed(let message): taskStatus = .failed(message: message)
        }
        return AgentTask(
            taskId: taskId, spaceId: spaceId, profileId: "",
            origin: isPhiAgent ? .phiAgent : .cdp, driverPrincipalId: nil,
            number: number, windowId: 0,
            ownership: ownedByUser ? .user : .agent,
            status: taskStatus, statusCaption: caption, cursor: nil,
            hasUnseenError: false, agentName: agentName,
            remoteController: remoteController)
    }
}

struct AgentRemoteTab: Codable, Equatable {
    let id: Int
    let title: String
    let url: String
    let isActive: Bool
}

struct AgentRemoteSnapshot: Codable, Equatable {
    let deviceName: String
    let tasks: [AgentRemoteTask]
}

/// One captured frame of the watched agent Space's operating tab. `cssSize`
/// is the page viewport the JPEG covers, the space remote input is sent in.
struct AgentRemoteFrame: Codable {
    let spaceId: String
    let tabId: Int
    let jpeg: Data
    let cssSize: CGSize
    let cursor: CGPoint?
}

enum AgentRemoteCommand: Codable {
    case activateTab(spaceId: String, tabId: Int)
    case takeControl(spaceId: String)
    case handBack(spaceId: String)
    case finish(spaceId: String)
    /// The user answered the handoff prompt on another Mac.
    case answerHandoff(spaceId: String)
}

/// User input from the Mac that holds control, in the page's CSS pixels.
struct AgentRemoteInput: Codable {
    enum Kind: String, Codable {
        case mouseMoved, mousePressed, mouseReleased, mouseWheel
        case keyDown, keyUp, insertText
    }

    let spaceId: String
    let kind: Kind
    var point: CGPoint = .zero
    var button: String?
    var clickCount: Int = 0
    var delta: CGSize = .zero
    var key: String?
    var code: String?
    var keyCode: Int = 0
    var text: String?
    /// CDP bitmask: Alt 1, Ctrl 2, Meta 4, Shift 8.
    var modifiers: Int = 0
}

enum AgentRemoteMessage: Codable {
    case hello(deviceName: String)
    case snapshot(AgentRemoteSnapshot)
    case frame(AgentRemoteFrame)
    case watch(spaceId: String?)
    case command(AgentRemoteCommand)
    case input(AgentRemoteInput)
}

/// Which remote agent Space a window is showing in place of its own page.
struct AgentRemoteMirrorTarget: Equatable {
    let peerId: String
    let spaceId: String
}

// MARK: - Trust

/// The key both Macs must hold before either sees the other's agents.
///
/// Official builds derive it from the account root key that Phi Sync already
/// shares between the account's unlocked devices, so "the same account" is
/// the whole pairing step and no secret is shown or typed. Open-source builds
/// have no account; there a link code, copied once from one Mac to the other,
/// stands in for it.
enum AgentRemoteTrust {
    private static let info = Data("phi.agentRemotePresence.v1".utf8)

    @MainActor
    static func presenceKey() -> SymmetricKey? {
        #if PHI_OSS_BUILD
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: Data(linkCode.utf8)),
            salt: Data("phi.agentRemotePresence.linkCode".utf8),
            info: info, outputByteCount: 32)
        #else
        guard let ark = PhiChromiumCoordinator.shared.syncKeyController?.manager.currentARK else {
            return nil
        }
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: ark, info: info, outputByteCount: 32)
        #endif
    }

    #if PHI_OSS_BUILD
    private static let linkCodeKey = "PhiRemoteAgentsLinkCode"
    private static let linkCodeAlphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    /// 16 Crockford base32 characters (80 bits), grouped for reading aloud.
    /// ponytail: kept in defaults, move to the Keychain once open-source
    /// builds sign with a stable identity (an ad-hoc signature changes every
    /// build, and each change re-prompts for the login keychain).
    static var linkCode: String {
        get {
            if let stored = UserDefaults.standard.string(forKey: linkCodeKey), !stored.isEmpty {
                return stored
            }
            var generator = SystemRandomNumberGenerator()
            let raw = String((0..<16).map { _ in linkCodeAlphabet.randomElement(using: &generator)! })
            let code = stride(from: 0, to: 16, by: 4).map { start in
                String(raw.dropFirst(start).prefix(4))
            }.joined(separator: "-")
            UserDefaults.standard.set(code, forKey: linkCodeKey)
            return code
        }
        set {
            // Only a full 80-bit code is kept; anything shorter would make a
            // guessable key, so the current code stays.
            let normalized = newValue.uppercased().filter { !$0.isWhitespace }
            let symbols = normalized.filter { $0 != "-" }
            guard symbols.count == 16, symbols.allSatisfy(linkCodeAlphabet.contains) else { return }
            UserDefaults.standard.set(normalized, forKey: linkCodeKey)
        }
    }
    #endif
}

// MARK: - Presence service

/// Shows this Mac's agent Spaces to the user's other Macs and theirs here.
///
/// Every Mac with the setting on is both a host (a Bonjour-advertised
/// listener that streams its agent Spaces) and a viewer (a browser that
/// connects to every other host it finds). Both directions run over TLS with
/// a pre-shared key from `AgentRemoteTrust`, so a Mac that does not hold the
/// key fails the handshake and never learns anything.
///
/// Control stays where it lives today: a remote "Take control" or "Hand back"
/// calls the host's `AgentSpaceManager`, so the driving agent sees exactly
/// the ownership broadcast a local click produces.
@MainActor
final class AgentRemotePresence: ObservableObject {
    static let shared = AgentRemotePresence()
    static let serviceType = "_phi-agents._tcp"
    /// Overrides the advertised name, so two instances on one Mac (separate
    /// `--user-data-dir`s) can tell themselves apart.
    static let deviceNameDefaultsKey = "PhiRemoteAgentsDeviceName"

    /// Live agent tasks of the other Macs, keyed by peer.
    @Published private(set) var peers: [String: AgentRemoteSnapshot] = [:]
    /// Frames for the agent Space a window is mirroring.
    let frames = PassthroughSubject<(peerId: String, frame: AgentRemoteFrame), Never>()

    private let instanceId = UUID().uuidString
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var viewers: [ObjectIdentifier: ViewerLink] = [:]
    private var hosts: [String: AgentRemoteChannel] = [:]
    private var watchedByPeer: [String: String] = [:]
    private var snapshotTimer: Timer?
    private var tasksCancellable: AnyCancellable?
    private var presentedHandoffs: Set<String> = []
    /// Fingerprint of the key the service runs on, rechecked every second so a
    /// sign-out, account switch or revoked device cuts access at once.
    private var activeKeyFingerprint: Data?
    /// Which viewer connection took control of each Space. Input is accepted
    /// from that connection only, never from another Mac or a stale one.
    private var controllingLinkBySpaceId: [String: ObjectIdentifier] = [:]

    private init() {
        for name: Notification.Name in [.agentRemotePresenceSettingDidChange, .phiAccountKeyDidUnlock] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { AgentRemotePresence.shared.refresh() }
            }
        }
    }

    var deviceName: String {
        UserDefaults.standard.string(forKey: Self.deviceNameDefaultsKey)
            ?? Host.current().localizedName ?? "Mac"
    }

    var isEnabled: Bool {
        PhiPreferences.AgentSpaces.developerModeEnabled
            && PhiPreferences.AgentSpaces.remoteAgentsEnabled
    }

    /// Starts or stops both roles to match the setting and the key.
    func refresh() {
        stop()
        guard isEnabled else { return }
        guard let key = AgentRemoteTrust.presenceKey() else {
            AppLogInfo("[AgentRemote] no presence key yet (Sync locked or off)")
            return
        }
        activeKeyFingerprint = Self.fingerprint(key)
        startListener(key: key)
        startBrowser(key: key)
        tasksCancellable = AgentSpaceManager.shared.$tasksBySpaceId
            .receive(on: DispatchQueue.main)
            .sink { _ in
                MainActor.assumeIsolated { AgentRemotePresence.shared.publishSnapshots() }
            }
        // Tab titles and URLs change without a task publish.
        snapshotTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated {
                let presence = AgentRemotePresence.shared
                guard Self.fingerprint(AgentRemoteTrust.presenceKey()) == presence.activeKeyFingerprint else {
                    return presence.refresh()
                }
                presence.publishSnapshots()
            }
        }
    }

    private static func fingerprint(_ key: SymmetricKey?) -> Data? {
        key.map { key in key.withUnsafeBytes { Data(SHA256.hash(data: Data($0))) } }
    }

    private func stop() {
        activeKeyFingerprint = nil
        for spaceId in controllingLinkBySpaceId.keys {
            AgentSpaceManager.shared.remoteControllerDidLeave(spaceId: spaceId)
        }
        controllingLinkBySpaceId = [:]
        listener?.cancel()
        listener = nil
        browser?.cancel()
        browser = nil
        snapshotTimer?.invalidate()
        snapshotTimer = nil
        tasksCancellable = nil
        viewers.values.forEach { $0.channel.close() }
        viewers = [:]
        hosts.values.forEach { $0.close() }
        hosts = [:]
        peers = [:]
        watchedByPeer = [:]
        presentedHandoffs.forEach { AgentSpaceManager.shared.dismissRemoteHandoffPrompt(key: $0) }
        presentedHandoffs = []
        clearMirrors { _ in true }
    }

    // MARK: Host role

    private final class ViewerLink {
        let channel: AgentRemoteChannel
        var deviceName = ""
        var watchedSpaceId: String?
        var lastSnapshot: AgentRemoteSnapshot?
        var frameTask: Task<Void, Never>?
        var inputQueue: [AgentRemoteInput] = []
        var inputTask: Task<Void, Never>?

        init(channel: AgentRemoteChannel) {
            self.channel = channel
        }
    }

    private func startListener(key: SymmetricKey) {
        do {
            let listener = try NWListener(using: AgentRemoteChannel.parameters(key: key))
            listener.service = NWListener.Service(name: instanceId, type: Self.serviceType)
            listener.newConnectionHandler = { connection in
                MainActor.assumeIsolated { AgentRemotePresence.shared.accept(connection) }
            }
            listener.stateUpdateHandler = { state in
                AppLogInfo("[AgentRemote] listener \(state)")
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            AppLogError("[AgentRemote] listener failed: \(error)")
        }
    }

    private func accept(_ connection: NWConnection) {
        let link = ViewerLink(channel: AgentRemoteChannel(connection))
        let id = ObjectIdentifier(link)
        viewers[id] = link
        link.channel.onMessage = { [weak self, weak link] message in
            guard let self, let link else { return }
            MainActor.assumeIsolated { self.handleViewerMessage(message, from: link) }
        }
        link.channel.onClose = { [weak self, weak link] in
            MainActor.assumeIsolated {
                link?.frameTask?.cancel()
                link?.inputTask?.cancel()
                self?.viewers[id] = nil
                // A Mac that held control and left must not leave the agent
                // blocked with nobody able to answer for it.
                for (spaceId, holder) in self?.controllingLinkBySpaceId ?? [:] where holder == id {
                    self?.controllingLinkBySpaceId[spaceId] = nil
                    AgentSpaceManager.shared.remoteControllerDidLeave(spaceId: spaceId)
                }
            }
        }
        link.channel.start()
    }

    private func handleViewerMessage(_ message: AgentRemoteMessage, from link: ViewerLink) {
        switch message {
        case .hello(let name):
            AppLogInfo("[AgentRemote] \(name) is watching this Mac's agents")
            link.deviceName = name
            link.lastSnapshot = nil
            publishSnapshots()
        case .watch(let spaceId):
            guard link.watchedSpaceId != spaceId else { return }
            link.watchedSpaceId = spaceId
            streamFrames(to: link)
        case .command(let command):
            perform(command, from: link)
        case .input(let input):
            enqueue(input, from: link)
        case .snapshot, .frame:
            break
        }
    }

    private func perform(_ command: AgentRemoteCommand, from link: ViewerLink) {
        let manager = AgentSpaceManager.shared
        switch command {
        case .activateTab(let spaceId, let tabId):
            guard let task = manager.task(forSpaceId: spaceId),
                  let state = SpaceSessionControllersManager.shared.getBrowserState(for: task.windowId),
                  state.normalTabs.contains(where: { $0.guid == tabId }) else { return }
            state.focusTabWithTabId(tabId)
        case .takeControl(let spaceId):
            guard manager.task(forSpaceId: spaceId) != nil else { return }
            controllingLinkBySpaceId[spaceId] = ObjectIdentifier(link)
            manager.takeControl(spaceId: spaceId, remoteController: link.deviceName)
        case .handBack(let spaceId):
            controllingLinkBySpaceId[spaceId] = nil
            manager.handBack(spaceId: spaceId)
        case .finish(let spaceId):
            guard let task = manager.task(forSpaceId: spaceId) else { return }
            manager.taskDidComplete(taskId: task.taskId, success: true, keep: true)
        case .answerHandoff(let spaceId):
            guard manager.pendingHandoffMessage(forSpaceId: spaceId) != nil else { return }
            controllingLinkBySpaceId[spaceId] = ObjectIdentifier(link)
            manager.answerHandoffRemotely(spaceId: spaceId, deviceName: link.deviceName)
        }
        publishSnapshots()
    }

    private func makeSnapshot() -> AgentRemoteSnapshot {
        let manager = AgentSpaceManager.shared
        let tasks = manager.tasksBySpaceId.values
            .sorted { $0.number < $1.number }
            .map { task -> AgentRemoteTask in
                let state = task.windowId == 0 ? nil
                    : SpaceSessionControllersManager.shared.getBrowserState(for: task.windowId)
                let activeId = state?.focusingTab?.guid
                let tabs = (state?.normalTabs ?? []).map {
                    AgentRemoteTab(id: $0.guid, title: $0.title, url: $0.url ?? "",
                                   isActive: $0.guid == activeId)
                }
                let status: AgentRemoteTask.Status
                switch task.status {
                case .starting: status = .starting
                case .running: status = .running
                case .idle: status = .idle
                case .completed: status = .completed
                case .failed(let message): status = .failed(message)
                }
                return AgentRemoteTask(
                    spaceId: task.spaceId, taskId: task.taskId, number: task.number,
                    agentName: task.agentName, isPhiAgent: task.origin == .phiAgent,
                    ownedByUser: task.ownership == .user, status: status,
                    caption: task.statusCaption, remoteController: task.remoteController,
                    handoffMessage: manager.pendingHandoffMessage(forSpaceId: task.spaceId),
                    tabs: tabs)
            }
        return AgentRemoteSnapshot(deviceName: deviceName, tasks: tasks)
    }

    private func publishSnapshots() {
        guard !viewers.isEmpty else { return }
        let snapshot = makeSnapshot()
        for link in viewers.values where !link.deviceName.isEmpty && link.lastSnapshot != snapshot {
            link.lastSnapshot = snapshot
            link.channel.send(.snapshot(snapshot))
        }
    }

    /// The operating tab of a live agent Space and its DevTools target.
    private static func operatingTab(spaceId: String) -> (tab: Tab, targetId: String)? {
        guard let task = AgentSpaceManager.shared.task(forSpaceId: spaceId),
              let tab = SpaceSessionControllersManager.shared
                .getBrowserState(for: task.windowId)?.focusingTab,
              let targetId = tab.webContentWrapper?.devToolsTargetId,
              !targetId.isEmpty else { return nil }
        return (tab, targetId)
    }

    /// Captures the watched Space's operating tab while a viewer watches it,
    /// keeping one frame in flight. Polls `Page.captureScreenshot` through an
    /// app-owned session: the agent window stays paintable while hidden.
    private func streamFrames(to link: ViewerLink) {
        link.frameTask?.cancel()
        guard let spaceId = link.watchedSpaceId else { return }
        link.frameTask = Task { @MainActor [weak link] in
            var session: AppDevToolsPageSession?
            var sessionTargetId: String?
            var lastJPEG = Data()
            defer { session?.close() }
            while !Task.isCancelled, let current = link, current.watchedSpaceId == spaceId {
                guard let (tab, targetId) = Self.operatingTab(spaceId: spaceId) else {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    continue
                }
                do {
                    if sessionTargetId != targetId {
                        session?.close()
                        session = try await AppDevToolsPageSession.open(
                            targetId: targetId, timeout: 5,
                            maxMessageBytes: AgentRemoteChannel.maxMessageBytes)
                        sessionTargetId = targetId
                    }
                    guard let page = session else { continue }
                    let metrics = try await page.command("Page.getLayoutMetrics", timeout: 3)
                    let shot = try await page.command("Page.captureScreenshot", params: [
                        "format": "jpeg", "quality": 60, "optimizeForSpeed": true,
                    ], timeout: 5)
                    let viewport = metrics["cssVisualViewport"] as? [String: Any]
                    guard let base64 = shot["data"] as? String,
                          let jpeg = Data(base64Encoded: base64),
                          let width = viewport?["clientWidth"] as? Double,
                          let height = viewport?["clientHeight"] as? Double else { continue }
                    let cursor = AgentSpaceManager.shared.cursorBySpaceId[spaceId]
                    if jpeg != lastJPEG || cursor != nil {
                        lastJPEG = jpeg
                        let frame = AgentRemoteFrame(
                            spaceId: spaceId, tabId: tab.guid, jpeg: jpeg,
                            cssSize: CGSize(width: width, height: height), cursor: cursor)
                        await withCheckedContinuation { continuation in
                            current.channel.send(.frame(frame)) { continuation.resume() }
                        }
                    }
                } catch {
                    AppLogInfo("[AgentRemote] frame capture failed: \(error)")
                    session?.close()
                    session = nil
                    sessionTargetId = nil
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    /// Remote input is accepted only while a human holds the Space, the same
    /// rule the local overlay enforces by swallowing input in watch mode.
    private func enqueue(_ input: AgentRemoteInput, from link: ViewerLink) {
        guard holdsControl(link, spaceId: input.spaceId) else { return }
        // Pointer moves outpace CDP round trips: keep only the latest one.
        if input.kind == .mouseMoved, link.inputQueue.last?.kind == .mouseMoved {
            link.inputQueue.removeLast()
        }
        guard link.inputQueue.count < Self.maxQueuedInputs else { return }
        link.inputQueue.append(input)
        guard link.inputTask == nil else { return }
        link.inputTask = Task { @MainActor [weak self, weak link] in
            guard let self else { return }
            var session: AppDevToolsPageSession?
            var sessionTargetId: String?
            defer { session?.close() }
            while let current = link, !current.inputQueue.isEmpty {
                let next = current.inputQueue.removeFirst()
                guard self.holdsControl(current, spaceId: next.spaceId),
                      let (_, targetId) = Self.operatingTab(spaceId: next.spaceId) else { continue }
                do {
                    if sessionTargetId != targetId {
                        session?.close()
                        session = try await AppDevToolsPageSession.open(targetId: targetId, timeout: 5)
                        sessionTargetId = targetId
                    }
                    let (method, params) = Self.devToolsCommand(for: next)
                    _ = try await session?.command(method, params: params, timeout: 3)
                } catch {
                    AppLogInfo("[AgentRemote] input \(next.kind.rawValue) failed: \(error)")
                    session?.close()
                    session = nil
                    sessionTargetId = nil
                }
            }
            link?.inputTask = nil
        }
    }

    private static let maxQueuedInputs = 256

    /// True while `link`'s Mac holds `spaceId`: a human has it, and it was
    /// this connection that took it, not this Mac's user or another Mac.
    private func holdsControl(_ link: ViewerLink, spaceId: String) -> Bool {
        guard let task = AgentSpaceManager.shared.task(forSpaceId: spaceId),
              task.ownership == .user, task.remoteController != nil else { return false }
        return controllingLinkBySpaceId[spaceId] == ObjectIdentifier(link)
    }

    nonisolated static func devToolsCommand(for input: AgentRemoteInput) -> (String, [String: Any]) {
        let x = Double(input.point.x), y = Double(input.point.y)
        switch input.kind {
        case .mouseMoved, .mousePressed, .mouseReleased:
            let button = input.button ?? "none"
            let held = input.kind == .mousePressed || (input.kind == .mouseMoved && button != "none")
            let mask = button == "left" ? 1 : button == "right" ? 2 : 0
            return ("Input.dispatchMouseEvent", [
                "type": input.kind.rawValue, "x": x, "y": y, "button": button,
                "buttons": held ? mask : 0, "clickCount": input.clickCount,
                "modifiers": input.modifiers,
            ])
        case .mouseWheel:
            return ("Input.dispatchMouseEvent", [
                "type": "mouseWheel", "x": x, "y": y,
                "deltaX": Double(input.delta.width), "deltaY": Double(input.delta.height),
                "modifiers": input.modifiers,
            ])
        case .keyDown, .keyUp:
            var params: [String: Any] = [
                "type": input.kind == .keyUp ? "keyUp" : (input.text == nil ? "rawKeyDown" : "keyDown"),
                "key": input.key ?? "", "code": input.code ?? "",
                "windowsVirtualKeyCode": input.keyCode, "modifiers": input.modifiers,
            ]
            if let text = input.text { params["text"] = text }
            return ("Input.dispatchKeyEvent", params)
        case .insertText:
            return ("Input.insertText", ["text": input.text ?? ""])
        }
    }

    // MARK: Viewer role

    private func startBrowser(key: SymmetricKey) {
        let browser = NWBrowser(for: .bonjour(type: Self.serviceType, domain: nil),
                                using: AgentRemoteChannel.parameters(key: key))
        browser.browseResultsChangedHandler = { results, _ in
            AppLogInfo("[AgentRemote] found \(results.count) Phi instance(s)")
            MainActor.assumeIsolated {
                for result in results {
                    AgentRemotePresence.shared.connect(to: result.endpoint, key: key)
                }
            }
        }
        browser.stateUpdateHandler = { state in
            AppLogInfo("[AgentRemote] browser \(state)")
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    private func connect(to endpoint: NWEndpoint, key: SymmetricKey) {
        guard case let .service(name, _, _, _) = endpoint,
              name != instanceId, hosts[name] == nil else { return }
        AppLogInfo("[AgentRemote] connecting to \(name)")
        let channel = AgentRemoteChannel(NWConnection(to: endpoint, using: AgentRemoteChannel.parameters(key: key)))
        hosts[name] = channel
        channel.onReady = { [weak channel, deviceName] in
            channel?.send(.hello(deviceName: deviceName))
        }
        channel.onMessage = { message in
            MainActor.assumeIsolated { AgentRemotePresence.shared.handleHostMessage(message, from: name) }
        }
        channel.onClose = { [weak channel] in
            MainActor.assumeIsolated {
                let presence = AgentRemotePresence.shared
                guard let channel, presence.hosts[name] === channel else { return }
                presence.hosts[name] = nil
                presence.watchedByPeer[name] = nil
                presence.apply(nil, from: name)
            }
        }
        channel.start()
    }

    private func handleHostMessage(_ message: AgentRemoteMessage, from peerId: String) {
        switch message {
        case .snapshot(let snapshot):
            apply(snapshot, from: peerId)
        case .frame(let frame):
            frames.send((peerId, frame))
        case .hello, .watch, .command, .input:
            break
        }
    }

    /// Mirrors the host's task list: a task that ended there (finished,
    /// deleted, timed out) disappears here with its pip, mirror and prompt.
    private func apply(_ snapshot: AgentRemoteSnapshot?, from peerId: String) {
        if let snapshot, !snapshot.tasks.isEmpty {
            peers[peerId] = snapshot
        } else {
            peers[peerId] = nil
        }
        let live = Set((snapshot?.tasks ?? []).map(\.spaceId))
        clearMirrors { $0.peerId == peerId && !live.contains($0.spaceId) }
        syncHandoffPrompts(peerId: peerId, snapshot: snapshot)
    }

    private func syncHandoffPrompts(peerId: String, snapshot: AgentRemoteSnapshot?) {
        let prefix = "remote:\(peerId):"
        var pending: Set<String> = []
        for task in snapshot?.tasks ?? [] where task.handoffMessage != nil {
            let key = prefix + task.spaceId
            pending.insert(key)
            guard !presentedHandoffs.contains(key), let snapshot else { continue }
            let spaceId = task.spaceId
            let shown = AgentSpaceManager.shared.presentRemoteHandoffPrompt(
                key: key, deviceName: snapshot.deviceName,
                message: task.handoffMessage,
                onSwitch: {
                    MainActor.assumeIsolated {
                        let presence = AgentRemotePresence.shared
                        presence.send(.answerHandoff(spaceId: spaceId), to: peerId)
                        presence.showMirror(AgentRemoteMirrorTarget(peerId: peerId, spaceId: spaceId),
                                            in: SpaceManager.shared.keySlot ?? SpaceManager.shared.slots.first)
                    }
                })
            if shown { presentedHandoffs.insert(key) }
        }
        for key in presentedHandoffs where key.hasPrefix(prefix) && !pending.contains(key) {
            presentedHandoffs.remove(key)
            AgentSpaceManager.shared.dismissRemoteHandoffPrompt(key: key)
        }
    }

    func task(for target: AgentRemoteMirrorTarget) -> AgentRemoteTask? {
        peers[target.peerId]?.tasks.first { $0.spaceId == target.spaceId }
    }

    func send(_ command: AgentRemoteCommand, to peerId: String) {
        hosts[peerId]?.send(.command(command))
    }

    func send(_ input: AgentRemoteInput, to peerId: String) {
        hosts[peerId]?.send(.input(input))
    }

    func showMirror(_ target: AgentRemoteMirrorTarget, in slot: SpaceWindowSlot?) {
        slot?.remoteMirror = target
        mirrorsDidChange()
    }

    /// Tells each host which of its Spaces is on screen here, so frames flow
    /// only while someone is looking. ponytail: one watched Space per peer;
    /// send a set when two windows need two Spaces of the same Mac at once.
    func mirrorsDidChange() {
        var wanted: [String: String] = [:]
        for slot in SpaceManager.shared.slots {
            if let target = slot.remoteMirror { wanted[target.peerId] = target.spaceId }
        }
        for peerId in Set(wanted.keys).union(watchedByPeer.keys) where wanted[peerId] != watchedByPeer[peerId] {
            watchedByPeer[peerId] = wanted[peerId]
            hosts[peerId]?.send(.watch(spaceId: wanted[peerId]))
        }
    }

    private func clearMirrors(where shouldClear: (AgentRemoteMirrorTarget) -> Bool) {
        for slot in SpaceManager.shared.slots {
            if let target = slot.remoteMirror, shouldClear(target) { slot.remoteMirror = nil }
        }
        mirrorsDidChange()
    }
}

extension Notification.Name {
    static let agentRemotePresenceSettingDidChange = Notification.Name("PhiAgentRemotePresenceSettingDidChange")
}
