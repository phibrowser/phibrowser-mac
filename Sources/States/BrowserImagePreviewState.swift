// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import Combine
import Foundation

@MainActor
final class BrowserImagePreviewState: ObservableObject {
    @Published private(set) var isVisible = false
    @Published private(set) var items: [ImagePreviewItem] = []
    @Published private(set) var currentIndex = 0
    @Published private(set) var loadState: ImagePreviewLoadState = .idle
    @Published private(set) var zoomScale: CGFloat = 1
    @Published private(set) var fitScale: CGFloat = 1
    @Published private(set) var minScale: CGFloat = 1
    @Published private(set) var maxScale: CGFloat = 8

    private let loader: ImagePreviewLoading
    private var activeLoadTask: Task<Void, Never>?

    var activeItem: ImagePreviewItem? {
        guard items.indices.contains(currentIndex) else { return nil }
        return items[currentIndex]
    }

    var canShowPrevious: Bool { currentIndex > 0 }
    var canShowNext: Bool { currentIndex + 1 < items.count }

    init(loader: ImagePreviewLoading) {
        self.loader = loader
    }

    func open(items: [ImagePreviewItem], currentIndex: Int) {
        activeLoadTask?.cancel()
        self.items = items
        self.currentIndex = clamp(index: currentIndex, in: items)
        isVisible = !items.isEmpty
        loadState = isVisible ? .loading : .idle
        resetZoomStateToFit()

        guard isVisible else { return }
        loadCurrentItem()
        loader.preloadAdjacentItems(around: items, currentIndex: self.currentIndex)
    }

    func close() {
        activeLoadTask?.cancel()
        activeLoadTask = nil
        loader.cancelCurrentLoad()
        items = []
        currentIndex = 0
        isVisible = false
        loadState = .idle
        resetZoomStateToFit()
    }

    func showNext() {
        guard canShowNext else { return }
        currentIndex += 1
        resetZoomStateToFit()
        loadCurrentItem()
        loader.preloadAdjacentItems(around: items, currentIndex: currentIndex)
    }

    func showPrevious() {
        guard canShowPrevious else { return }
        currentIndex -= 1
        resetZoomStateToFit()
        loadCurrentItem()
        loader.preloadAdjacentItems(around: items, currentIndex: currentIndex)
    }

    func retryCurrentItem() {
        guard activeItem != nil else { return }
        loadCurrentItem()
    }

    func append(items newItems: [ImagePreviewItem]) {
        guard !newItems.isEmpty else { return }

        guard isVisible, !items.isEmpty else {
            open(items: newItems, currentIndex: 0)
            return
        }

        items.append(contentsOf: newItems)
        loader.preloadAdjacentItems(around: items, currentIndex: currentIndex)
    }

    func updateZoom(scale: CGFloat, fitScale: CGFloat, minScale: CGFloat) {
        self.fitScale = fitScale
        self.minScale = minScale
        zoomScale = scale
    }

    private func clamp(index: Int, in items: [ImagePreviewItem]) -> Int {
        guard !items.isEmpty else { return 0 }
        return Swift.max(0, Swift.min(index, items.count - 1))
    }

    private func resetZoomStateToFit() {
        fitScale = 1
        zoomScale = 1
        minScale = 1
    }

    private func loadCurrentItem() {
        activeLoadTask?.cancel()
        guard let item = activeItem else {
            loadState = .idle
            return
        }

        loadState = .loading
        let itemID = item.id

        activeLoadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let asset = try await loader.load(item)
                guard !Task.isCancelled, self.activeItem?.id == itemID else { return }
                self.loadState = .loaded(asset)
            } catch is CancellationError {
                return
            } catch let error as ImagePreviewError {
                guard self.activeItem?.id == itemID else { return }
                self.loadState = .failed(error)
                AppLogWarn("[ImagePreview] Failed to load image \(item.source.url?.absoluteString ?? item.source.cacheKey): \(error)")
            } catch {
                guard self.activeItem?.id == itemID else { return }
                self.loadState = .failed(.decodeFailed)
                AppLogError("[ImagePreview] Unexpected load failure for \(item.source.url?.absoluteString ?? item.source.cacheKey): \(error.localizedDescription)")
            }
        }
    }
}
