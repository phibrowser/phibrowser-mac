// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import SwiftUI
import Combine
import AppKit

@Observable
@MainActor
final class TabViewModel {
    var title: String = ""
    var url: String?
    var faviconUrl: String?
    var liveFaviconImage: NSImage?
    private(set) var liveFaviconRevision: Int = 0
    /// The last non-nil URL used for favicon loading. Prevents globe flash
    /// when viewModel is briefly reconfigured with a nil-url tab during layout.
    private(set) var faviconLoadURL: String?
    var isActive: Bool = false
    var isPressed: Bool = false
    var isLoading: Bool = false
    var loadingProgress: Double = 1.0
    var isCurrentlyAudible: Bool = false
    var isAudioMuted: Bool = false
    var isCapturingMedia: Bool = false
    var isHorizontalCompactMode: Bool = false
    
    var onToggleMute: (() -> Void)?
    var onToolTipUpdated: (() -> Void)?
    
    private(set) var faviconRevision: Int = 0
    
    private var cancellables = Set<AnyCancellable>()

    var isShimmering: Bool {
        isLoading && loadingProgress < 0.99
    }
    
    var displayTitle: String {
        if !title.isEmpty { return title }
        if let url, !url.isEmpty { return url }
        return NSLocalizedString("New Tab", comment: "Default title for a new tab when no page title or URL is available")
    }

    func reloadFavicon() {
        faviconRevision += 1
    }

    func cancelSubscriptions() {
        cancellables.removeAll()
    }

    func configure(with tab: Tab) {
        self.title = tab.title
        self.url = tab.url
        if let newUrl = tab.url, !newUrl.isEmpty {
            self.faviconLoadURL = newUrl
        }
        self.faviconUrl = tab.faviconUrl
        updateLiveFavicon(data: tab.liveFaviconData, revision: tab.liveFaviconRevision)
        self.isActive = tab.isActive
        self.isLoading = tab.isLoading
        self.loadingProgress = Double(tab.loadingProgress)
        self.isCurrentlyAudible = tab.isCurrentlyAudible
        self.isAudioMuted = tab.isAudioMuted
        self.isCapturingMedia = tab.isCapturingAudio || tab.isCapturingVideo || tab.isSharingScreen
        
        cancellables.removeAll()
        
        tab.$title
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newTitle in
                guard let self else { return }
                self.title = newTitle
                self.onToolTipUpdated?()
            }
            .store(in: &cancellables)
            
        tab.$url
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newUrl in
                guard let self else { return }
                self.url = newUrl
                if let newUrl, !newUrl.isEmpty {
                    self.faviconLoadURL = newUrl
                }
            }
            .store(in: &cancellables)
            
        tab.$faviconUrl
            .receive(on: DispatchQueue.main)
            .sink { [weak self] rawFaviconUrl in
                guard let self else { return }
                let newFaviconUrl = (rawFaviconUrl?.isEmpty == false) ? rawFaviconUrl : nil
                let oldFaviconUrl = (self.faviconUrl?.isEmpty == false) ? self.faviconUrl : nil
                self.faviconUrl = rawFaviconUrl
                
                if let newFaviconUrl,
                    oldFaviconUrl?.isEmpty == false,
                    newFaviconUrl != oldFaviconUrl,
                   let pageURL = self.faviconLoadURL.flatMap(URL.init(string:)) {
                    Task { [weak self] in
                        await FaviconDataProvider.clearCache(for: pageURL)
                        self?.reloadFavicon()
                    }
                } else if oldFaviconUrl == nil {
                    self.reloadFavicon()
                }
            }
            .store(in: &cancellables)

        tab.$liveFaviconData
            .combineLatest(tab.$liveFaviconRevision)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] data, revision in
                self?.updateLiveFavicon(data: data, revision: revision)
            }
            .store(in: &cancellables)
            
        tab.$isActive
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.isActive = $0 }
            .store(in: &cancellables)
            
        tab.$isLoading
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.isLoading = $0 }
            .store(in: &cancellables)
            
        tab.$loadingProgress
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.loadingProgress = Double($0) }
            .store(in: &cancellables)

        tab.$isCurrentlyAudible
            .combineLatest(tab.$isAudioMuted)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isCurrentlyAudible, isAudioMuted in
                self?.isCurrentlyAudible = isCurrentlyAudible
                self?.isAudioMuted = isAudioMuted
            }
            .store(in: &cancellables)

        Publishers.CombineLatest3(tab.$isCapturingAudio, tab.$isCapturingVideo, tab.$isSharingScreen)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isCapturingAudio, isCapturingVideo, isSharingScreen in
                self?.isCapturingMedia = isCapturingAudio || isCapturingVideo || isSharingScreen
            }
            .store(in: &cancellables)
    }

    private func updateLiveFavicon(data: Data?, revision: Int) {
        liveFaviconRevision = revision

        guard let data, let image = NSImage(data: data) else {
            liveFaviconImage = nil
            return
        }

        liveFaviconImage = image
    }
}
