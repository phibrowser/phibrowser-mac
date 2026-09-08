// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import Foundation
import PostHog

/// Folio — the user-facing name of this feature — saves a page as a
/// markdown version and a webpage (MHTML) version, written as a flat pair
/// with one shared basename into the configured folder. Identifiers keep
/// the original SaveForLater/saveForLater names; only the product-facing
/// strings say Folio ("Memory is what Phi remembers about you, Folio is
/// what you chose to keep"). Design:
/// docs/plans/2026-08-31-save-for-later-design.md.
///
/// A save is a background job detached from the tab: both capture legs start
/// the moment the save is triggered, and once their payloads are in hand
/// nothing else needs the page, so closing the tab mid-save loses nothing.
/// The MHTML is unconditional and the markdown best-effort — extension
/// ladder first, the accessibility rung when the DOM defeats it, and a stub
/// carrying the link when both refuse. The user always gets a durable copy.
@MainActor
enum SaveForLaterService {

    /// The master Folio flag: the whole feature — menu rows, the shortcut's
    /// settings listing, the settings sections, the highlight context menu,
    /// site-action auto-save, and the library bridge — sits behind it, so
    /// turning it off makes Folio disappear without a release. Release
    /// builds ask PostHog; DEBUG builds default to on, with
    /// `-FolioFeatureFlag NO` to rehearse the disabled state.
    nonisolated static var featureEnabled: Bool {
        #if DEBUG
        if UserDefaults.standard.object(forKey: "FolioFeatureFlag") != nil {
            return UserDefaults.standard.bool(forKey: "FolioFeatureFlag")
        }
        return true
        #else
        return PostHogSDK.shared.isFeatureEnabled("folio")
        #endif
    }

    /// Tabs with a save in flight, by Chromium tab id. Guards double
    /// triggers the way `ReaderExtensionBridge.pendingExtractions` guards
    /// its RPCs: job bookkeeping, not a state container.
    private static var inFlightTabGuids: Set<Int> = []

    /// Whether the menu item / shortcut should be offered for this tab.
    /// Guest Mode is refused outright: a guest session must not write into
    /// the permanent library. Only web pages are saveable — chrome:// and
    /// chrome-extension:// surfaces (reader pages, settings) are not items.
    static func canSave(_ tab: Tab?) -> Bool {
        guard featureEnabled,
              let tab, !tab.isShowingNativeNTP,
              !ApplicationState.shared.isGuest,
              !inFlightTabGuids.contains(tab.guid),
              let url = tab.url, !url.isEmpty, !url.isLocalUrlString,
              url.lowercased().hasPrefix("http://")
                || url.lowercased().hasPrefix("https://") else {
            return false
        }
        return true
    }

    /// What asked for this save; `siteAction` carries the trigger rule's
    /// action id ("youtube-like", "x-bookmark", …) into the frontmatter, and
    /// `highlight` marks a save whose first cause was a selection highlight
    /// on a page that was not in the library yet.
    enum SaveTrigger {
        case manual
        case siteAction(String)
        case highlight

        var frontmatterValue: String {
            switch self {
            case .manual: return "manual"
            case .siteAction(let action): return action
            case .highlight: return "highlight"
            }
        }

        var isAutomatic: Bool {
            if case .siteAction = self { return true }
            return false
        }
    }

    static func save(tab: Tab, in state: BrowserState,
                     trigger: SaveTrigger = .manual,
                     highlightBlocks: [String] = []) {
        guard canSave(tab) else { return }
        let context = JobContext(
            tabGuid: tab.guid,
            windowId: state.windowId,
            profileId: state.profileId,
            pageTitle: tab.title,
            sourceURL: tab.url ?? "",
            trigger: trigger,
            highlightBlocks: highlightBlocks)
        inFlightTabGuids.insert(context.tabGuid)
        pinFolder(forTab: context.tabGuid, profileId: context.profileId)
        Task {
            await run(tab: tab, context: context)
            inFlightTabGuids.remove(context.tabGuid)
        }
    }

    // MARK: - The job

    /// Everything the job needs from the tab, captured at trigger time so
    /// the rest of the job is indifferent to the tab's fate.
    private struct JobContext {
        let tabGuid: Int
        let windowId: Int
        let profileId: String
        let pageTitle: String
        let sourceURL: String
        let trigger: SaveTrigger
        /// Highlight blocks that are part of the document from the start —
        /// a highlight on an unsaved page saves the page around itself.
        let highlightBlocks: [String]
    }

    /// Hands the save to Mirage, which owns it end to end: extraction, the
    /// document, the files (through the broker below), and the toast. There
    /// is deliberately no second implementation here — one save path, in
    /// the half that ships with the extension updater. Reader View already
    /// depends on Mirage the same way, and Folio's own flag can turn the
    /// feature off if the extension is ever missing.
    ///
    /// So silence has no fallback to fall back TO: it means no Mirage is
    /// listening, and all the app can do is say the save did not happen.
    private static func run(tab: Tab, context: JobContext) async {
        if await requestExtensionSave(tab: tab, context: context) {
            AppLogDebug("[SaveForLater] save accepted by the extension")
            return
        }
        AppLogWarn("[SaveForLater] no extension answered the save request")
        showToast(title: failedToastTitle,
                  message: URL(fileURLWithPath: PhiPreferences.SaveForLater
                      .effectiveFolderPath(forProfile: context.profileId))
                      .lastPathComponent,
                  windowId: context.windowId)
    }

    // MARK: - Site-action auto-save

    /// The remote gate above the user's opt-in: the kill switch for this
    /// feature's characteristic failure — a site markup change making a
    /// trigger rule misfire and spray files to disk — stoppable without an
    /// app release or a rules refresh. Manual saves are not behind it.
    static var autoTriggerFlagEnabled: Bool {
        #if DEBUG
        // Local development: `-SaveForLaterAutoTriggerFlag YES` stands in
        // for the PostHog flag so the trigger chain is testable before the
        // flag exists in the project.
        if UserDefaults.standard.object(forKey: "SaveForLaterAutoTriggerFlag") != nil {
            return UserDefaults.standard.bool(forKey: "SaveForLaterAutoTriggerFlag")
        }
        #endif
        return PostHogSDK.shared.isFeatureEnabled("save-for-later-auto-trigger")
    }

    /// Effective arming: Folio on && flag && user opt-in && not Guest Mode.
    static var autoTriggerArmed: Bool {
        featureEnabled
            && autoTriggerFlagEnabled
            && PhiPreferences.SaveForLater.autoSaveOnSiteActions
            && !ApplicationState.shared.isGuest
    }

    /// Pushes the armed state to Mirage's trigger relay. Called when the
    /// settings toggle flips; Mirage also pulls on boot (`getArmed`).
    static func broadcastArmedState() {
        AppLogDebug("[SaveForLater] broadcasting armed=\(autoTriggerArmed)")
        ExtensionMessaging.shared.broadcast(
            type: "saveForLater.armedChanged",
            payload: "{\"armed\":\(autoTriggerArmed)}")
    }

    /// `saveForLater.getArmed`: Mirage's boot-time pull of the armed state.
    nonisolated static func handleGetArmed(_ context: ExtensionMessageContext) -> String? {
        guard context.senderId == ReaderExtensionBridge.extensionId else {
            AppLogDebug("[SaveForLater] getArmed dropped: sender=\(context.senderId)")
            return "{\"armed\":false,\"enabled\":false}"
        }
        return MainActor.assumeIsolated {
            AppLogDebug("[SaveForLater] getArmed -> \(autoTriggerArmed) " +
                        "(folio=\(featureEnabled) flag=\(autoTriggerFlagEnabled) " +
                        "optIn=\(PhiPreferences.SaveForLater.autoSaveOnSiteActions))")
            // `enabled` is the master Folio flag — Mirage keys its own
            // surfaces (the highlight context menu) off it.
            return "{\"armed\":\(autoTriggerArmed),\"enabled\":\(featureEnabled)}"
        }
    }

    /// Recently auto-saved URLs. Repeated toggling inside the window is one
    /// snapshot; beyond it a re-trigger is a fresh save, consistent with
    /// manual behavior.
    private static var recentAutoSaves: [String: Date] = [:]
    private static let autoSaveDedupWindow: TimeInterval = 600

    private struct TriggerPayload: Decodable {
        let tabId: Int
        let url: String
        let action: String
    }

    /// `saveForLater.trigger`: a site-action activation reported by Mirage.
    /// The app is the authority — the armed check runs again here so a stale
    /// extension cache can never write files past the gate.
    nonisolated static func handleTrigger(_ context: ExtensionMessageContext) {
        guard context.senderId == ReaderExtensionBridge.extensionId else {
            AppLogDebug("[SaveForLater] trigger dropped: sender=\(context.senderId)")
            return
        }
        guard let data = context.payload.data(using: .utf8),
              let payload = try? JSONDecoder().decode(TriggerPayload.self, from: data) else {
            AppLogDebug("[SaveForLater] trigger dropped: bad payload \(context.payload)")
            return
        }
        MainActor.assumeIsolated {
            guard autoTriggerArmed else {
                AppLogDebug("[SaveForLater] trigger dropped: disarmed")
                return
            }
            guard let (tab, state) = findTab(payload.tabId) else {
                AppLogDebug("[SaveForLater] trigger dropped: no tab \(payload.tabId)")
                return
            }
            // The trigger names the page it came from; a tab that has moved
            // on is not saved.
            guard tab.url == payload.url else {
                AppLogDebug("[SaveForLater] trigger dropped: url moved on")
                return
            }
            let now = Date()
            recentAutoSaves = recentAutoSaves.filter {
                now.timeIntervalSince($0.value) < autoSaveDedupWindow
            }
            guard recentAutoSaves[payload.url] == nil else { return }
            recentAutoSaves[payload.url] = now
            AppLogDebug("[SaveForLater] site-action trigger \(payload.action)")
            save(tab: tab, in: state, trigger: .siteAction(payload.action))
        }
    }

    /// The extension speaks in Chromium tab ids (`Tab.guid`); the tab can be
    /// in any window.
    private static func findTab(_ tabId: Int) -> (tab: Tab, state: BrowserState)? {
        for controller in MainBrowserWindowControllersManager.shared.getAllWindows() {
            let state = controller.browserState
            if let tab = state.tabs.first(where: { $0.guid == tabId }) {
                return (tab, state)
            }
        }
        return nil
    }

    // MARK: - Notes

    /// The **Add Note** toast action. The prompt is native because the
    /// toast is; the write goes back to Mirage, so the extension stays the
    /// only writer of a saved item.
    private static func addNoteToastAction(basename: String, block: String,
                                           windowId: Int,
                                           tabId: Int?) -> OverlayToastAction {
        OverlayToastAction(
            title: NSLocalizedString(
                "browser.folio.addNoteAction",
                value: "Add Note",
                comment: "Folio - Button on the highlight toast that opens a small dialog to attach a note to the just-saved highlight"),
            handler: {
                Task { @MainActor in
                    guard let note = await promptForNote(windowId: windowId),
                          !note.isEmpty else { return }
                    let label = NSLocalizedString(
                        "browser.folio.noteLabel",
                        value: "Note",
                        comment: "Folio - Bold lead-in word of a note line written under a highlight in the saved markdown")
                    // The note lands through the same broker the save used,
                    // so it must name the same tab or it resolves a folder
                    // from whichever window is frontmost.
                    var payload: [String: Any] = [
                        "basename": basename,
                        "block": block,
                        "note": "**\(label):** " + note,
                    ]
                    if let tabId { payload["tabId"] = tabId }
                    guard let data = try? JSONSerialization.data(withJSONObject: payload),
                          let json = String(data: data, encoding: .utf8) else { return }
                    ExtensionMessaging.shared.broadcast(
                        type: "saveForLater.addNote", payload: json)
                }
            })
    }

    private static func promptForNote(windowId: Int) async -> String? {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString(
            "browser.folio.addNoteTitle",
            value: "Add Note",
            comment: "Folio - Title of the dialog that attaches a note to a saved highlight")
        alert.informativeText = NSLocalizedString(
            "browser.folio.addNoteMessage",
            value: "The note is written into the saved markdown, under the highlight.",
            comment: "Folio - Explanatory text of the add-note dialog")
        alert.alertStyle = .informational
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.placeholderString = NSLocalizedString(
            "browser.folio.addNotePlaceholder",
            value: "Your note",
            comment: "Folio - Placeholder of the add-note dialog's text field")
        alert.accessoryView = field
        alert.addButton(withTitle: NSLocalizedString(
            "browser.folio.addNoteConfirmButton",
            value: "Save Note",
            comment: "Folio - Confirm button of the add-note dialog"))
        alert.addButton(withTitle: NSLocalizedString(
            "browser.folio.addNoteCancelButton",
            value: "Cancel",
            comment: "Folio - Cancel button of the add-note dialog"))
        alert.window.initialFirstResponder = field
        let window = MainBrowserWindowControllersManager.shared.getAllWindows()
            .first(where: { $0.browserState.windowId == windowId })?.window
        let response: NSApplication.ModalResponse
        if let window {
            response = await alert.beginSheetModal(for: window)
        } else {
            response = alert.runModal()
        }
        guard response == .alertFirstButtonReturn else { return nil }
        return field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `saveForLater.highlight`: the shape an OLD Mirage sends, from before
    /// the extension owned the highlight flow. The app cannot serve it any
    /// more — that engine is gone — but a user action must never be a
    /// silent no-op, so say what is wrong instead of swallowing it. The two
    /// halves ship together, so this is the update-window case only.
    nonisolated static func handleLegacyHighlight(_ context: ExtensionMessageContext) {
        guard context.senderId == ReaderExtensionBridge.extensionId else { return }
        AppLogWarn("[SaveForLater] legacy saveForLater.highlight from a " +
                   "pre-3.7 Mirage; the extension now owns highlights")
        Task { @MainActor in
            guard let windowId = MainBrowserWindowControllersManager.shared
                .getActiveWindowState()?.windowId else { return }
            showToast(
                title: NSLocalizedString(
                    "browser.folio.staleExtensionToast",
                    value: "Folio needs a browser restart",
                    comment: "Folio - Toast shown when the page-side extension is older than the app and can no longer save a highlight"),
                message: "",
                windowId: windowId)
        }
    }

    // MARK: - Library

    /// Opens the Save for Later library — a Mirage extension page that lists
    /// the saved items and renders their markdown with the reader's own
    /// stylesheet. The page cannot touch the folder itself; the
    /// `saveForLater.list/read/delete/reveal/openWebpage` handlers below are
    /// its only access, and this service stays the authority on paths.
    static func openLibrary() {
        openExtensionPage("library.html")
    }

    /// The per-site auto-save list. The sites ARE the extension's trigger
    /// corpus — it grows with a rules update, not an app release — so the
    /// detail lives on Mirage's own page and settings links to it rather
    /// than mirroring a list the app would have to re-learn.
    static func openAutoSaveSites() {
        openExtensionPage("triggers.html")
    }

    private static func openExtensionPage(_ page: String) {
        guard featureEnabled,
              let state = MainBrowserWindowControllersManager.shared
                  .activeWindowController?.browserState else { return }
        state.createTab(
            "chrome-extension://\(ReaderExtensionBridge.extensionId)/\(page)",
            customGuid: nil, focusAfterCreate: true)
    }

    /// The destination a save resolved at trigger time, by tab. A save is a
    /// detached job whose last chunk can land minutes later — after the tab
    /// closed, or after the user focused a window whose profile overrides the
    /// folder — so the answer is pinned here instead of being re-derived from
    /// whatever is frontmost when the I/O runs. Without this, one save's
    /// markdown and webpage copy can land in two different folders.
    private static var pinnedJobFolders: [Int: (folder: URL, at: Date)] = [:]
    /// Longer than any save can take (a video gist is minutes), short enough
    /// that a tab id reused much later resolves freshly.
    private static let pinnedFolderLifetime: TimeInterval = 3600

    private static func pinFolder(forTab tabGuid: Int, profileId: String) {
        let now = Date()
        pinnedJobFolders = pinnedJobFolders.filter {
            now.timeIntervalSince($0.value.at) < pinnedFolderLifetime
        }
        pinnedJobFolders[tabGuid] = (folderURL(forProfile: profileId), now)
    }

    private static func folderURL(forProfile profileId: String) -> URL {
        URL(fileURLWithPath: PhiPreferences.SaveForLater
            .effectiveFolderPath(forProfile: profileId), isDirectory: true)
    }

    /// The folder a request belongs to. A broker call names the tab it is
    /// acting for, so the profile is the one that OWNS that tab — the save's
    /// pinned answer first (it survives the tab closing), then the tab's live
    /// window, and only then the frontmost window for a request that named no
    /// tab at all.
    private static func libraryFolder(forTab tabId: Int? = nil) -> URL {
        if let tabId, let pinned = pinnedJobFolders[tabId],
           Date().timeIntervalSince(pinned.at) < pinnedFolderLifetime {
            return pinned.folder
        }
        if let tabId, let found = findTab(tabId) {
            return folderURL(forProfile: found.state.profileId)
        }
        return folderURL(forProfile: MainBrowserWindowControllersManager.shared
            .getActiveWindowState()?.profileId ?? "")
    }

    private nonisolated static func libraryGate(
        _ context: ExtensionMessageContext) -> Bool {
        context.senderId == ReaderExtensionBridge.extensionId && featureEnabled
    }

    /// A library request names an item by bare basename; anything that could
    /// leave the folder is refused rather than resolved.
    ///
    /// One rule, shared with the write path: `brokerFileName` decides what a
    /// legal name in this folder is, and reading, revealing and deleting ask
    /// it the same question the write asked. When these drifted apart, a
    /// title holding an ellipsis ("Wait... what?") saved fine and then could
    /// not be deleted or revealed, because only this side refused "..".
    nonisolated static func libraryFileURL(
        basename: String, ext: String, folder: URL) -> URL? {
        guard let name = brokerFileName(basename + "." + ext) else { return nil }
        return folder.appendingPathComponent(name)
    }

    private nonisolated static func libraryReply(
        _ json: String, requestId: String) {
        Task {
            await ExtensionMessaging.shared.sendResponse(
                json, requestId: requestId)
        }
    }

    // MARK: - Broker: reading

    /// How much of each markdown file the listing carries. Enough for the
    /// frontmatter block the extension parses, and bounded so a folder of
    /// hundreds of items still fits one bridge message.
    /// Bytes per read chunk: base64 expands 4/3, so 512 KiB stays inside
    /// the bridge's 1 MiB message cap the same way the write path does.
    private nonisolated static let brokerReadChunkBytes = 512 * 1024

    private nonisolated static let listingHeadBytes = 4096
    /// Total heads per listing, well under the bridge's 1 MiB message cap.
    private nonisolated static let listingHeadBudget = 600 * 1024

    /// `data` cut back to the last complete UTF-8 sequence. A fixed byte
    /// prefix can end inside a multi-byte character; decoded as-is that
    /// becomes a replacement character, which then travels into a title.
    ///
    /// A sequence is at most four bytes, so at most three trailing bytes can
    /// belong to an incomplete one — which makes asking the decoder cheaper
    /// and more obviously right than re-deriving the encoding here. Data
    /// that is not valid UTF-8 for some other reason is returned unchanged;
    /// that is the caller's existing lossy behavior, not this function's
    /// problem to solve.
    private nonisolated static func truncatedToUTF8Boundary(_ data: Data) -> Data {
        for dropped in 0...3 {
            let end = data.count - dropped
            if end <= 0 { break }
            let candidate = data.prefix(end)
            if String(data: candidate, encoding: .utf8) != nil { return candidate }
        }
        return data
    }

    private struct BrokerListEntry: Encodable {
        let name: String
        let size: Int
        let modified: Double
        /// First bytes of a markdown file, UTF-8; absent for archives and
        /// once the budget is spent.
        let head: String?
    }

    /// `saveForLater.fs.list`: what the folder holds. The broker reports
    /// names, sizes, timestamps and a bounded head — never what any of it
    /// means; the extension parses frontmatter and builds items.
    /// Every broker call names the tab it acts for, so the folder resolves to
    /// that tab's profile rather than the frontmost window's.
    private struct BrokerScopePayload: Decodable { let tabId: Int? }

    private nonisolated static func brokerTabId(
        _ context: ExtensionMessageContext) -> Int? {
        guard let data = context.payload.data(using: .utf8) else { return nil }
        return (try? JSONDecoder().decode(BrokerScopePayload.self,
                                          from: data))?.tabId
    }

    nonisolated static func handleFSList(_ context: ExtensionMessageContext) {
        guard libraryGate(context) else {
            libraryReply("{\"error\":\"unavailable\"}", requestId: context.requestId)
            return
        }
        let tabId = brokerTabId(context)
        Task { @MainActor in
            guard !ApplicationState.shared.isGuest else {
                libraryReply("{\"error\":\"unavailable\"}",
                             requestId: context.requestId)
                return
            }
            let folder = libraryFolder(forTab: tabId)
            let json = await Task.detached(priority: .utility) { () -> String in
                struct Reply: Encodable {
                    let folder: String
                    let entries: [BrokerListEntry]
                }
                let fileManager = FileManager.default
                let urls: [URL]
                do {
                    urls = try fileManager.contentsOfDirectory(
                        at: folder,
                        includingPropertiesForKeys: [.contentModificationDateKey,
                                                     .fileSizeKey],
                        options: [.skipsHiddenFiles])
                } catch {
                    // A folder that does not exist yet is an EMPTY library —
                    // the first save creates it. A folder that exists and
                    // cannot be read is a failure, and must say so: the
                    // caller reserves basenames from this listing, and an
                    // empty answer would let it claim a name that is already
                    // taken and overwrite the pair sitting there.
                    guard !fileManager.fileExists(atPath: folder.path) else {
                        AppLogWarn("[SaveForLater] list failed: \(error)")
                        return "{\"error\":\"list_failed\"}"
                    }
                    return "{\"folder\":\"\",\"entries\":[]}"
                }
                var entries: [BrokerListEntry] = []
                var headBudget = listingHeadBudget
                for url in urls where ["md", "mhtml"].contains(url.pathExtension) {
                    let values = try? url.resourceValues(
                        forKeys: [.contentModificationDateKey, .fileSizeKey])
                    var head: String?
                    if url.pathExtension == "md", headBudget > 0,
                       let handle = try? FileHandle(forReadingFrom: url) {
                        defer { try? handle.close() }
                        if let data = try? handle.read(upToCount: listingHeadBytes),
                           !data.isEmpty {
                            // A fixed byte prefix can land mid-character.
                            // Frontmatter is ASCII and sits first, but the
                            // head runs on into the body, so the tail is
                            // trimmed back to a character boundary rather
                            // than handed over as replacement characters.
                            head = String(decoding: truncatedToUTF8Boundary(data),
                                          as: UTF8.self)
                            headBudget -= data.count
                        }
                    }
                    entries.append(BrokerListEntry(
                        name: url.lastPathComponent,
                        size: values?.fileSize ?? 0,
                        modified: (values?.contentModificationDate
                                   ?? .distantPast).timeIntervalSince1970,
                        head: head))
                }
                guard let data = try? JSONEncoder().encode(
                    Reply(folder: folder.path, entries: entries)),
                      let json = String(data: data, encoding: .utf8) else {
                    return "{\"error\":\"list_failed\"}"
                }
                return json
            }.value
            libraryReply(json, requestId: context.requestId)
        }
    }

    private struct BrokerReadPayload: Decodable {
        let name: String
        let offset: Int?
        let length: Int?
        let tabId: Int?
    }

    /// `saveForLater.fs.read`: bytes at an offset, base64, so one primitive
    /// serves both the markdown and the multi-megabyte archive the webpage
    /// view unpacks. The caller loops until `eof`.
    nonisolated static func handleFSRead(_ context: ExtensionMessageContext) {
        guard libraryGate(context),
              let data = context.payload.data(using: .utf8),
              let payload = try? JSONDecoder().decode(BrokerReadPayload.self, from: data),
              let name = brokerFileName(payload.name) else {
            libraryReply("{\"error\":\"invalid\"}", requestId: context.requestId)
            return
        }
        Task { @MainActor in
            guard !ApplicationState.shared.isGuest else {
                libraryReply("{\"error\":\"unavailable\"}",
                             requestId: context.requestId)
                return
            }
            let url = libraryFolder(forTab: payload.tabId)
                .appendingPathComponent(name)
            let offset = max(0, payload.offset ?? 0)
            let length = min(max(1, payload.length ?? brokerReadChunkBytes),
                             brokerReadChunkBytes)
            let json = await Task.detached(priority: .utility) { () -> String in
                struct Reply: Encodable {
                    let data: String
                    let eof: Bool
                }
                guard let handle = try? FileHandle(forReadingFrom: url) else {
                    return "{\"error\":\"not_found\"}"
                }
                defer { try? handle.close() }
                do {
                    try handle.seek(toOffset: UInt64(offset))
                    let chunk = try handle.read(upToCount: length) ?? Data()
                    // EOF is a claim about the file, so it needs the file's
                    // size. Without it, "I read fewer bytes than I asked
                    // for" would report as a complete read and the caller
                    // would keep a truncated copy believing it was whole —
                    // a short read is normal, an unstattable file is not.
                    guard let total = try? FileManager.default
                        .attributesOfItem(atPath: url.path)[.size] as? Int else {
                        return "{\"error\":\"read_failed\"}"
                    }
                    let eof = offset + chunk.count >= total
                    let reply = Reply(data: chunk.base64EncodedString(), eof: eof)
                    guard let encoded = try? JSONEncoder().encode(reply),
                          let json = String(data: encoded, encoding: .utf8) else {
                        return "{\"error\":\"read_failed\"}"
                    }
                    return json
                } catch {
                    return "{\"error\":\"read_failed\"}"
                }
            }.value
            libraryReply(json, requestId: context.requestId)
        }
    }

    private struct LibraryItemPayload: Decodable {
        let basename: String
        /// The library page's own tab, when the action targets its window.
        let tabId: Int?
    }

    private nonisolated static func libraryItemPayload(
        _ context: ExtensionMessageContext) -> LibraryItemPayload? {
        guard let data = context.payload.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(LibraryItemPayload.self, from: data)
    }

    /// `saveForLater.delete`: removes an item's pair from the folder for
    /// good. Delete means delete — the library page arms the button before
    /// it will act, and that confirmation, not the Trash, is what stands
    /// between a mis-click and a lost item.
    nonisolated static func handleLibraryDelete(_ context: ExtensionMessageContext) {
        guard libraryGate(context) else {
            libraryReply("{\"error\":\"unavailable\"}", requestId: context.requestId)
            return
        }
        guard let payload = libraryItemPayload(context) else {
            libraryReply("{\"error\":\"invalid\"}", requestId: context.requestId)
            return
        }
        Task { @MainActor in
            let folder = libraryFolder(forTab: payload.tabId)
            guard !ApplicationState.shared.isGuest,
                  libraryFileURL(basename: payload.basename, ext: "md",
                                 folder: folder) != nil else {
                libraryReply("{\"error\":\"invalid\"}",
                             requestId: context.requestId)
                return
            }
            let basename = payload.basename
            await Task.detached(priority: .utility) {
                let fileManager = FileManager.default
                for ext in ["md", "mhtml"] {
                    let url = folder.appendingPathComponent(basename + "." + ext)
                    if fileManager.fileExists(atPath: url.path) {
                        try? fileManager.removeItem(at: url)
                    }
                }
            }.value
            libraryReply("{\"ok\":true}", requestId: context.requestId)
        }
    }

    /// `saveForLater.reveal`: the pair in Finder.
    nonisolated static func handleLibraryReveal(_ context: ExtensionMessageContext) {
        guard libraryGate(context) else { return }
        guard let payload = libraryItemPayload(context) else { return }
        Task { @MainActor in
            guard !ApplicationState.shared.isGuest,
                  let url = libraryFileURL(
                      basename: payload.basename, ext: "md",
                      folder: libraryFolder(forTab: payload.tabId)),
                  FileManager.default.fileExists(atPath: url.path) else {
                return
            }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    // MARK: - Toasts

    private static var failedToastTitle: String {
        NSLocalizedString(
            "browser.folio.failedToast",
            value: "Couldn't save this page",
            comment: "Folio - Toast shown when nothing could be written to the destination folder")
    }

    /// The wording for an outcome the extension named. Toasts are window
    /// chrome, so they belong in the app's language — the extension bundle
    /// carries no translation for the browser's locale, and a save is not
    /// the place to discover that.
    private static func toastTitle(forKey key: String) -> String? {
        switch key {
        case "saved":
            return NSLocalizedString(
                "browser.folio.savedToast",
                value: "Saved to Folio",
                comment: "Folio - Toast shown when a page was saved as both a markdown article and a webpage copy")
        case "savedWithoutWebpage":
            return NSLocalizedString(
                "browser.folio.savedWithoutWebpageToast",
                value: "Saved without webpage copy",
                comment: "Folio - Toast shown when the article was saved but the copy of the original web page could not be captured")
        case "savedWithoutVideoArticle":
            return NSLocalizedString(
                "browser.folio.savedWithoutArticleToast",
                value: "Saved without video article",
                comment: "Folio - Toast shown when a video was saved but could not be turned into a written article")
        case "savedPartial":
            return NSLocalizedString(
                "browser.folio.savedPartialToast",
                value: "Saved only what had loaded",
                comment: "Folio - Toast shown when a page whose reader source did not answer was saved from the loaded page instead, so the item holds less than the whole page")
        case "alreadySaved":
            return NSLocalizedString(
                "browser.folio.alreadySavedToast",
                value: "Already in Folio",
                comment: "Folio - Toast shown when a page is saved again: the item it already has is kept rather than a second copy being written")
        case "highlightSaved":
            return NSLocalizedString(
                "browser.folio.highlightSavedToast",
                value: "Highlight saved",
                comment: "Folio - Toast shown when a selected passage was added to the page's saved item")
        case "failed":
            return failedToastTitle
        default:
            return nil
        }
    }

    /// The second line of a failure toast: why, in words. An unrecognized
    /// code says nothing rather than leaking an identifier.
    private static func toastReason(_ code: String) -> String {
        switch code {
        case "folder_unreadable":
            return NSLocalizedString(
                "browser.folio.reasonFolderUnreadable",
                value: "The Folio folder could not be read.",
                comment: "Folio - Failure toast detail: the destination folder exists but could not be listed, so saving would risk overwriting an item already there")
        case "markdown_write_failed":
            return NSLocalizedString(
                "browser.folio.reasonWriteFailed",
                value: "Nothing could be written to the Folio folder.",
                comment: "Folio - Failure toast detail: the destination folder could not be written to")
        case "not_a_web_page":
            return NSLocalizedString(
                "browser.folio.reasonNotAWebPage",
                value: "Only web pages can be saved.",
                comment: "Folio - Failure toast detail: the tab was not showing an ordinary web page")
        default:
            AppLogDebug("[SaveForLater] unworded toast reason: \(code)")
            return ""
        }
    }

    private static func showToast(title: String, message: String, windowId: Int) {
        OverlayToastCenter.shared.show(
            title: title, message: message, in: .windowId(windowId))
    }

    /// Undo trashes the pair the automatic save wrote — unless the user has
    /// since highlighted it. A highlight is deliberate work the file now
    /// carries alone, so Undo yields to it rather than deleting it; the
    /// rename that a highlight performs also means `basename` no longer
    /// resolves, which is the same conclusion by a second route.
    private static func trashPair(basename: String, folder: URL) {
        Task.detached(priority: .utility) {
            let fileManager = FileManager.default
            let markdown = folder.appendingPathComponent(basename + ".md")
            if let content = try? String(contentsOf: markdown, encoding: .utf8),
               content.contains("\n## Highlights\n") {
                AppLogDebug("[SaveForLater] undo skipped: item has highlights")
                return
            }
            for ext in ["md", "mhtml"] {
                let url = folder.appendingPathComponent(basename + "." + ext)
                if fileManager.fileExists(atPath: url.path) {
                    try? fileManager.trashItem(at: url, resultingItemURL: nil)
                }
            }
        }
    }

    // MARK: - Broker: text, rename, toast

    private struct BrokerTextPayload: Decodable {
        let name: String
        let text: String
        let tabId: Int?
    }

    /// `saveForLater.fs.writeText`: a whole small file in one message —
    /// markdown documents, which are far under the bridge's 1 MiB cap. The
    /// archive path uses the chunked write instead.
    nonisolated static func handleFSWriteText(_ context: ExtensionMessageContext) {
        guard libraryGate(context),
              let data = context.payload.data(using: .utf8),
              let payload = try? JSONDecoder().decode(BrokerTextPayload.self, from: data),
              let name = brokerFileName(payload.name) else {
            libraryReply("{\"error\":\"invalid\"}", requestId: context.requestId)
            return
        }
        Task { @MainActor in
            guard !ApplicationState.shared.isGuest else {
                libraryReply("{\"error\":\"unavailable\"}",
                             requestId: context.requestId)
                return
            }
            let folder = libraryFolder(forTab: payload.tabId)
            let text = payload.text
            let ok = await Task.detached(priority: .utility) { () -> Bool in
                do {
                    try FileManager.default.createDirectory(
                        at: folder, withIntermediateDirectories: true)
                    try Data(text.utf8).write(
                        to: folder.appendingPathComponent(name), options: .atomic)
                    return true
                } catch {
                    return false
                }
            }.value
            libraryReply(ok ? "{\"ok\":true}" : "{\"error\":\"write_failed\"}",
                         requestId: context.requestId)
        }
    }

    private struct BrokerRenamePayload: Decodable {
        let from: String
        let to: String
        let tabId: Int?
    }

    /// `saveForLater.fs.rename`: moves a pair to a new basename (the video
    /// title promotion). Replies with the basename in effect afterwards —
    /// the old one when the move failed, so the caller's next write lands
    /// on a file that exists.
    nonisolated static func handleFSRename(_ context: ExtensionMessageContext) {
        guard libraryGate(context),
              let data = context.payload.data(using: .utf8),
              let payload = try? JSONDecoder().decode(BrokerRenamePayload.self, from: data),
              brokerFileName(payload.from + ".md") != nil,
              brokerFileName(payload.to + ".md") != nil else {
            libraryReply("{\"error\":\"invalid\"}", requestId: context.requestId)
            return
        }
        Task { @MainActor in
            guard !ApplicationState.shared.isGuest else {
                libraryReply("{\"error\":\"unavailable\"}",
                             requestId: context.requestId)
                return
            }
            let folder = libraryFolder(forTab: payload.tabId)
            let from = payload.from
            let to = payload.to
            let landed = await Task.detached(priority: .utility) { () -> String in
                renamePairSync(from: from, to: to, folder: folder)
            }.value
            let encoded = (try? JSONEncoder().encode(["basename": landed]))
                .flatMap { String(data: $0, encoding: .utf8) }
            libraryReply(encoded ?? "{\"error\":\"rename_failed\"}",
                         requestId: context.requestId)
        }
    }

    private struct ToastPayload: Decodable {
        /// The outcome, named rather than worded: the extension says WHICH
        /// toast, the app says it in the browser's language — the extension
        /// bundle carries no translation for the browser's locale, and a
        /// save is not the place to discover that.
        let titleKey: String
        let message: String?
        /// A stable failure code (`folder_unreadable`, …). Rendered here —
        /// `markdown_write_failed` is a log line, not a sentence to show
        /// someone.
        let reason: String?
        /// Present for an automatic save: the toast offers Undo, which
        /// trashes that pair (unless it has since gained highlights).
        let undoBasename: String?
        /// Present for a highlight: the toast offers Add Note, anchored to
        /// this item and quote.
        let noteBasename: String?
        let noteBlock: String?
        let tabId: Int?
    }

    /// `saveForLater.toast`: native completion feedback for a save the
    /// extension ran. Toasts stay app-side — they belong to the window
    /// chrome, not the page.
    nonisolated static func handleToast(_ context: ExtensionMessageContext) {
        guard libraryGate(context),
              let data = context.payload.data(using: .utf8),
              let payload = try? JSONDecoder().decode(ToastPayload.self, from: data) else {
            return
        }
        Task { @MainActor in
            let windowId = payload.tabId.flatMap { findTab($0)?.state.windowId }
                ?? MainBrowserWindowControllersManager.shared
                    .getActiveWindowState()?.windowId
            guard let windowId else { return }
            guard let title = toastTitle(forKey: payload.titleKey) else {
                AppLogDebug("[SaveForLater] toast dropped: unknown outcome " +
                            payload.titleKey)
                return
            }
            let message = payload.reason.map { toastReason($0) }
                ?? payload.message ?? ""
            let folder = libraryFolder(forTab: payload.tabId)
            if let noteBasename = payload.noteBasename,
               let noteBlock = payload.noteBlock {
                OverlayToastCenter.shared.show(
                    title: title, message: message,
                    duration: 6, in: .windowId(windowId),
                    action: addNoteToastAction(basename: noteBasename,
                                               block: noteBlock,
                                               windowId: windowId,
                                               tabId: payload.tabId))
                return
            }
            guard let undo = payload.undoBasename else {
                showToast(title: title, message: message, windowId: windowId)
                return
            }
            let action = OverlayToastAction(
                title: NSLocalizedString(
                    "browser.folio.undoAction",
                    value: "Undo",
                    comment: "Folio - Undo button on the toast after an automatic site-action save; moves the just-saved files to the Trash"),
                handler: { trashPair(basename: undo, folder: folder) })
            OverlayToastCenter.shared.show(
                title: title, message: message,
                duration: 6, in: .windowId(windowId), action: action)
        }
    }

    // MARK: - Extension-driven saves

    private struct SaveResult: Decodable {
        let requestId: String
        let ok: Bool
        let error: String?
    }

    private static var pendingSaves:
        [String: CheckedContinuation<Bool, Never>] = [:]

    /// Asks Mirage to run the whole save — extraction, document, files,
    /// toast. The reply acknowledges that the extension ACCEPTED the save,
    /// not that it finished: a video save waits minutes on the gist, and
    /// waiting for completion here would time out mid-flight and write the
    /// item a second time. A short budget is therefore right — silence
    /// means no extension is listening, which is the cue to fall back.
    private static func requestExtensionSave(tab: Tab, context: JobContext,
                                             timeout: TimeInterval = 12) async -> Bool {
        let requestId = UUID().uuidString
        let windowId = MainBrowserWindowControllersManager.shared.getAllWindows()
            .first(where: { controller in
                controller.browserState.tabs.contains(where: { $0.guid == tab.guid })
            })?.browserState.windowId
        var payload: [String: Any] = [
            "tabId": tab.guid,
            "requestId": requestId,
            "trigger": context.trigger.frontmatterValue,
            "isAutomatic": context.trigger.isAutomatic,
            "highlightBlocks": context.highlightBlocks,
        ]
        if let windowId { payload["windowId"] = windowId }
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return false }
        ExtensionMessaging.shared.broadcast(type: "saveForLater.save",
                                            payload: json)
        return await withCheckedContinuation { continuation in
            pendingSaves[requestId] = continuation
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                pendingSaves.removeValue(forKey: requestId)?.resume(returning: false)
            }
        }
    }

    /// `saveForLater.saveResult`: the reply to a save request.
    nonisolated static func handleSaveResult(_ context: ExtensionMessageContext) {
        guard context.senderId == ReaderExtensionBridge.extensionId,
              let data = context.payload.data(using: .utf8),
              let result = try? JSONDecoder().decode(SaveResult.self, from: data) else {
            return
        }
        MainActor.assumeIsolated {
            if !result.ok {
                AppLogDebug("[SaveForLater] extension save failed: " +
                            (result.error ?? "unknown"))
            }
            pendingSaves.removeValue(forKey: result.requestId)?
                .resume(returning: result.ok)
        }
    }

    private struct VideoGistPayload: Decodable { let url: String }

    /// `saveForLater.videoGist`: the app still owns the authenticated call
    /// to phi-agent, so Mirage asks for the article rather than carrying
    /// credentials. Moving this is a later phase.
    nonisolated static func handleVideoGist(_ context: ExtensionMessageContext) {
        guard libraryGate(context),
              let data = context.payload.data(using: .utf8),
              let payload = try? JSONDecoder().decode(VideoGistPayload.self, from: data) else {
            libraryReply("{\"error\":\"invalid\"}", requestId: context.requestId)
            return
        }
        Task { @MainActor in
            guard PhiPreferences.AISettings.phiAIEnabled.loadValue(),
                  ApplicationState.shared.isAuthenticated else {
                libraryReply("{\"error\":\"unavailable\"}",
                             requestId: context.requestId)
                return
            }
            do {
                let article = try await APIClient.shared
                    .generateVideoGistArticle(videoURL: payload.url)
                struct Reply: Encodable {
                    let markdown: String
                    let truncated: Bool
                }
                let encoded = try JSONEncoder().encode(
                    Reply(markdown: article.markdown, truncated: article.truncated))
                libraryReply(String(data: encoded, encoding: .utf8) ?? "{}",
                             requestId: context.requestId)
            } catch let error as APIClient.VideoGistError {
                // A code the endpoint actually reported.
                libraryReply("{\"error\":\"\(error.code)\"}",
                             requestId: context.requestId)
            } catch {
                // Never borrow the endpoint's vocabulary for a failure that
                // never reached it: "video_gist_failed" means generation
                // failed, while this is the backend being unreachable
                // (dev stack down, transport refused, timeout).
                AppLogWarn("[SaveForLater] video gist unreachable: \(error)")
                libraryReply("{\"error\":\"video_gist_unreachable\"}",
                             requestId: context.requestId)
            }
        }
    }

    // MARK: - File broker

    /// The broker is deliberately dumb: jailed file primitives for Mirage,
    /// no policy. Writes stream in bounded base64 chunks into a hidden part
    /// file and land atomically on `writeEnd`; an abandoned write is swept
    /// after a timeout. Chunks arrive strictly in order — the extension
    /// awaits each reply before sending the next.
    private struct BrokerWrite {
        let handle: FileHandle
        let partURL: URL
        let finalURL: URL
        /// When this write last made progress. The sweep is an IDLE timeout,
        /// not a deadline from `writeBegin`: a large archive streams in 512
        /// KiB round trips, and a fixed budget from the start would drop the
        /// token out from under a capture that was still going fine, leaving
        /// every remaining chunk to fail as `unknown_token`.
        var touched: Date
    }

    private static var brokerWrites: [String: BrokerWrite] = [:]

    /// A broker file name is a bare `<basename>.md|.mhtml` inside the
    /// folder; anything that could escape it is refused.
    ///
    /// Traversal is separators plus the `.`/`..` components themselves, not
    /// the two characters wherever they appear: a page whose title ends in
    /// a period ("… worth knowing.") produces "… worth knowing..md", which
    /// is an ordinary file, and refusing it cost a real save.
    nonisolated static func brokerFileName(_ name: String) -> String? {
        guard !name.isEmpty, !name.contains("/"), !name.contains("\\"),
              !name.contains("\0"), !name.hasPrefix("."),
              name.hasSuffix(".md") || name.hasSuffix(".mhtml") else {
            return nil
        }
        return name
    }

    private struct BrokerBeginPayload: Decodable {
        let name: String
        let tabId: Int?
    }
    private struct BrokerChunkPayload: Decodable {
        let token: String
        let data: String
    }
    private struct BrokerEndPayload: Decodable { let token: String }

    nonisolated static func handleFSWriteBegin(_ context: ExtensionMessageContext) {
        guard libraryGate(context),
              let data = context.payload.data(using: .utf8),
              let payload = try? JSONDecoder().decode(BrokerBeginPayload.self, from: data),
              let name = brokerFileName(payload.name) else {
            libraryReply("{\"error\":\"invalid\"}", requestId: context.requestId)
            return
        }
        Task { @MainActor in
            guard !ApplicationState.shared.isGuest else {
                libraryReply("{\"error\":\"unavailable\"}",
                             requestId: context.requestId)
                return
            }
            let folder = libraryFolder(forTab: payload.tabId)
            let token = UUID().uuidString
            let partURL = folder.appendingPathComponent(".folio-part-" + token)
            do {
                try FileManager.default.createDirectory(
                    at: folder, withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: partURL.path, contents: nil)
                let handle = try FileHandle(forWritingTo: partURL)
                brokerWrites[token] = BrokerWrite(
                    handle: handle, partURL: partURL,
                    finalURL: folder.appendingPathComponent(name),
                    touched: Date())
                // Sweep an upload the extension abandoned mid-stream, once it
                // has actually gone quiet.
                scheduleBrokerSweep(token: token, name: name)
                libraryReply("{\"token\":\"\(token)\"}",
                             requestId: context.requestId)
            } catch {
                AppLogWarn("[SaveForLater] broker begin failed: \(error)")
                libraryReply("{\"error\":\"write_failed\"}",
                             requestId: context.requestId)
            }
        }
    }

    /// Idle timeout for one streamed write. Generous: it only has to be
    /// longer than the gap between two chunks, never longer than a whole
    /// capture.
    private static let brokerWriteIdleTimeout: TimeInterval = 180

    /// Re-arms itself while the write keeps making progress, and only closes
    /// out a token that has been silent for the whole idle window.
    private static func scheduleBrokerSweep(token: String, name: String) {
        Task { @MainActor in
            while true {
                guard let write = brokerWrites[token] else { return }
                let idle = Date().timeIntervalSince(write.touched)
                if idle >= brokerWriteIdleTimeout {
                    brokerWrites.removeValue(forKey: token)
                    try? write.handle.close()
                    try? FileManager.default.removeItem(at: write.partURL)
                    AppLogDebug("[SaveForLater] broker write swept: \(name)")
                    return
                }
                let remaining = brokerWriteIdleTimeout - idle
                try? await Task.sleep(
                    nanoseconds: UInt64(remaining * 1_000_000_000))
            }
        }
    }

    nonisolated static func handleFSWriteChunk(_ context: ExtensionMessageContext) {
        guard libraryGate(context),
              let data = context.payload.data(using: .utf8),
              let payload = try? JSONDecoder().decode(BrokerChunkPayload.self, from: data),
              let chunk = Data(base64Encoded: payload.data) else {
            libraryReply("{\"error\":\"invalid\"}", requestId: context.requestId)
            return
        }
        Task { @MainActor in
            guard let write = brokerWrites[payload.token] else {
                libraryReply("{\"error\":\"unknown_token\"}",
                             requestId: context.requestId)
                return
            }
            let outcome = await Task.detached(priority: .utility) { () -> Bool in
                do {
                    try write.handle.write(contentsOf: chunk)
                    return true
                } catch {
                    return false
                }
            }.value
            if outcome {
                brokerWrites[payload.token]?.touched = Date()
                libraryReply("{\"ok\":true}", requestId: context.requestId)
            } else {
                brokerWrites.removeValue(forKey: payload.token)
                try? write.handle.close()
                try? FileManager.default.removeItem(at: write.partURL)
                libraryReply("{\"error\":\"write_failed\"}",
                             requestId: context.requestId)
            }
        }
    }

    nonisolated static func handleFSWriteEnd(_ context: ExtensionMessageContext) {
        guard libraryGate(context),
              let data = context.payload.data(using: .utf8),
              let payload = try? JSONDecoder().decode(BrokerEndPayload.self, from: data) else {
            libraryReply("{\"error\":\"invalid\"}", requestId: context.requestId)
            return
        }
        Task { @MainActor in
            guard let write = brokerWrites.removeValue(forKey: payload.token) else {
                libraryReply("{\"error\":\"unknown_token\"}",
                             requestId: context.requestId)
                return
            }
            let outcome = await Task.detached(priority: .utility) { () -> Bool in
                do {
                    try write.handle.close()
                    // Replace rather than remove-then-move: the window
                    // between the two is one where a re-save of an item has
                    // deleted the copy the user had and not yet written the
                    // new one.
                    if FileManager.default.fileExists(atPath: write.finalURL.path) {
                        _ = try FileManager.default.replaceItemAt(
                            write.finalURL, withItemAt: write.partURL)
                    } else {
                        try FileManager.default.moveItem(at: write.partURL,
                                                         to: write.finalURL)
                    }
                    return true
                } catch {
                    try? FileManager.default.removeItem(at: write.partURL)
                    return false
                }
            }.value
            libraryReply(outcome ? "{\"ok\":true}" : "{\"error\":\"write_failed\"}",
                         requestId: context.requestId)
        }
    }

    // MARK: - Naming

    /// The first basename whose pair is free, bumping with ` 2`, ` 3`, … The
    /// extension reserves names the same way from its listing; this is the
    /// check at the moment of the move, where it is authoritative.
    private nonisolated static func firstFreeBasename(_ desired: String,
                                                      folder: URL) -> String {
        let fileManager = FileManager.default
        var candidate = desired
        var counter = 2
        func taken(_ name: String) -> Bool {
            fileManager.fileExists(
                atPath: folder.appendingPathComponent(name + ".md").path)
            || fileManager.fileExists(
                atPath: folder.appendingPathComponent(name + ".mhtml").path)
        }
        while taken(candidate) {
            candidate = "\(desired) \(counter)"
            counter += 1
        }
        return candidate
    }

    /// Moves a pair to a new basename, off the main actor. The markdown is
    /// the item — if its move fails nothing has changed and the old name is
    /// returned, so the caller's next write still lands on a file that
    /// exists. The webpage copy follows when there is one.
    private nonisolated static func renamePairSync(
        from oldBasename: String, to desired: String, folder: URL) -> String {
        guard desired != oldBasename else { return oldBasename }
        let fileManager = FileManager.default
        let target = firstFreeBasename(desired, folder: folder)
        do {
            try fileManager.moveItem(
                at: folder.appendingPathComponent(oldBasename + ".md"),
                to: folder.appendingPathComponent(target + ".md"))
        } catch {
            return oldBasename
        }
        let oldWebpage = folder.appendingPathComponent(oldBasename + ".mhtml")
        if fileManager.fileExists(atPath: oldWebpage.path) {
            try? fileManager.moveItem(
                at: oldWebpage,
                to: folder.appendingPathComponent(target + ".mhtml"))
        }
        return target
    }
}
