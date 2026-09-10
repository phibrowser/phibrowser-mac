// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Combine
import Foundation

final class OverlayToastCenter: ObservableObject {
    static let shared = OverlayToastCenter()

    typealias TargetResolver = (OverlayToastTarget) -> Int?
    typealias Scheduler = (_ delay: TimeInterval, _ action: @escaping () -> Void) -> AnyCancellable
    typealias IDFactory = () -> UUID

    private struct WindowQueue {
        var active: [OverlayToastPlacement: OverlayToastItem] = [:]
        var queued: [OverlayToastPlacement: [OverlayToastItem]] = [:]

        var isEmpty: Bool {
            active.isEmpty && queued.values.allSatisfy(\.isEmpty)
        }
    }

    private static let defaultDuration: TimeInterval = 3

    private let targetResolver: TargetResolver
    private let scheduler: Scheduler
    private let idFactory: IDFactory

    private var queuesByWindowId: [Int: WindowQueue] = [:]
    private var dismissalsByToastId: [UUID: AnyCancellable] = [:]

    @Published private var visibleToastsByWindowId: [Int: [OverlayToastItem]] = [:]

    init(
        targetResolver: @escaping TargetResolver = OverlayToastCenter.resolveTarget,
        scheduler: @escaping Scheduler = { delay, action in
            OverlayToastCenter.scheduleOnMainQueue(delay: delay, action: action)
        },
        idFactory: @escaping IDFactory = UUID.init
    ) {
        self.targetResolver = targetResolver
        self.scheduler = scheduler
        self.idFactory = idFactory
    }

    func visibleToastsPublisher(for windowId: Int) -> AnyPublisher<[OverlayToastItem], Never> {
        performOnMainQueue {
            $visibleToastsByWindowId
                .map { $0[windowId] ?? [] }
                .removeDuplicates()
                .eraseToAnyPublisher()
        }
    }

    func visibleToasts(for windowId: Int) -> [OverlayToastItem] {
        performOnMainQueue {
            visibleToastsByWindowId[windowId] ?? []
        }
    }

    @discardableResult
    func show(
        title: String,
        message: String? = nil,
        duration: TimeInterval = OverlayToastCenter.defaultDuration,
        placement: OverlayToastPlacement = .topCenter,
        shareURLs: [URL] = [],
        in target: OverlayToastTarget = .activeWindow,
        action: OverlayToastAction? = nil,
        id: UUID? = nil
    ) -> UUID? {
        performOnMainQueue {
            showOnMainQueue(
                title: title,
                message: message,
                duration: duration,
                placement: placement,
                shareURLs: shareURLs,
                in: target,
                action: action,
                id: id
            )
        }
    }

    @discardableResult
    func show(
        title: String,
        message: String? = nil,
        duration: TimeInterval = OverlayToastCenter.defaultDuration,
        placement: OverlayToastPlacement = .topCenter,
        shareURLs: [URL] = [],
        in browserState: BrowserState
    ) -> UUID? {
        performOnMainQueue {
            showOnMainQueue(
                title: title,
                message: message,
                duration: duration,
                placement: placement,
                shareURLs: shareURLs,
                in: .windowId(browserState.windowId)
            )
        }
    }

    @discardableResult
    func dismiss(id: UUID) -> Bool {
        performOnMainQueue {
            dismissOnMainQueue(id: id)
        }
    }

    func clearWindow(windowId: Int) {
        performOnMainQueue {
            clearWindowOnMainQueue(windowId: windowId)
        }
    }

    func pauseDismissal(id: UUID) {
        performOnMainQueue {
            dismissalsByToastId[id]?.cancel()
            dismissalsByToastId[id] = nil
        }
    }

    private func showOnMainQueue(
        title: String,
        message: String?,
        duration: TimeInterval,
        placement: OverlayToastPlacement,
        shareURLs: [URL],
        in target: OverlayToastTarget,
        action: OverlayToastAction? = nil,
        id: UUID? = nil
    ) -> UUID? {
        guard let windowId = targetResolver(target) else {
            AppLogWarn("[OverlayToast] Drop toast without target window: title=\(title)")
            return nil
        }

        let toast = OverlayToastItem(
            id: id ?? idFactory(),
            title: title,
            message: message,
            duration: duration > 0 ? duration : Self.defaultDuration,
            placement: placement,
            shareURLs: shareURLs,
            action: action
        )
        enqueueOnMainQueue(toast, for: windowId)
        return toast.id
    }

    private func dismissOnMainQueue(id: UUID) -> Bool {
        for (windowId, windowQueue) in queuesByWindowId {
            if let placement = windowQueue.active.first(where: { $0.value.id == id })?.key {
                dismissalsByToastId[id]?.cancel()
                dismissalsByToastId[id] = nil

                var updatedQueue = windowQueue
                updatedQueue.active[placement] = nil
                queuesByWindowId[windowId] = updatedQueue
                presentNextToastOnMainQueue(for: windowId, placement: placement)
                return true
            }

            var updatedQueue = windowQueue
            for placement in OverlayToastPlacement.allCases {
                guard var queuedToasts = updatedQueue.queued[placement],
                      let index = queuedToasts.firstIndex(where: { $0.id == id })
                else {
                    continue
                }
                queuedToasts.remove(at: index)
                updatedQueue.queued[placement] = queuedToasts
                queuesByWindowId[windowId] = updatedQueue
                publishVisibleToastsOnMainQueue(for: windowId)
                return true
            }
        }

        return false
    }

    private func clearWindowOnMainQueue(windowId: Int) {
        guard let queue = queuesByWindowId.removeValue(forKey: windowId) else {
            setVisibleToastsOnMainQueue(nil, for: windowId)
            return
        }

        for toast in queue.active.values {
            dismissalsByToastId[toast.id]?.cancel()
            dismissalsByToastId[toast.id] = nil
        }
        setVisibleToastsOnMainQueue(nil, for: windowId)
    }

    private func enqueueOnMainQueue(_ toast: OverlayToastItem, for windowId: Int) {
        var queue = queuesByWindowId[windowId] ?? WindowQueue()

        if let activeToast = queue.active[toast.placement] {
            dismissalsByToastId[activeToast.id]?.cancel()
            dismissalsByToastId[activeToast.id] = nil
            queue.active[toast.placement] = nil
        }

        queue.queued[toast.placement] = [toast]
        queuesByWindowId[windowId] = queue
        presentNextToastOnMainQueue(for: windowId, placement: toast.placement)
    }

    private func presentNextToastOnMainQueue(for windowId: Int, placement: OverlayToastPlacement) {
        var queue = queuesByWindowId[windowId] ?? WindowQueue()
        guard queue.active[placement] == nil else {
            publishVisibleToastsOnMainQueue(for: windowId)
            return
        }
        guard var queuedToasts = queue.queued[placement], !queuedToasts.isEmpty else {
            queuesByWindowId[windowId] = queue
            publishVisibleToastsOnMainQueue(for: windowId)
            return
        }

        let nextToast = queuedToasts.removeFirst()
        queue.queued[placement] = queuedToasts
        queue.active[placement] = nextToast
        queuesByWindowId[windowId] = queue

        dismissalsByToastId[nextToast.id] = scheduler(nextToast.duration) { [weak self] in
            _ = self?.dismiss(id: nextToast.id)
        }

        publishVisibleToastsOnMainQueue(for: windowId)
    }

    private func publishVisibleToastsOnMainQueue(for windowId: Int) {
        guard let queue = queuesByWindowId[windowId] else {
            setVisibleToastsOnMainQueue(nil, for: windowId)
            return
        }

        let visibleToasts = OverlayToastPlacement.allCases.compactMap { queue.active[$0] }
        if visibleToasts.isEmpty, queue.isEmpty {
            queuesByWindowId[windowId] = nil
            setVisibleToastsOnMainQueue(nil, for: windowId)
        } else {
            setVisibleToastsOnMainQueue(visibleToasts, for: windowId)
        }
    }

    private func setVisibleToastsOnMainQueue(_ toasts: [OverlayToastItem]?, for windowId: Int) {
        var updatedVisibleToasts = visibleToastsByWindowId
        updatedVisibleToasts[windowId] = toasts
        visibleToastsByWindowId = updatedVisibleToasts
    }

    private func performOnMainQueue<T>(_ action: () -> T) -> T {
        if Thread.isMainThread {
            return action()
        }
        return DispatchQueue.main.sync(execute: action)
    }

    private static func resolveTarget(_ target: OverlayToastTarget) -> Int? {
        switch target {
        case .activeWindow:
            return MainBrowserWindowControllersManager.shared.getActiveWindowState()?.windowId
        case .windowId(let windowId):
            return windowId
        }
    }

    private static func scheduleOnMainQueue(delay: TimeInterval, action: @escaping () -> Void) -> AnyCancellable {
        let workItem = DispatchWorkItem(block: action)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        return AnyCancellable {
            workItem.cancel()
        }
    }
}

extension OverlayToastCenter {
    @discardableResult
    func showHighlightLinkCopyConfirmation(url: URL, in browserState: BrowserState) -> UUID? {
        let title = NSLocalizedString(
            "browser.highlightLink.copied",
            value: "Link copied to highlight",
            comment: "Toast shown after copying a link to highlighted text, including when a short link is unavailable")
        return show(title: title, placement: .topTrailing, shareURLs: [url], in: browserState)
    }

    @discardableResult
    func showURLCopyConfirmation(copiedURLs: [String], in browserState: BrowserState) -> UUID? {
        let title = copiedURLs.count > 1
            ? NSLocalizedString("app.copyTabURLsToast.multiple", value: "URLs Copied", comment: "Toast shown after copying selected tab URLs to the clipboard")
            : NSLocalizedString("app.copyTabURLsToast.single", value: "URL Copied", comment: "Toast shown after copying the selected tab URL to the clipboard")
        return show(title: title, placement: .topTrailing, shareURLs: copiedURLs.compactMap(URL.init(string:)), in: browserState)
    }
}
