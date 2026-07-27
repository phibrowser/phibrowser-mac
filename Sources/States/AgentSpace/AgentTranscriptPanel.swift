// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import Combine
import SnapKit
import SwiftUI

/// Where the agent console lives on screen — the same choices DevTools
/// offers, picked from the console header's placement menu and persisted
/// across launches.
enum AgentTranscriptPlacement: String, CaseIterable, Identifiable {
    /// Docked as a right sidebar of the frontmost browser window.
    case right
    /// Docked along the bottom of the frontmost browser window.
    case bottom
    /// A regular standalone window.
    case window

    var id: String { rawValue }

    var isDocked: Bool { self == .right || self == .bottom }

    var dockEdge: AgentTranscriptDockEdge? {
        switch self {
        case .right: return .right
        case .bottom: return .bottom
        case .window: return nil
        }
    }

    var title: String {
        switch self {
        case .right:
            return NSLocalizedString("agent.transcript.placement.rightSidebar", value: "Dock to Right", comment: "Agent console placement - right sidebar")
        case .bottom:
            return NSLocalizedString("agent.transcript.placement.bottomDock", value: "Dock to Bottom", comment: "Agent console placement - bottom dock")
        case .window:
            return NSLocalizedString("agent.transcript.placement.separateWindow", value: "Separate Window", comment: "Agent console placement - standalone window")
        }
    }

    var symbol: String {
        switch self {
        case .right: return "rectangle.trailinghalf.inset.filled"
        case .bottom: return "rectangle.bottomhalf.inset.filled"
        case .window: return "macwindow"
        }
    }
}

/// Console mirroring the driving code agent's session: the live transcript
/// (actions, narration, rounds, lifecycle) plus a prompt where the user can
/// type commands back to the agent. Like DevTools it can dock to the right
/// or bottom of the browser window, or live in its own window — one console
/// instance re-homed between those placements.
///
/// Opened from View ▸ Agent Transcript, an agent pip's context menu, or
/// automatically at task start while Agent Autoview is enabled.
@MainActor
final class AgentTranscriptPanelController: NSObject {
    static let shared = AgentTranscriptPanelController()

    private static let placementDefaultsKey = "PhiAgentTranscriptPlacement"
    private static let windowAutosaveName = "AgentTranscriptWindow"

    private var window: NSWindow?
    private var dockView: AgentTranscriptDockView?
    private weak var dockHost: WebContentContainerViewController?
    /// Docked placement counts as "shown" even while its host window is
    /// briefly gone (closed, Space swap in flight) — the next browser window
    /// to become key takes the dock back in.
    private var dockActive = false
    /// Set while a placement switch or programmatic teardown closes a
    /// window, so `windowWillClose` doesn't treat the re-host as the user
    /// closing the console.
    private var isRehosting = false
    /// Space of the last slot-visible key window, so a key change can be
    /// told apart as "switched Spaces" vs "same Space refocused" — only a
    /// real switch may steal the feed filter.
    private var lastKeySpaceId: String?

    private let model = AgentTranscriptPanelModel()
    /// One hosting view shared by every placement — moving it between hosts
    /// keeps the feed scroll position and a half-typed prompt across
    /// re-docks.
    private var hostingView: NSHostingView<AgentTranscriptPanelView>?

    private(set) var placement: AgentTranscriptPlacement {
        didSet { model.placement = placement }
    }

    override private init() {
        placement = UserDefaults.standard.string(forKey: Self.placementDefaultsKey)
            .flatMap(AgentTranscriptPlacement.init(rawValue:)) ?? .right
        super.init()
        model.placement = placement
        // A docked console follows the frontmost browser window: a Space
        // switch swaps NSWindows behind one visual "window", so the dock
        // must re-host to keep that illusion intact.
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleWindowDidBecomeKey(_:)),
            name: NSWindow.didBecomeKeyNotification, object: nil)
        // …and must ALSO follow programmatic switches. When the code agent
        // surfaces its Space (autoview, handoff) the user is typically in the
        // terminal, so Phi is inactive and the ordered-front window can NOT
        // become key — no didBecomeKey ever fires, and the dock would stay
        // stranded in the now-hidden window until the user's next click. The
        // slot posts this on every visible-window repoint.
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleVisibleWindowChanged(_:)),
            name: .spaceSlotVisibleWindowDidChange, object: nil)
    }

    var isVisible: Bool {
        window?.isVisible == true || (dockActive && dockView?.window != nil)
    }

    func toggle() {
        if isVisible {
            dismiss()
        } else {
            show()
        }
    }

    /// Surfaces the console. `focusTaskId` preselects that task in the feed
    /// filter (the pip context menu passes it). Without one, opening inside
    /// an agent Space focuses that Space's own task; elsewhere the current
    /// filter stays — "all tasks" by default.
    func show(focusTaskId: String? = nil) {
        if let focusTaskId {
            model.taskFilter = focusTaskId
        } else if let taskId = activeSpaceTaskId() {
            model.taskFilter = taskId
        }
        healStaleFilter()
        present()
    }

    /// The live task bound to the Space the user is currently looking at,
    /// or nil when that Space isn't an agent Space.
    private func activeSpaceTaskId() -> String? {
        guard let spaceId = SpaceManager.shared.activeSpaceId else { return nil }
        return AgentSpaceManager.shared.tasksBySpaceId[spaceId]?.taskId
    }

    /// Moves the console to a new home, keeping it up if it was up.
    func setPlacement(_ new: AgentTranscriptPlacement) {
        guard new != placement else { return }
        let wasVisible = isVisible || dockActive
        tearDownPresentation()
        placement = new
        UserDefaults.standard.set(new.rawValue, forKey: Self.placementDefaultsKey)
        if wasVisible { present() }
    }

    func dismiss() {
        tearDownPresentation()
        reapEndedBuffers()
    }

    // MARK: - Presentation

    private func present() {
        switch placement {
        case .window: presentWindow()
        case .right, .bottom: presentDock()
        }
    }

    private func sharedHostingView() -> NSHostingView<AgentTranscriptPanelView> {
        if let hostingView { return hostingView }
        let view = NSHostingView(rootView: AgentTranscriptPanelView(model: model))
        // The browser window is full-size-content, so its title-bar safe area
        // reaches into the docked console's frame and NSHostingView would pad
        // the layout down by it — a blank strip above the header. The console
        // draws its own chrome; opt out of safe-area handling entirely.
        // (`safeAreaRegions` is macOS 13.3+; older systems keep the padding.)
        if #available(macOS 13.3, *) {
        view.safeAreaRegions = []
        }
        hostingView = view
        return view
    }

    private func presentWindow() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = NSLocalizedString("agent.transcript.windowTitle", value: "Agent Transcript", comment: "Agent console panel - window title")
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 320, height: 300)
        window.contentView = sharedHostingView()
        window.delegate = self
        if !window.setFrameUsingName(Self.windowAutosaveName) {
            window.center()
        }
        window.setFrameAutosaveName(Self.windowAutosaveName)
        // orderFrontRegardless too: an auto-view show can land while Phi is
        // in the background, where makeKeyAndOrderFront alone leaves the
        // console behind the browser window.
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        self.window = window
    }

    private func presentDock() {
        guard let edge = placement.dockEdge else { return }
        if dockActive, let dockView, dockView.window != nil, dockView.edge == edge { return }
        guard let container = frontmostContainer() else { return }
        let dock = AgentTranscriptDockView(edge: edge, content: sharedHostingView())
        dockHost?.detachTranscriptDock()
        container.attachTranscriptDock(dock, edge: edge)
        dockView = dock
        dockHost = container
        dockActive = true
    }

    private func tearDownPresentation() {
        isRehosting = true
        defer { isRehosting = false }
        if let window {
            window.contentView = NSView()
            window.close()
            self.window = nil
        }
        if dockActive || dockView != nil {
            hostingView?.removeFromSuperview()
            dockHost?.detachTranscriptDock()
            dockHost = nil
            dockView = nil
            dockActive = false
        }
    }

    /// The container of the browser window a dock should live in right now.
    /// Slot `visibleController`s only — NSApp.keyWindow can be the hidden
    /// agent-Space window during task start (Chromium keys it briefly before
    /// the slot pushes it back out), and a dock installed there is invisible.
    private func frontmostContainer() -> WebContentContainerViewController? {
        let controller = SpaceManager.shared.keySlot?.visibleController
            ?? SpaceManager.shared.slots.first?.visibleController
        return controller?.mainSplitViewController.webContentContainerViewController
    }

    /// Reacts to a different browser window coming to the front — a Space
    /// switch swapping windows, or the user moving between two real windows.
    /// The work runs one runloop turn later against SpaceManager state: this
    /// observer can fire BEFORE the slot's own didBecomeKey observer (added
    /// later) has repointed `visibleController`, and acting on the stale
    /// value strands the dock in the window that just went off screen.
    @objc private nonisolated func handleWindowDidBecomeKey(_ notification: Notification) {
        MainActor.assumeIsolated {
            guard (notification.object as? NSWindow)?.windowController
                    is MainBrowserWindowController else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    AgentTranscriptPanelController.shared.reconcileFrontWindow()
                }
            }
        }
    }

    /// A slot repointed its visible window (see the init observer). Same
    /// one-turn deferral as the key-window path so the swap's attach-side
    /// state has settled before the dock re-homes.
    @objc private nonisolated func handleVisibleWindowChanged(_ notification: Notification) {
        MainActor.assumeIsolated {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    AgentTranscriptPanelController.shared.reconcileFrontWindow()
                }
            }
        }
    }

    /// Aligns the console with the browser window the user is now looking
    /// at: switching INTO an agent Space pulls the feed filter onto the task
    /// that Space is bound to, and an active dock re-homes into the front
    /// window (a Space switch swaps NSWindows behind one visual "window").
    private func reconcileFrontWindow() {
        guard let controller = SpaceManager.shared.keySlot?.visibleController
            ?? SpaceManager.shared.slots.first?.visibleController else { return }

        // Filter refocus only on a real Space change — a re-focus of the
        // same Space must not undo a filter the user picked by hand.
        let spaceChanged = controller.spaceId != lastKeySpaceId
        lastKeySpaceId = controller.spaceId
        if spaceChanged, isVisible,
           let task = AgentSpaceManager.shared.tasksBySpaceId[controller.spaceId] {
            model.taskFilter = task.taskId
        }

        guard dockActive, let edge = placement.dockEdge else { return }
        let container = controller.mainSplitViewController.webContentContainerViewController
        guard container !== dockHost, let dock = dockView else { return }
        dockHost?.detachTranscriptDock()
        container.attachTranscriptDock(dock, edge: edge)
        dockHost = container
    }

    /// Reaps buffers of tasks that already ended — the open console was the
    /// only reason they were retained.
    private func reapEndedBuffers() {
        let live = Set(AgentSpaceManager.shared.tasksBySpaceId.values.map(\.taskId))
        AgentTranscriptStore.shared.clearAll(except: live)
    }

    /// A new task started while the console is up: steal the filter from a
    /// task that is no longer live so the feed keeps showing something real —
    /// never from a live one the user chose to watch. Without this, a filter
    /// left on an ended task blanks the feed while the new task streams
    /// unseen behind it.
    func refocusIfStale(onto taskId: String) {
        guard isVisible, let filter = model.taskFilter, filter != taskId else { return }
        let live = AgentSpaceManager.shared.tasksBySpaceId.values
            .contains { $0.taskId == filter }
        if !live { model.taskFilter = taskId }
    }

    /// Drops a filter pointing at a task with neither a live record nor a
    /// buffer (e.g. reopened after its buffers were reaped) — the all-tasks
    /// feed is always better than a permanently empty one.
    private func healStaleFilter() {
        guard let filter = model.taskFilter else { return }
        let live = AgentSpaceManager.shared.tasksBySpaceId.values
            .contains { $0.taskId == filter }
        let buffered = AgentTranscriptStore.shared.entriesByTaskId[filter] != nil
        if !live && !buffered { model.taskFilter = nil }
    }
}

extension AgentTranscriptPanelController: NSWindowDelegate {
    /// The user closed the console via the title-bar button: drop the
    /// window and reap ended tasks' buffers. Placement switches close the
    /// same windows programmatically but flag `isRehosting` first.
    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            guard !isRehosting else { return }
            if let closing = notification.object as? NSWindow, closing === window {
                window = nil
            }
            reapEndedBuffers()
        }
    }
}

/// View state that outlives panel open/close: the feed's task filter.
@MainActor
final class AgentTranscriptPanelModel: ObservableObject {
    /// nil = all tasks interleaved; else only this taskId's lines.
    @Published var taskFilter: String?
    /// Mirrors the controller's placement for the header's placement menu.
    @Published var placement: AgentTranscriptPlacement = .right
}

// MARK: - Dock chrome

/// Which browser-window edge a docked console occupies.
enum AgentTranscriptDockEdge {
    case right
    case bottom

    var sizeDefaultsKey: String {
        switch self {
        case .right: return "PhiAgentTranscriptDockWidth"
        case .bottom: return "PhiAgentTranscriptDockHeight"
        }
    }
}

/// Chrome for a docked console: the console wrapped in the same rounded
/// panel geometry as the page area, plus an invisible drag divider on the
/// content-facing edge for resizing. Installed into a browser window by
/// `WebContentContainerViewController.attachTranscriptDock`.
final class AgentTranscriptDockView: NSView {
    let edge: AgentTranscriptDockEdge

    private static let defaultWidth: CGFloat = 360
    private static let defaultHeight: CGFloat = 220
    private static let minWidth: CGFloat = 280
    private static let minHeight: CGFloat = 150
    /// Room a resize must always leave for the page content.
    private static let contentReserve: CGFloat = 400

    private var sizeConstraint: NSLayoutConstraint!
    /// Bottom dock only: the wrapper's leading inset, kept in sync with the
    /// page panel's leading inset so both panels share one left edge. See
    /// `updateLeadingInset`.
    private var wrapperLeadingConstraint: Constraint?

    init(edge: AgentTranscriptDockEdge, content: NSView) {
        self.edge = edge
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        // Same panel treatment as the page area (rounded corners, inset from
        // the window edge) so the console reads as a sibling panel. The page
        // side needs no inset here — the page panel's own 8pt edge inset
        // provides the gap between the two panels.
        let wrapper = NSView()
        wrapper.wantsLayer = true
        wrapper.layer?.cornerCurve = .continuous
        wrapper.layer?.cornerRadius = LiquidGlassCompatible.webContentContainerCornerRadius
        wrapper.layer?.masksToBounds = true
        addSubview(wrapper)
        wrapper.snp.makeConstraints { make in
            make.top.equalToSuperview()
            switch edge {
            case .right:
                make.leading.equalToSuperview()
                make.trailing.bottom.equalToSuperview().inset(WebContentConstant.edgesSpacing)
            case .bottom:
                wrapperLeadingConstraint = make.leading.equalToSuperview()
                    .inset(WebContentConstant.edgesSpacing).constraint
                make.trailing.bottom.equalToSuperview()
                    .inset(WebContentConstant.edgesSpacing)
            }
        }

        content.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(content)
        content.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        let divider = DividerView(edge: edge)
        divider.currentSize = { [weak self] in self?.sizeConstraint.constant ?? 0 }
        divider.onDrag = { [weak self] proposed in
            guard let self else { return }
            self.sizeConstraint.constant = self.clamped(proposed)
        }
        divider.onDragEnded = { [weak self] in
            guard let self else { return }
            UserDefaults.standard.set(Double(self.sizeConstraint.constant),
                                      forKey: self.edge.sizeDefaultsKey)
        }
        addSubview(divider)
        divider.snp.makeConstraints { make in
            switch edge {
            case .right:
                make.leading.top.bottom.equalToSuperview()
                make.width.equalTo(6)
            case .bottom:
                make.top.leading.trailing.equalToSuperview()
                make.height.equalTo(6)
            }
        }

        let stored = CGFloat(UserDefaults.standard.double(forKey: edge.sizeDefaultsKey))
        let initial = stored > 0 ? stored
            : (edge == .right ? Self.defaultWidth : Self.defaultHeight)
        sizeConstraint = edge == .right
            ? widthAnchor.constraint(equalToConstant: initial)
            : heightAnchor.constraint(equalToConstant: initial)
        // Below-required so an extreme window shrink compresses the dock
        // instead of raising an unsatisfiable-constraints exception.
        sizeConstraint.priority = NSLayoutConstraint.Priority(999)
        sizeConstraint.isActive = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Aligns a bottom dock's left edge with the page panel, whose leading
    /// inset varies with layout mode and sidebar state. Driven by
    /// `WebContentContainerViewController`, the only layer that knows that
    /// inset. No-op for a right dock (its leading edge faces the page).
    func updateLeadingInset(_ inset: CGFloat) {
        wrapperLeadingConstraint?.update(inset: inset)
    }

    private func clamped(_ proposed: CGFloat) -> CGFloat {
        let minSize = edge == .right ? Self.minWidth : Self.minHeight
        var maxSize = CGFloat.greatestFiniteMagnitude
        if let superview {
            maxSize = (edge == .right ? superview.bounds.width : superview.bounds.height)
                - Self.contentReserve
        }
        return min(max(proposed, minSize), max(minSize, maxSize))
    }

    /// The drag strip along the dock's content-facing edge.
    private final class DividerView: NSView {
        let edge: AgentTranscriptDockEdge
        var onDrag: ((CGFloat) -> Void)?
        var onDragEnded: (() -> Void)?
        var currentSize: (() -> CGFloat)?
        private var dragOrigin: NSPoint = .zero
        private var originalSize: CGFloat = 0

        init(edge: AgentTranscriptDockEdge) {
            self.edge = edge
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: edge == .right ? .resizeLeftRight : .resizeUpDown)
        }

        override func mouseDown(with event: NSEvent) {
            dragOrigin = event.locationInWindow
            originalSize = currentSize?() ?? 0
        }

        override func mouseDragged(with event: NSEvent) {
            let location = event.locationInWindow
            // Right dock widens as the divider moves left; bottom dock grows
            // as it moves up (window coordinates are y-up).
            let delta = edge == .right
                ? dragOrigin.x - location.x
                : location.y - dragOrigin.y
            onDrag?(originalSize + delta)
        }

        override func mouseUp(with event: NSEvent) {
            onDragEnded?()
        }
    }
}

// MARK: - Selectable transcript feed

/// The feed's renderer: a read-only NSTextView holding the transcript as one
/// attributed document, so text selection is the native kind — a drag can
/// cross every line, ⌘A/⌘C work, and selection survives appends. SwiftUI's
/// `.textSelection` cannot select across separate Text views, which is why
/// the feed is not a stack of row views.
private struct TranscriptTextFeed: NSViewRepresentable {
    let entries: [AgentTranscriptEntry]
    let showTaskTags: Bool
    /// Builds the attributed document (see
    /// `AgentTranscriptPanelView.attributedTranscript`). Called only when
    /// `entries`/`showTaskTags` actually changed — unrelated view updates
    /// (prompt keystrokes, activity ticks) skip the rebuild.
    let build: () -> NSAttributedString

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        if let textView = scroll.documentView as? NSTextView {
            textView.isEditable = false
            textView.isSelectable = true
            textView.drawsBackground = false
            textView.textContainerInset = NSSize(width: 8, height: 12)
            textView.textContainer?.widthTracksTextView = true
            textView.delegate = context.coordinator
            textView.linkTextAttributes = [
                .foregroundColor: NSColor.linkColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .cursor: NSCursor.pointingHand,
            ]
            context.coordinator.textView = textView
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        guard let textView = coordinator.textView else { return }
        guard entries != coordinator.renderedEntries
                || showTaskTags != coordinator.renderedTags else { return }
        coordinator.renderedEntries = entries
        coordinator.renderedTags = showTaskTags

        // Stick to the tail on appends — unless the user scrolled up to
        // read, in which case new lines must not yank the view.
        let wasAtBottom = coordinator.isAtBottom(scroll)
        let selections = textView.selectedRanges
        let document = build()
        textView.textStorage?.setAttributedString(document)

        // Restore a still-valid selection; the transcript is append-mostly,
        // so an in-progress selection keeps its place across new lines.
        let length = document.length
        let clamped = selections.compactMap { value -> NSValue? in
            let range = value.rangeValue
            guard range.location != NSNotFound, range.location <= length else { return nil }
            return NSValue(range: NSRange(
                location: range.location,
                length: min(range.length, length - range.location)))
        }
        if !clamped.isEmpty { textView.selectedRanges = clamped }

        if wasAtBottom || coordinator.firstRender {
            textView.scrollToEndOfDocument(nil)
        }
        coordinator.firstRender = false
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        weak var textView: NSTextView?
        var renderedEntries: [AgentTranscriptEntry] = []
        var renderedTags = false
        var firstRender = true

        func isAtBottom(_ scroll: NSScrollView) -> Bool {
            guard let document = scroll.documentView else { return true }
            return scroll.contentView.documentVisibleRect.maxY >= document.frame.height - 40
        }

        /// A transcript link opens as a tab in Phi itself — the default
        /// NSTextView behavior would bounce it out to the OS default browser.
        func textView(_ textView: NSTextView, clickedOnLink link: Any,
                      at charIndex: Int) -> Bool {
            let url: URL?
            if let u = link as? URL {
                url = u
            } else if let s = link as? String {
                url = URL(string: s)
            } else {
                url = nil
            }
            guard let url else { return false }
            MainBrowserWindowControllersManager.shared.activeWindowController?
                .browserState.openTab(url.absoluteString)
            return true
        }
    }
}

// MARK: - Console view

/// The console: terminal-styled transcript feed + command prompt. The
/// palette follows the system (and per-window) light/dark appearance — a
/// paper-light console in light mode, the terminal-dark one in dark mode.
struct AgentTranscriptPanelView: View {
    @ObservedObject var model: AgentTranscriptPanelModel
    @ObservedObject private var store = AgentTranscriptStore.shared
    @ObservedObject private var manager = AgentSpaceManager.shared

    @State private var draft = ""
    /// Brief checkmark feedback after Copy Transcript lands on the pasteboard.
    @State private var justCopiedTranscript = false
    @FocusState private var promptFocused: Bool

    private enum Palette {
        static let background = adaptive(
            light: NSColor(red: 0.965, green: 0.965, blue: 0.975, alpha: 1),
            dark: NSColor(red: 0.075, green: 0.08, blue: 0.10, alpha: 1))
        static let chrome = adaptive(
            light: NSColor(red: 0.915, green: 0.92, blue: 0.935, alpha: 1),
            dark: NSColor(red: 0.12, green: 0.125, blue: 0.155, alpha: 1))
        // The transcript body renders through an NSTextView (see
        // TranscriptTextFeed), so its colors are sourced as dynamic NSColors
        // with the SwiftUI Color derived — one value, both worlds.
        static let textNS = adaptiveNS(
            light: NSColor.black.withAlphaComponent(0.85),
            dark: NSColor.white.withAlphaComponent(0.92))
        static let text = Color(nsColor: textNS)
        static let dimNS = adaptiveNS(
            light: NSColor.black.withAlphaComponent(0.55),
            dark: NSColor.white.withAlphaComponent(0.55))
        static let dim = Color(nsColor: dimNS)
        static let faintNS = adaptiveNS(
            light: NSColor.black.withAlphaComponent(0.32),
            dark: NSColor.white.withAlphaComponent(0.35))
        static let faint = Color(nsColor: faintNS)
        static let promptNS = adaptiveNS(
            light: NSColor(red: 0.05, green: 0.5, blue: 0.24, alpha: 1),
            dark: NSColor(red: 0.42, green: 0.85, blue: 0.55, alpha: 1))
        static let prompt = Color(nsColor: promptNS)
        static let errorNS = adaptiveNS(
            light: NSColor(red: 0.8, green: 0.22, blue: 0.17, alpha: 1),
            dark: NSColor(red: 1.0, green: 0.48, blue: 0.42, alpha: 1))
        static let error = Color(nsColor: errorNS)
        // Claude Code's brand rust, used only by the mirrored Claude Code
        // status line (spinner + verb).
        static let claudeAccent = adaptive(
            light: NSColor(red: 0.78, green: 0.40, blue: 0.27, alpha: 1),
            dark: NSColor(red: 0.855, green: 0.467, blue: 0.337, alpha: 1))
        // Pi's built-in light/dark theme surfaces. Keep them separate from
        // Phi's console chrome: they are used only by mirrored Pi rows.
        static let piUserBackgroundNS = adaptiveNS(
            light: NSColor(red: 0.91, green: 0.91, blue: 0.91, alpha: 1),
            dark: NSColor(red: 0.204, green: 0.208, blue: 0.255, alpha: 1))
        static let piToolPendingBackgroundNS = adaptiveNS(
            light: NSColor(red: 0.91, green: 0.91, blue: 0.94, alpha: 1),
            dark: NSColor(red: 0.157, green: 0.157, blue: 0.196, alpha: 1))
        static let piToolSuccessBackgroundNS = adaptiveNS(
            light: NSColor(red: 0.91, green: 0.94, blue: 0.91, alpha: 1),
            dark: NSColor(red: 0.157, green: 0.196, blue: 0.157, alpha: 1))
        static let piToolErrorBackgroundNS = adaptiveNS(
            light: NSColor(red: 0.94, green: 0.91, blue: 0.91, alpha: 1),
            dark: NSColor(red: 0.235, green: 0.157, blue: 0.157, alpha: 1))
        static let piDiffAdditionNS = adaptiveNS(
            light: NSColor(red: 0.345, green: 0.518, blue: 0.345, alpha: 1),
            dark: NSColor(red: 0.71, green: 0.74, blue: 0.41, alpha: 1))
        static let piDiffDeletionNS = adaptiveNS(
            light: NSColor(red: 0.667, green: 0.333, blue: 0.333, alpha: 1),
            dark: NSColor(red: 0.8, green: 0.4, blue: 0.4, alpha: 1))
        /// Transcript content is monospaced; the chrome around it (header,
        /// status pill, hints) uses the UI font so controls read as controls,
        /// not as more console output.
        static let font = Font.system(size: 11.5, design: .monospaced)
        static let fontSmall = Font.system(size: 10, design: .monospaced)
        static let fontUI = Font.system(size: 11)
        static let fontUISmall = Font.system(size: 10)
        // NSFont twins for the attributed transcript document.
        static let nsFont = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
        static let nsFontBold = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .bold)
        static let nsFontSemibold = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .semibold)
        static let nsFontSmall = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        static let nsFontSmallBold = NSFont.monospacedSystemFont(ofSize: 10, weight: .bold)
        static let nsFontHeading = NSFont.monospacedSystemFont(ofSize: 13, weight: .bold)
        static let nsFontSubheading = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .bold)

        /// Appearance-tracking color (`ThemedColor.dynamicColor`) so the
        /// console re-renders when the system or window theme flips.
        private static func adaptive(light: NSColor, dark: NSColor) -> Color {
            Color(nsColor: adaptiveNS(light: light, dark: dark))
        }

        private static func adaptiveNS(light: NSColor, dark: NSColor) -> NSColor {
            ThemedColor(light: light, dark: dark).dynamicColor()
        }
    }

    /// Live tasks by taskId, for R-tags, the filter menu, and prompt targeting.
    private var liveTasks: [String: AgentTask] {
        Dictionary(uniqueKeysWithValues:
            manager.tasksBySpaceId.values.map { ($0.taskId, $0) })
    }

    /// Merged feed, filtered then ordered by authored time (append sequence
    /// breaks ties) — so mirrored prose backfilled after the heredoc it
    /// describes still lands in its true chronological place.
    private var entries: [AgentTranscriptEntry] {
        let buffers: [[AgentTranscriptEntry]]
        if let filter = model.taskFilter {
            buffers = [store.entriesByTaskId[filter] ?? []]
        } else {
            buffers = Array(store.entriesByTaskId.values)
        }
        return buffers.flatMap { $0 }.sorted {
            $0.timestamp == $1.timestamp ? $0.seq < $1.seq : $0.timestamp < $1.timestamp
        }
    }

    /// Where a typed command goes: the filtered task if it is live, else the
    /// lowest-numbered live task (the pip order the user already knows).
    private var promptTarget: AgentTask? {
        if let filter = model.taskFilter, let task = liveTasks[filter] {
            return task
        }
        return liveTasks.values.min(by: { $0.number < $1.number })
    }

    private var showTaskTags: Bool { liveTasks.count > 1 && model.taskFilter == nil }

    /// Tasks with a mirrored turn edge — Codex's working/waiting row or
    /// Claude Code's spinner/summary status line. Other agents keep their
    /// existing transcript UI; browser-run state is deliberately not used as
    /// fallback.
    private var activityTasks: [AgentTask] {
        let tasks: [AgentTask]
        if let filter = model.taskFilter {
            tasks = liveTasks[filter].map { [$0] } ?? []
        } else {
            tasks = Array(liveTasks.values)
        }
        return tasks.filter { codexActivity(for: $0) != nil || claudeActivity(for: $0) != nil }
            .sorted { $0.number < $1.number }
    }

    private func codexActivity(for task: AgentTask) -> CodexTranscriptActivity? {
        store.codexActivityByTaskId[task.taskId]
    }

    private func claudeActivity(for task: AgentTask) -> ClaudeTranscriptActivity? {
        guard let state = store.claudeActivityByTaskId[task.taskId] else { return nil }
        // A sub-second idle turn with nothing still running has no story to
        // tell — Claude Code's terminal shows no resting line for the tiny
        // turns its harness records around slash commands and notifications.
        if state.phase == .idle, state.shellsRunning == 0,
           (state.durationMs ?? 0) < 1000 { return nil }
        return state
    }

    private var activitySignature: String {
        activityTasks.compactMap { task -> String? in
            if let state = claudeActivity(for: task) {
                return "\(task.taskId):claude:\(state.phase.rawValue)"
                    + ":\(state.startTimestampMs ?? 0):\(state.durationMs ?? 0)"
                    + ":\(state.shellsRunning)"
            }
            guard let state = codexActivity(for: task) else { return nil }
            return "\(task.taskId):\(state.rawValue)"
        }.joined(separator: "|")
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Palette.faint.opacity(0.4))
            feed
            Divider().overlay(Palette.faint.opacity(0.4))
            promptRow
        }
        .background(Palette.background)
    }

    private var header: some View {
        HStack(spacing: 8) {
            // The title is the one element allowed to give way: it truncates
            // (no .fixedSize) so the fixed-size pill and buttons after it can
            // never be squeezed into wrapping.
            Menu {
                Button {
                    model.taskFilter = nil
                } label: {
                    Label(NSLocalizedString("agent.transcript.feedFilter.allTasksMenuOption", value: "All tasks", comment: "Agent transcript - Menu option that shows every task"),
                          systemImage: "list.bullet")
                }
                ForEach(filterChoices, id: \.taskId) { choice in
                    Button {
                        model.taskFilter = choice.taskId
                    } label: {
                        Label { Text(choice.label) } icon: { badgeIcon(for: choice.taskId) }
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    if let filter = model.taskFilter {
                        badgeIcon(for: filter)
                    } else {
                        Image(systemName: "list.bullet")
                    }
                    Text(filterLabel)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Palette.faint)
                }
                .font(Palette.fontUI.weight(.medium))
                .foregroundStyle(Palette.dim)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)

            Spacer(minLength: 8)

            statusPill

            // One-click whole-feed copy, serialized in the console's own
            // notation. Partial ranges copy natively: the feed is a real
            // text view, so drag-select plus ⌘C works anywhere in it.
            Button {
                copyTranscript()
            } label: {
                headerIcon(justCopiedTranscript ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.plain)
            .disabled(entries.isEmpty)
            .help(NSLocalizedString("agent.transcript.copyButtonTooltip", value: "Copy transcript", comment: "Agent console - copy the visible feed as text"))

            Button {
                if let filter = model.taskFilter {
                    AgentTranscriptStore.shared.clearEntries(taskId: filter)
                } else {
                    AgentTranscriptStore.shared.clearAllEntries()
                }
            } label: {
                headerIcon("trash")
            }
            .buttonStyle(.plain)
            .help(NSLocalizedString("agent.transcript.clearButtonTooltip", value: "Clear", comment: "Agent console - clear the feed"))

            // DevTools-style placement switcher: dock right/bottom, float,
            // or break out into a separate window.
            Menu {
                Picker("", selection: placementBinding) {
                    ForEach(AgentTranscriptPlacement.allCases) { choice in
                        Label(choice.title, systemImage: choice.symbol).tag(choice)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                headerIcon(model.placement.symbol)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()

            // Docked chrome has no title bar, so it carries its own close.
            if model.placement.isDocked {
                Button {
                    AgentTranscriptPanelController.shared.dismiss()
                } label: {
                    headerIcon("xmark")
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        // Fixed bar height instead of vertical padding: the borderless-button
        // Menu reports a tall ideal height in some states, and padding around
        // it lets the whole bar balloon — the clamp keeps the title row to
        // exactly one line no matter what the controls ask for.
        .frame(height: 32)
        .background(Palette.chrome)
    }

    private func headerIcon(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(Palette.dim)
            .frame(width: 20, height: 20)
            .contentShape(Rectangle())
    }

    /// Compact live/running indicator: a status dot plus the running count,
    /// fixed-size so it can never wrap; the full "N live · N running" phrase
    /// lives in its tooltip.
    @ViewBuilder
    private var statusPill: some View {
        if !liveTasks.isEmpty {
            HStack(spacing: 5) {
                Circle()
                    .fill(runningCount > 0 ? Palette.prompt : Palette.faint)
                    .frame(width: 6, height: 6)
                Text(statusPillLabel)
                    .font(Palette.fontUISmall)
                    .foregroundStyle(Palette.dim)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(Palette.faint.opacity(0.12), in: Capsule())
            .fixedSize()
            .help(runningSummary)
        }
    }

    private var statusPillLabel: String {
        guard runningCount > 0 else {
            return NSLocalizedString("agent.transcript.status.idle", value: "idle", comment: "Agent console - status pill when no task is actively running")
        }
        return String(
            format: NSLocalizedString("agent.transcript.status.runningTaskCount", value: "%d running",
                comment: "Agent console - status pill with the actively running task count"),
            runningCount)
    }

    private var placementBinding: Binding<AgentTranscriptPlacement> {
        Binding(get: { model.placement },
                set: { AgentTranscriptPanelController.shared.setPlacement($0) })
    }

    private struct FilterChoice {
        let taskId: String
        let label: String
    }

    /// One choice per buffered task, labeled by its pip ordinal while live
    /// ("R1 · research-x") and marked ended once its record is gone (its
    /// buffer survives while the panel stays open).
    private var filterChoices: [FilterChoice] {
        store.entriesByTaskId.keys.sorted().map { taskId in
            FilterChoice(taskId: taskId, label: taskLabel(taskId))
        }
    }

    private var filterLabel: String {
        guard let filter = model.taskFilter else {
            return NSLocalizedString("agent.transcript.feedFilter.allTasksLabel", value: "All tasks", comment: "Agent transcript - Current filter label when every task is shown")
        }
        return taskLabel(filter)
    }

    private func taskLabel(_ taskId: String) -> String {
        if let task = liveTasks[taskId] {
            return "\(AgentSpaceManager.agentSpaceName(task.number)) · \(taskId)"
        }
        return taskId + NSLocalizedString("agent.transcript.taskFilter.finishedSuffix", value: " · ended", comment: "Agent console - filter label suffix for a finished task")
    }

    /// The driving-agent badge for a task. Ended tasks (no live record) keep
    /// only their buffer, not their identity, so they fall back to the generic
    /// code-agent glyph.
    private func badge(for taskId: String) -> AgentDriverBadge {
        if let task = liveTasks[taskId] {
            return AgentDriverBadge.make(agentName: task.agentName, origin: task.origin)
        }
        return AgentDriverBadge.make(agentName: "", origin: .cdp)
    }

    /// The driving agent's icon — a bundled brand imageset (template) when the
    /// agent is recognized, else the SF Symbol fallback.
    @ViewBuilder
    private func badgeIcon(for taskId: String) -> some View {
        let b = badge(for: taskId)
        if let asset = b.assetName {
            // Widened for the asset's internal padding (see `assetInkRatio`)
            // so the visible glyph matches a 12pt symbol.
            Image(asset).renderingMode(.template).resizable().scaledToFit()
                .frame(width: 12 / AgentDriverBadge.assetInkRatio,
                       height: 12 / AgentDriverBadge.assetInkRatio)
        } else {
            Image(systemName: b.symbol)
        }
    }

    private var runningCount: Int {
        manager.tasksBySpaceId.values.filter { $0.status == .running }.count
    }

    private var runningSummary: String {
        guard !liveTasks.isEmpty else {
            return NSLocalizedString("agent.transcript.footer.noActiveTasks", value: "no active tasks", comment: "Agent console - footer with no live agent task")
        }
        return String(
            format: NSLocalizedString("agent.transcript.footer.liveAndRunningCount", value: "%d live · %d running",
                comment: "Agent console - live vs actively running agent task counts"),
            liveTasks.count, runningCount)
    }

    /// Puts the visible feed on the pasteboard as plain text. SwiftUI's
    /// per-row `.textSelection` cannot select across rows, so this is the
    /// console's way to copy more than one line at a time.
    private func copyTranscript() {
        let text = transcriptText()
        guard !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        justCopiedTranscript = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            justCopiedTranscript = false
        }
    }

    /// The visible feed serialized in the console's own notation — one row
    /// per entry with its glyph, hanging detail lines under their ⎿ elbow —
    /// so the clipboard reads like the panel looks.
    private func transcriptText() -> String {
        entries.map { entry in
            var line = ""
            if showTaskTags {
                line += "[\(AgentSpaceManager.agentSpaceName(entry.taskNumber))] "
            }
            line += serializedRow(entry)
            if let detail = entry.detail, !detail.isEmpty {
                let detailLines = detail.split(
                    separator: "\n", omittingEmptySubsequences: false)
                for (index, raw) in detailLines.enumerated() {
                    line += index == 0 ? "\n  ⎿ \(raw)" : "\n    \(raw)"
                }
            }
            return line
        }.joined(separator: "\n")
    }

    private func serializedRow(_ entry: AgentTranscriptEntry) -> String {
        switch entry.kind {
        case .user: return "> \(entry.text)"
        case .assistant, .narration:
            return Flavor(entry.agent) == .claude ? "⏺ \(entry.text)" : entry.text
        case .thinking: return "✻ \(entry.text)"
        case .tool: return "\(Flavor(entry.agent) == .codex ? "•" : "⏺") \(entry.text)"
        case .action: return "⏺ \(entry.text)"
        case .error: return "✗ \(entry.text)"
        case .status: return entry.text
        case .round: return "── \(entry.text) ──"
        }
    }

    // MARK: - Attributed transcript document

    /// The whole feed as one attributed string — the NSTextView twin of the
    /// per-row SwiftUI styling, keeping its visual language: per-agent glyphs
    /// and colors, dim `⎿` details, italic thinking, Pi card tints, and
    /// markdown structure (headings, bullets, code, inline emphasis).
    private func attributedTranscript() -> NSAttributedString {
        let out = NSMutableAttributedString()
        for (index, entry) in entries.enumerated() {
            if index > 0 { out.append(atr("\n", font: Palette.nsFont, color: Palette.textNS)) }
            out.append(attributedRow(entry))
        }
        linkifyBareURLs(out)
        return out
    }

    /// Makes pasted-style URLs clickable wherever they appear in the feed
    /// (narration, tool lines, ⎿ details). Explicit-scheme matches only:
    /// agent transcripts are full of file names ("main.rs", "script.py")
    /// whose extensions double as country TLDs, and the data detector would
    /// happily linkify those without the `://` requirement.
    private func linkifyBareURLs(_ document: NSMutableAttributedString) {
        guard let detector = try? NSDataDetector(
            types: NSTextCheckingResult.CheckingType.link.rawValue) else { return }
        let text = document.string as NSString
        let matches = detector.matches(
            in: document.string, range: NSRange(location: 0, length: text.length))
        for match in matches {
            guard let url = match.url,
                  text.substring(with: match.range).contains("://"),
                  document.attribute(.link, at: match.range.location,
                                     effectiveRange: nil) == nil else { continue }
            document.addAttribute(.link, value: url, range: match.range)
        }
    }

    private func attributedRow(_ entry: AgentTranscriptEntry) -> NSAttributedString {
        let row = NSMutableAttributedString()
        if showTaskTags {
            row.append(atr("[\(AgentSpaceManager.agentSpaceName(entry.taskNumber))] ",
                           font: Palette.nsFontSmall, color: Palette.dimNS))
        }
        let flavor = Flavor(entry.agent)
        switch entry.kind {
        case .round:
            row.append(atr("── \(entry.text) ──",
                           font: Palette.nsFontSmall, color: Palette.faintNS))
        case .user:
            switch flavor {
            case nil:
                // A command typed into THIS console.
                row.append(atr("❯ ", font: Palette.nsFontBold, color: Palette.promptNS))
                row.append(markdownRuns(entry.text, color: Palette.textNS))
                if let detail = entry.detail, !detail.isEmpty {
                    appendDetail(row, detail, elbow: "⎿")
                }
            case .codex:
                row.append(atr("▌ ", font: Palette.nsFont, color: Palette.promptNS))
                row.append(markdownRuns(entry.text, color: Palette.textNS))
            case .pi:
                let start = row.length
                row.append(markdownRuns(entry.text, color: Palette.textNS))
                row.addAttribute(.backgroundColor, value: Palette.piUserBackgroundNS,
                                 range: NSRange(location: start, length: row.length - start))
            default:
                row.append(atr("> ", font: Palette.nsFontBold, color: Palette.dimNS))
                row.append(markdownRuns(entry.text, color: Palette.textNS))
            }
        case .assistant, .narration:
            if entry.kind == .assistant, flavor == .claude {
                row.append(atr("⏺ ", font: Palette.nsFont, color: Palette.textNS))
            }
            row.append(markdownRuns(entry.text, color: Palette.textNS))
        case .thinking:
            if flavor == .claude {
                row.append(atr("✻ ", font: Palette.nsFont, color: Palette.faintNS))
            }
            row.append(atr(entry.text, font: Palette.nsFont, color: Palette.faintNS,
                           oblique: true))
        case .action, .status, .error, .tool:
            if entry.kind == .tool, flavor == .pi {
                appendPiToolCard(entry, to: row)
            } else {
                if let glyph = glyphNS(for: entry) {
                    row.append(atr("\(glyph.symbol) ", font: Palette.nsFont,
                                   color: glyph.color))
                }
                row.append(atr(entry.text, font: Palette.nsFont,
                               color: kindColorNS(entry.kind)))
                if let detail = entry.detail, !detail.isEmpty {
                    appendDetail(row, detail, elbow: flavor == .codex ? "└" : "⎿")
                }
            }
        }
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = 3
        style.lineSpacing = 1
        row.addAttribute(.paragraphStyle, value: style,
                         range: NSRange(location: 0, length: row.length))
        return row
    }

    /// Pi's tool execution keeps its card reading: semibold title, output and
    /// diff lines under it, the pending/success/error tint carried as a run
    /// background.
    private func appendPiToolCard(_ entry: AgentTranscriptEntry,
                                  to row: NSMutableAttributedString) {
        let start = row.length
        row.append(atr(entry.text, font: Palette.nsFontSemibold, color: Palette.textNS))
        if let detail = entry.detail, !detail.isEmpty {
            for line in detail.split(separator: "\n", omittingEmptySubsequences: false) {
                let text = String(line)
                let color: NSColor
                if text.hasPrefix("+") && !text.hasPrefix("+++") {
                    color = Palette.piDiffAdditionNS
                } else if text.hasPrefix("-") && !text.hasPrefix("---") {
                    color = Palette.piDiffDeletionNS
                } else {
                    color = Palette.dimNS
                }
                row.append(atr("\n\(text)", font: Palette.nsFontSmall, color: color))
            }
        }
        let background: NSColor
        switch entry.piToolState {
        case .success: background = Palette.piToolSuccessBackgroundNS
        case .error: background = Palette.piToolErrorBackgroundNS
        case .pending, nil: background = Palette.piToolPendingBackgroundNS
        }
        row.addAttribute(.backgroundColor, value: background,
                         range: NSRange(location: start, length: row.length - start))
    }

    private func appendDetail(_ row: NSMutableAttributedString, _ detail: String,
                              elbow: String) {
        for (index, line) in detail
            .split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            row.append(atr(index == 0 ? "\n  \(elbow) \(line)" : "\n     \(line)",
                           font: Palette.nsFontSmall, color: Palette.faintNS))
        }
    }

    /// Markdown at block level, reusing the same parser as before the
    /// text-view feed: headings, bullets, numbered lists, code, tables (as
    /// monospace-aligned columns), and inline emphasis inside each.
    private func markdownRuns(_ text: String, color: NSColor) -> NSAttributedString {
        let out = NSMutableAttributedString()
        var first = true
        for block in parseMarkdown(text) {
            if !first { out.append(atr("\n", font: Palette.nsFont, color: color)) }
            first = false
            switch block {
            case .blank:
                break
            case .heading(let level, let text):
                out.append(inlineRuns(
                    text,
                    font: level <= 1 ? Palette.nsFontHeading : Palette.nsFontSubheading,
                    color: Palette.textNS))
            case .bullet(let text):
                out.append(atr("• ", font: Palette.nsFont, color: Palette.dimNS))
                out.append(inlineRuns(text, font: Palette.nsFont, color: color))
            case .numbered(let marker, let text):
                out.append(atr("\(marker) ", font: Palette.nsFont, color: Palette.dimNS))
                out.append(inlineRuns(text, font: Palette.nsFont, color: color))
            case .code(let line):
                out.append(atr("    \(line)", font: Palette.nsFontSmall,
                               color: Palette.dimNS))
            case .paragraph(let text):
                out.append(inlineRuns(text, font: Palette.nsFont, color: color))
            case .table(let rows):
                out.append(tableRuns(rows, color: color))
            }
        }
        return out
    }

    /// Inline markdown (**bold**, *italic*, `code`) mapped onto attributed
    /// runs; falls back to the literal string when parsing fails.
    private func inlineRuns(_ text: String, font: NSFont, color: NSColor) -> NSAttributedString {
        guard let parsed = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        else { return atr(text, font: font, color: color) }
        let out = NSMutableAttributedString()
        for run in parsed.runs {
            let piece = String(parsed[run.range].characters)
            let intent = run.inlinePresentationIntent ?? []
            var pieceFont = font
            var pieceColor = color
            if intent.contains(.stronglyEmphasized) {
                pieceFont = NSFont.monospacedSystemFont(ofSize: font.pointSize, weight: .bold)
            }
            if intent.contains(.code) { pieceColor = Palette.dimNS }
            let attributed = NSMutableAttributedString(
                attributedString: atr(piece, font: pieceFont, color: pieceColor,
                                      oblique: intent.contains(.emphasized)))
            if let link = run.link {
                attributed.addAttribute(
                    .link, value: link,
                    range: NSRange(location: 0, length: attributed.length))
            }
            out.append(attributed)
        }
        return out
    }

    /// A GFM table as monospace-aligned columns: cells padded to their
    /// column's width, header row bold.
    private func tableRuns(_ rows: [[String]], color: NSColor) -> NSAttributedString {
        var widths: [Int] = []
        for row in rows {
            for (index, cell) in row.enumerated() {
                if index == widths.count { widths.append(0) }
                widths[index] = max(widths[index], cell.count)
            }
        }
        let out = NSMutableAttributedString()
        for (index, row) in rows.enumerated() {
            if index > 0 { out.append(atr("\n", font: Palette.nsFontSmall, color: color)) }
            let padded = row.enumerated().map { column, cell in
                cell.padding(toLength: widths[column], withPad: " ", startingAt: 0)
            }.joined(separator: "  ")
            out.append(atr(padded,
                           font: index == 0 ? Palette.nsFontSmallBold : Palette.nsFontSmall,
                           color: index == 0 ? Palette.textNS : color))
        }
        return out
    }

    private func glyphNS(for entry: AgentTranscriptEntry) -> (symbol: String, color: NSColor)? {
        switch entry.kind {
        case .action: return ("⏺", Palette.promptNS)
        case .error: return ("✗", Palette.errorNS)
        case .tool: return (Flavor(entry.agent) == .codex ? "•" : "⏺", Palette.promptNS)
        case .user, .assistant, .narration, .status, .round, .thinking: return nil
        }
    }

    private func kindColorNS(_ kind: AgentTranscriptEntry.Kind) -> NSColor {
        switch kind {
        case .action, .status: return Palette.dimNS
        case .error: return Palette.errorNS
        default: return Palette.textNS
        }
    }

    /// `.obliqueness` stands in for italics: the monospaced system font has
    /// no true italic face.
    private func atr(_ text: String, font: NSFont, color: NSColor,
                     oblique: Bool = false) -> NSAttributedString {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: color,
        ]
        if oblique { attributes[.obliqueness] = 0.18 }
        return NSAttributedString(string: text, attributes: attributes)
    }

    @ViewBuilder
    /// The transcript body: ONE AppKit text view holding the whole feed as an
    /// attributed document, because native text selection is the only kind
    /// that can drag across lines — SwiftUI's per-view selection stops at
    /// each row's edge. The transient activity rows (spinners, resting
    /// summaries) stay SwiftUI, pinned under the scroll like the terminals
    /// they mirror pin their status line; they are state, not copyable text.
    private var feed: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                TranscriptTextFeed(entries: entries, showTaskTags: showTaskTags,
                                   build: { attributedTranscript() })
                if entries.isEmpty && activityTasks.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 18))
                            .foregroundStyle(Palette.faint)
                        Text(NSLocalizedString("agent.transcript.feed.emptyPlaceholder", value: "Nothing yet — agent activity appears here live.",
                            comment: "Agent console - empty feed placeholder"))
                            .font(Palette.fontUISmall)
                            .foregroundStyle(Palette.faint)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 48)
                    .frame(maxHeight: .infinity, alignment: .top)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if !activityTasks.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(activityTasks, id: \.taskId) { task in
                        if let state = claudeActivity(for: task) {
                            claudeActivityRow(task: task, state: state)
                        } else if let state = codexActivity(for: task) {
                            codexActivityRow(task: task, state: state)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
        }
    }

    /// Codex-style transient activity at the tail. The pulse changes opacity
    /// in place, making the state visibly live without adding repeated rows.
    private func codexActivityRow(task: AgentTask, state: CodexTranscriptActivity) -> some View {
        TimelineView(.periodic(from: .now, by: 0.55)) { context in
            let bright = Int(context.date.timeIntervalSinceReferenceDate / 0.55)
                .isMultiple(of: 2)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if showTaskTags { taskTag(task.number) }
                Text("•")
                    .font(Palette.font)
                    .foregroundStyle(Palette.prompt)
                    .opacity(bright ? 1 : 0.2)
                Text(verbatim: state == .working ? "Working…" : "Waiting…")
                    .font(Palette.font)
                    .foregroundStyle(Palette.dim)
                    .opacity(bright ? 1 : 0.5)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(verbatim:
                state == .working ? "Working" : "Waiting"))
        }
    }

    /// Claude Code's spinner glyphs, cycled the way the terminal breathes
    /// them: grow to the full asterisk, then shrink back.
    private static let claudeSpinnerFrames = ["·", "✢", "✳", "✶", "✻", "✽", "✻", "✶", "✳", "✢"]

    /// Whimsical turn verbs in Claude Code's voice, as gerund/past pairs so
    /// the live spinner ("Mulling…") and the resting summary ("Mulled for
    /// 28s") conjugate the same verb.
    private static let claudeVerbs: [(gerund: String, past: String)] = [
        ("Mulling", "Mulled"), ("Cogitating", "Cogitated"), ("Pondering", "Pondered"),
        ("Musing", "Mused"), ("Ruminating", "Ruminated"), ("Noodling", "Noodled"),
        ("Percolating", "Percolated"), ("Brewing", "Brewed"), ("Simmering", "Simmered"),
        ("Crunching", "Crunched"), ("Deliberating", "Deliberated"), ("Tinkering", "Tinkered"),
    ]

    /// The turn's verb, seeded by the turn's start time — stable across
    /// re-renders and shared by the working spinner and its later summary.
    private static func claudeVerb(seedMs: Double?) -> (gerund: String, past: String) {
        guard let seedMs, seedMs.isFinite, seedMs > 0, seedMs < 1e15 else {
            return ("Working", "Worked")
        }
        return claudeVerbs[Int(seedMs) % claudeVerbs.count]
    }

    /// Elapsed/duration readout in Claude Code's terminal shape: "6s",
    /// "1m 43s", "2h 5m".
    private static func claudeDuration(_ seconds: Int) -> String {
        let s = max(0, seconds)
        if s < 60 { return "\(s)s" }
        let m = s / 60
        if m < 60 {
            let rs = s % 60
            return rs == 0 ? "\(m)m" : "\(m)m \(rs)s"
        }
        let h = m / 60
        let rm = m % 60
        return rm == 0 ? "\(h)h" : "\(h)h \(rm)m"
    }

    /// Claude Code's terminal status line, mirrored at the transcript tail:
    /// the animated "✽ Mulling… (6s · thinking with xhigh effort)" while a
    /// turn runs, and the resting "Cogitated for 28s · 1 shell still running"
    /// summary once it ends — until the next turn replaces it.
    @ViewBuilder
    private func claudeActivityRow(task: AgentTask, state: ClaudeTranscriptActivity) -> some View {
        switch state.phase {
        case .working:
            claudeWorkingRow(task: task, state: state)
        case .idle:
            claudeIdleRow(task: task, state: state)
        }
    }

    private func claudeWorkingRow(task: AgentTask,
                                  state: ClaudeTranscriptActivity) -> some View {
        let verb = Self.claudeVerb(seedMs: state.startTimestampMs)
        return TimelineView(.periodic(from: .now, by: 0.15)) { context in
            let tick = Int(context.date.timeIntervalSinceReferenceDate / 0.15)
            let frame = Self.claudeSpinnerFrames[
                abs(tick) % Self.claudeSpinnerFrames.count]
            var suffixParts: [String] = []
            if let startMs = state.startTimestampMs {
                let elapsed = Int(context.date.timeIntervalSince1970 - startMs / 1000)
                suffixParts.append(Self.claudeDuration(elapsed))
            }
            if let effort = state.effort {
                suffixParts.append("thinking with \(effort) effort")
            }
            return HStack(alignment: .firstTextBaseline, spacing: 6) {
                if showTaskTags { taskTag(task.number) }
                Text(verbatim: frame)
                    .font(Palette.font)
                    .foregroundStyle(Palette.claudeAccent)
                Text(verbatim: "\(verb.gerund)…")
                    .font(Palette.font)
                    .foregroundStyle(Palette.claudeAccent)
                if !suffixParts.isEmpty {
                    Text(verbatim: "(\(suffixParts.joined(separator: " · ")))")
                        .font(Palette.font)
                        .foregroundStyle(Palette.faint)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(verbatim: "Working"))
        }
    }

    private func claudeIdleRow(task: AgentTask,
                               state: ClaudeTranscriptActivity) -> some View {
        let verb = Self.claudeVerb(seedMs: state.startTimestampMs)
        var parts: [String] = []
        if let ms = state.durationMs, ms >= 1000 {
            parts.append("\(verb.past) for \(Self.claudeDuration(Int(ms / 1000)))")
        }
        if state.shellsRunning > 0 {
            parts.append(state.shellsRunning == 1
                ? "1 shell still running"
                : "\(state.shellsRunning) shells still running")
        }
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            if showTaskTags { taskTag(task.number) }
            Text(verbatim: parts.joined(separator: " · "))
                .font(Palette.font)
                .foregroundStyle(Palette.dim)
        }
        .accessibilityElement(children: .combine)
    }

    /// The origin-CLI dialect of a mirrored line — which visual language the
    /// row borrows so the console reads like the driving agent's own UI.
    /// nil (app/skill-authored) keeps Phi's console style; unrecognized
    /// agents get a neutral CLI look.
    private enum Flavor {
        case claude, codex, pi, generic

        init?(_ agent: String?) {
            switch agent {
            case nil: return nil
            case "claude": self = .claude
            case "codex": self = .codex
            case "pi": self = .pi
            default: self = .generic
            }
        }
    }

    private func taskTag(_ number: Int) -> some View {
        Text(AgentSpaceManager.agentSpaceName(number))
            .font(Palette.fontUISmall.weight(.medium))
            .foregroundStyle(Palette.dim)
            .padding(.horizontal, 4)
            .padding(.vertical, 0.5)
            .background(Palette.faint.opacity(0.14),
                        in: RoundedRectangle(cornerRadius: 3, style: .continuous))
    }

    // MARK: - Markdown

    private enum MDBlock {
        case blank
        case heading(Int, String)
        case bullet(String)
        case numbered(String, String)
        case code(String)
        case paragraph(String)
        /// A GFM table; first row is the header (the separator row that
        /// declared it a table is consumed by the parser, not stored).
        case table([[String]])
    }

    private func parseMarkdown(_ text: String) -> [MDBlock] {
        var out: [MDBlock] = []
        var inCode = false
        let lines = text.components(separatedBy: "\n")
        var index = 0
        while index < lines.count {
            let raw = lines[index]
            index += 1
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") { inCode.toggle(); continue }  // drop fence lines
            if inCode { out.append(.code(raw)); continue }
            if trimmed.isEmpty { out.append(.blank); continue }
            // GFM table: a pipe row whose NEXT line is the |---|---| separator
            // starts one; body rows are the following pipe rows. Without the
            // separator, pipe-bearing lines stay ordinary paragraphs.
            if trimmed.contains("|"), index < lines.count,
               Self.isTableSeparator(lines[index].trimmingCharacters(in: .whitespaces)) {
                var rows = [Self.tableCells(trimmed)]
                index += 1  // consume the separator line
                while index < lines.count {
                    let row = lines[index].trimmingCharacters(in: .whitespaces)
                    guard row.contains("|"), !row.isEmpty else { break }
                    rows.append(Self.tableCells(row))
                    index += 1
                }
                out.append(.table(rows))
                continue
            }
            if trimmed.hasPrefix("#") {
                let hashes = trimmed.prefix(while: { $0 == "#" })
                if hashes.count <= 6,
                   trimmed.dropFirst(hashes.count).first == " " {
                    out.append(.heading(hashes.count,
                        trimmed.dropFirst(hashes.count).trimmingCharacters(in: .whitespaces)))
                    continue
                }
            }
            if let r = trimmed.range(of: "^[-*+][ \t]+", options: .regularExpression) {
                out.append(.bullet(String(trimmed[r.upperBound...])))
                continue
            }
            if let r = trimmed.range(of: "^[0-9]+\\.[ \t]+", options: .regularExpression) {
                out.append(.numbered(
                    String(trimmed[trimmed.startIndex..<r.upperBound])
                        .trimmingCharacters(in: .whitespaces),
                    String(trimmed[r.upperBound...])))
                continue
            }
            out.append(.paragraph(raw))
        }
        return out
    }

    /// `| --- | :---: |` and friends — dashes with optional alignment colons,
    /// pipes and spaces, nothing else.
    private static func isTableSeparator(_ s: String) -> Bool {
        guard s.contains("-"), s.contains("|") else { return false }
        return s.range(of: #"^\|?[ \t]*:?-+:?[ \t]*(\|[ \t]*:?-+:?[ \t]*)*\|?$"#,
                       options: .regularExpression) != nil
    }

    /// Splits a pipe row into trimmed cells, dropping the empty edges a
    /// leading/trailing pipe produces.
    private static func tableCells(_ s: String) -> [String] {
        var cells = s.components(separatedBy: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        if cells.first?.isEmpty == true { cells.removeFirst() }
        if cells.last?.isEmpty == true { cells.removeLast() }
        return cells
    }

    private var promptRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("❯")
                    .font(Palette.font.weight(.bold))
                    .foregroundStyle(promptTarget == nil ? Palette.faint : Palette.prompt)
                TextField(promptPlaceholder, text: $draft)
                    .textFieldStyle(.plain)
                    .font(Palette.font)
                    .foregroundStyle(Palette.text)
                    .focused($promptFocused)
                    .disabled(promptTarget == nil)
                    .onSubmit(sendDraft)
                if !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button(action: sendDraft) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(Palette.prompt)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Palette.background,
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(promptFocused ? Palette.prompt.opacity(0.5)
                                                : Palette.faint.opacity(0.35),
                                  lineWidth: 1)
            )
            if let target = promptTarget, target.status != .running {
                Text(NSLocalizedString("agent.transcript.commandInput.idleAgentHint", value: "agent idle — command starts or queues its next round",
                    comment: "Agent console - hint for sending a command to an idle agent"))
                    .font(Palette.fontUISmall)
                    .foregroundStyle(Palette.faint)
                    .padding(.leading, 2)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Palette.chrome)
    }

    private var promptPlaceholder: String {
        guard let target = promptTarget else {
            return NSLocalizedString("agent.transcript.commandInput.noActiveTaskPlaceholder", value: "No active agent task", comment: "Agent console - prompt disabled placeholder")
        }
        return String(
            format: NSLocalizedString("agent.transcript.commandInput.targetSpacePlaceholder", value: "Message the agent (→ %@)",
                comment: "Agent console - prompt placeholder naming the target task's Space"),
            AgentSpaceManager.agentSpaceName(target.number))
    }

    private func sendDraft() {
        guard let target = promptTarget else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        AgentSpaceManager.shared.sendUserMessage(taskId: target.taskId, text: text)
        draft = ""
    }
}
