// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import Combine
import Security

/// Tracks whether focus is in web content or the AI Chat sidebar.
enum FocusTarget {
    case webContent
    case aiChat
}

protocol WebContentRepresentable {
    var url: String? { get }
    var webContentWrapper: (WebContentWrapper & NSObject)? { get }
}

struct TabSecurityInfo {
    let isSecure: Bool?  // nil for not fully secure
    let certificates: [SecCertificate]
    let raw: [String: Any]

    init(isSecure: Bool, certificates: [SecCertificate], raw: [String: Any]) {
        self.isSecure = isSecure
        self.certificates = certificates
        self.raw = raw
    }

    static let empty = TabSecurityInfo(isSecure: false, certificates: [], raw: [:])

    init(dictionary: [String: Any]?) {
        let dict = dictionary ?? [:]
        let securityLevel = dict["securityLevel"] as? Int ?? 0
        let hasCertificate = dict["hasCertificate"] as? Bool ?? false
        if securityLevel == 0 {
            self.isSecure = nil
        } else {
            self.isSecure = (securityLevel == 3) && hasCertificate
        }
        self.certificates = Self.makeCertificates(from: dict["certificateChainBase64"])
        self.raw = dict
    }

    private static func makeCertificates(from value: Any?) -> [SecCertificate] {
        guard let base64Chain = value as? [String] else {
            return []
        }
        return base64Chain.compactMap { base64 in
            guard let der = Data(base64Encoded: base64) else {
                return nil
            }
            return SecCertificateCreateWithData(nil, der as CFData)
        }
    }
}

class Tab: WebContentRepresentable {
    private(set) var index: Int = 0
    @Published var isActive: Bool = false
    @Published private(set) var faviconUrl: String?
    @Published private(set) var cachedFaviconData: Data?
    @Published private(set) var liveFaviconData: Data?
    @Published private(set) var liveFaviconRevision: Int = 0
    @Published private(set) var isLoading = false
    @Published private(set) var loadingProgress: CGFloat = 1
    @Published private(set) var canGoBack: Bool = false
    @Published private(set) var canGoForward: Bool = false
    @Published private(set) var isCurrentlyAudible: Bool = false
    @Published private(set) var isAudioMuted: Bool = false
    @Published private(set) var isCapturingAudio: Bool = false
    @Published private(set) var isCapturingVideo: Bool = false
    @Published private(set) var isCapturingWindow: Bool = false
    @Published private(set) var isCapturingDisplay: Bool = false
    @Published private(set) var isCapturingTab: Bool = false
    @Published private(set) var isBeingMirrored: Bool = false
    @Published private(set) var isSharingScreen: Bool = false
    /// Whether this tab is currently in HTML5 content fullscreen. Driven by
    /// the bridge event `tabContentFullscreenChanged`. The container view
    /// controller subscribes to this to re-parent `hostView` on/off the
    /// window's top-level overlay layer.
    @Published var isInContentFullscreen: Bool = false
    @Published var isPinned = false
    @Published var title: String = ""
    @Published var url: String?
    @Published private(set) var securityInfo: TabSecurityInfo = .empty
    
    /// Per-tab AI Chat sidebar collapsed state.
    @Published var aiChatCollapsed: Bool = true
    @Published var aiChatEnabled: Bool = false

    /// Use native NTP rendering when the tab URL is an NTP URL.
    var usesNativeNTP: Bool = false

    /// Whether this tab is currently rendered by the native NTP view (rather
    /// than Chromium's WebContents). Mirrored from `WebContentViewController.contentMode`
    /// so consumers outside the view controller (e.g. key-event dispatch) can
    /// reliably tell that no WebContents is visible.
    var isShowingNativeNTP: Bool = false

    
    // =========================================================================
    // Flicker fix: Track first paint state for new tab switching (scenario 2)
    // =========================================================================

    /// Whether this tab has completed its first visually non-empty paint.
    /// Used to determine if we can immediately show this tab (true) or need to
    /// wait for first paint notification (false) when switching to it.
    var hasFirstPaint: Bool = false

    // =========================================================================
    // DevTools embedding state
    // =========================================================================

    /// Whether a docked DevTools is currently attached to this tab.
    var devToolsAttached: Bool = false
    /// The DevTools NSView (owned by Chromium, we just hold a reference).
    var devToolsView: NSView?
    /// Last known inspected page bounds (for restoring on tab switch).
    var inspectedPageBounds: CGRect?
    /// Whether the inspected content should be hidden (e.g. device emulation fullscreen).
    var hideInspectedContents: Bool = false

    /// Last known focus target used when restoring tab focus.
    var lastFocusTarget: FocusTarget? = .webContent
    
    /// Called when the tab's web content becomes focused.
    var onFocusGained: (() -> Void)?
    
    private(set) var webContentWrapper: (WebContentWrapper & NSObject)?
    let parent: Tab? = nil
    let subTabs: [Tab] = []
    var guid: Int
    var guidInLocalDB: String? = nil
    var profileId: String?
    var windowId: Int = 0
    var isOpenned = true
    /// DB-persisted title that bypasses title KVO from `webContentWrapper`.
    var storedTitle: String?
    /// Original URL persisted in the database for pinned tabs, immune to navigation KVO.
    var pinnedUrl: String?
    var webContentView: NSView? { webContentWrapper?.nativeView }
    
    private var cancellables = Set<AnyCancellable>()
    private var faviconSnapshotUpdater: ((Data) -> Void)?
    
    init(guid: Int = UUID().hashValue,
         url: String?,
         isActive: Bool,
         index: Int,
         title: String? = "",
         webContentView: (WebContentWrapper & NSObject)? = nil,
         customGuid: String? = nil,
         windowId: Int = 0,
         profileId: String? = nil,
         faviconData: Data? = nil) {
        self.guid = guid
        self.url = url
        self.isActive = isActive
        self.index = index
        self.title = title ?? ""
        self.webContentWrapper = webContentView
        self.guidInLocalDB = customGuid
        self.windowId = windowId
        self.profileId = profileId
        self.cachedFaviconData = faviconData
        setupObservers(for: webContentView)
    }
    
    private func setupObservers<Wrapper: WebContentWrapper & NSObject>(for wrapper: Wrapper?) {
        cancellables.forEach { $0.cancel() }
        cancellables.removeAll()
        liveFaviconData = nil
        liveFaviconRevision = 0

        guard let wrapper else {
            return
        }

        faviconUrl = wrapper.favIconURL
        liveFaviconData = wrapper.favIconData
        liveFaviconRevision = wrapper.favIconRevision
        updateCachedFaviconData(wrapper.favIconData)
        
        wrapper.publisher(for: \.favIconURL)
            .assign(to: \.faviconUrl, on: self)
            .store(in: &cancellables)

        wrapper.publisher(for: \.favIconData)
            .sink { [weak self] data in
                self?.liveFaviconData = data
                self?.updateCachedFaviconData(data)
            }
            .store(in: &cancellables)

        wrapper.publisher(for: \.favIconRevision)
            .assign(to: \.liveFaviconRevision, on: self)
            .store(in: &cancellables)
        
        wrapper.publisher(for: \.isLoading)
            .assign(to: \.isLoading, on: self)
            .store(in: &cancellables)
        
        wrapper.publisher(for: \.loadProgress)
            .assign(to: \.loadingProgress, on: self)
            .store(in: &cancellables)
        
        wrapper.publisher(for: \.canGoBack)
            .assign(to: \.canGoBack, on: self)
            .store(in: &cancellables)
        
        wrapper.publisher(for: \.canGoForward)
            .assign(to: \.canGoForward, on: self)
            .store(in: &cancellables)

        wrapper.publisher(for: \.isCurrentlyAudible)
            .assign(to: \.isCurrentlyAudible, on: self)
            .store(in: &cancellables)

        wrapper.publisher(for: \.isAudioMuted)
            .assign(to: \.isAudioMuted, on: self)
            .store(in: &cancellables)

        wrapper.publisher(for: \.isCapturingAudio)
            .assign(to: \.isCapturingAudio, on: self)
            .store(in: &cancellables)

        wrapper.publisher(for: \.isCapturingVideo)
            .assign(to: \.isCapturingVideo, on: self)
            .store(in: &cancellables)

        wrapper.publisher(for: \.isCapturingWindow)
            .assign(to: \.isCapturingWindow, on: self)
            .store(in: &cancellables)

        wrapper.publisher(for: \.isCapturingDisplay)
            .assign(to: \.isCapturingDisplay, on: self)
            .store(in: &cancellables)

        wrapper.publisher(for: \.isCapturingTab)
            .assign(to: \.isCapturingTab, on: self)
            .store(in: &cancellables)

        wrapper.publisher(for: \.isBeingMirrored)
            .assign(to: \.isBeingMirrored, on: self)
            .store(in: &cancellables)

        wrapper.publisher(for: \.isSharingScreen)
            .assign(to: \.isSharingScreen, on: self)
            .store(in: &cancellables)
        
        wrapper.publisher(for: \.title)
            .replaceNil(with: "")
            .sink { [weak self] title in
                guard let self else { return }
                if let localTitle = self.storedTitle, !localTitle.isEmpty {
                    self.title = localTitle
                } else {
                    self.title = title
                }
            }
            .store(in: &cancellables)
        
        wrapper.publisher(for: \.urlString)
            .assign(to: \.url, on: self)
            .store(in: &cancellables)

        wrapper.publisher(for: \.securityInfo)
            .map { value in
                TabSecurityInfo(dictionary: value)
            }
            .assign(to: \.securityInfo, on: self)
            .store(in: &cancellables)
        
        $url
            .compactMap { urlStr in
                guard let urlStr else {
                    return false
                }
                return !urlStr.isNTPUrlString
            }
            .assign(to: \.aiChatEnabled, on: self)
            .store(in: &cancellables)
        
        wrapper.publisher(for: \.isFocused)
            .removeDuplicates()
            .filter { $0 }
            .sink { [weak self] _ in
                self?.onFocusGained?()
            }
            .store(in: &cancellables)
    }
    
    func setWebContentsWrapper(wrapper: (WebContentWrapper & NSObject)?) {
        self.webContentWrapper = wrapper
        setupObservers(for: wrapper)
    }
    
    func setFaviconSnapshotUpdater(_ updater: @escaping (Data) -> Void) {
        faviconSnapshotUpdater = updater
    }
    
    func updateCachedFaviconData(_ data: Data?) {
        guard let data, cachedFaviconData != data else { return }
        cachedFaviconData = data
        faviconSnapshotUpdater?(data)
    }
    
    /// Persists a custom title and rebinds observers so KVO no longer overwrites it.
    func applyStoredTitle(_ title: String) {
        storedTitle = title
        self.title = title
        setWebContentsWrapper(wrapper: webContentWrapper)
    }
    
    func setActive(_ active: Bool) {
        self.isActive = active
    }
    
    func setIndex(_ index: Int) {
        if index != self.index {
            self.index = index
        }
    }
    
    @objc func close() {
        if isActive, windowId != 0 {
            MainBrowserWindowControllersManager.shared
                .getBrowserState(for: windowId)?
                .prepareForActiveTabClose(tabId: guid)
            // Let Chromium handle active-tab teardown to avoid close flicker.
            ChromiumLauncher.sharedInstance().bridge?.executeCommand(
                Int32(CommandWrapper.IDC_CLOSE_TAB.rawValue),
                windowId: Int64(windowId)
            )
        } else {
            webContentWrapper?.close()
        }
    }
    
    func makeSelfActive() {
        webContentWrapper?.setAsActiveTab()
    }
    
    func goBack() {
        webContentWrapper?.goBack()
    }
    
    func goForward() {
        webContentWrapper?.goForward()
    }
    
    func reload() {
        webContentWrapper?.reload()
    }
    
    func stopLoading() {
        webContentWrapper?.stopLoading()
    }

    func setAudioMuted(_ muted: Bool) {
        webContentWrapper?.setAudioMuted(muted)
    }

    func muteAudio() {
        webContentWrapper?.muteAudio()
    }

    func unmuteAudio() {
        webContentWrapper?.unmuteAudio()
    }
    
    /// Toggles the AI Chat sidebar for this tab.
    func toggleAIChat(_ collapse: Bool? = nil) {
        if let collapse {
            aiChatCollapsed = collapse
        } else {
            aiChatCollapsed.toggle()
        }
    }
    
    /// Updates the last known focus target for this tab.
    func updateFocusTarget(_ target: FocusTarget?) {
        lastFocusTarget = target
    }
    
    func tearDown() {
        cancellables.forEach { $0.cancel() }
        cancellables.removeAll()
    }
}

extension Tab {
    enum `Type` {
        case normal, parent, sub
    }
}

extension Tab: Equatable {
    static func == (lhs: Tab, rhs: Tab) -> Bool {
        return lhs.guidInLocalDB == rhs.guidInLocalDB && lhs.guid == rhs.guid
    }
}

extension Tab: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(guid)
        hasher.combine(guidInLocalDB)
    }
}

extension Tab: CustomStringConvertible {
    var description: String { "\(Unmanaged.passUnretained(self).toOpaque()) title: \(title), url: \(url ?? ""), favicon: \(faviconUrl ?? ""), isActive: \(isActive), guid:\(guidInLocalDB ?? "") - (\(guid)"
    }
}

extension Tab {
    convenience init(with dbModel: TabDataModel) {
        self.init(guid: -1,
                  url: dbModel.url.absoluteString,
                  isActive: false,
                  index: dbModel.index,
                  title: dbModel.title,
                  webContentView: nil,
                  customGuid: dbModel.guid,
                  profileId: dbModel.profile?.profileId ?? dbModel.profileId,
                  faviconData: dbModel.favicon)
        self.isOpenned = false
        self.isPinned = (dbModel.dataType == .pinnedTab)
        self.storedTitle = dbModel.title
        if dbModel.dataType == .pinnedTab {
            self.pinnedUrl = dbModel.url.absoluteString
        }
    }
}

extension Tab {
    var isPinnedOrInDB: Bool {
        return isPinned || guidInLocalDB?.isEmpty ?? true == false
    }
}

extension Tab {
    var isNTP: Bool {
        return url?.hasPrefix("chrome://newtab") ?? false
        || url?.hasPrefix("phi://newtab") ?? false
        || url?.hasPrefix("chrome://conversation") ?? false
    }
}

extension String {
    var isNTPUrlString: Bool {
        return hasPrefix("chrome://newtab") ||
        hasPrefix("phi://newtab") ||
        hasPrefix("chrome://conversation")
    }
}
