// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import Combine
import SwiftUI

/// Owns horizontal wheel gestures before they reach sidebar Space navigation.
/// A claimed gesture remains local to this window if the pointer leaves the card.
final class SidebarMediaHostingView: ThemedHostingView {
    weak var mediaController: SidebarMediaController? {
        didSet { bindSwipeCancellation() }
    }
    var mediaSurface: SidebarMediaController.Surface = .docked {
        didSet { if oldValue != mediaSurface { cancelMediaSwipe() } }
    }
    private var heightAnimationTimer: Timer?
    private let swipeTracker = SpaceSwipeTracker()
    private var swipeItem: SidebarMediaController.Item?
    private var swipeMonitor: Any?
    private var swipeWindowCloseObserver: NSObjectProtocol?
    private(set) var isMediaSwipeCancelled = false
    private var swipeSubscriptions = Set<AnyCancellable>()

    override var mouseDownCanMoveWindow: Bool { false }

    /// Update the actual host bounds so SwiftUI lays out every animation frame.
    /// Layer-only resizing can leave the hosted content at its final size.
    func animateHeight(to height: CGFloat, update: @escaping (CGFloat) -> Void) {
        cancelHeightAnimation()
        let initialHeight = frame.height
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              abs(initialHeight - height) > 0.5 else {
            update(height)
            return
        }
        let start = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                let progress = min(1, (ProcessInfo.processInfo.systemUptime - start) / 0.2)
                let eased = progress * progress * (3 - 2 * progress)
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0
                    context.allowsImplicitAnimation = false
                    update(initialHeight + (height - initialHeight) * eased)
                }
                if progress >= 1 { self.cancelHeightAnimation() }
            }
        }
        heightAnimationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func cancelHeightAnimation() {
        heightAnimationTimer?.invalidate()
        heightAnimationTimer = nil
    }

    private func bindSwipeCancellation() {
        cancelMediaSwipe()
        swipeSubscriptions.removeAll()
        guard let controller = mediaController else { return }
        controller.$item.dropFirst().receive(on: DispatchQueue.main).sink { [weak self, weak controller] _ in
            guard let self, let controller, let item = self.swipeItem else { return }
            if !controller.matchesCurrentSource(item) { self.cancelMediaSwipe() }
        }.store(in: &swipeSubscriptions)
        controller.$presentationMode.dropFirst().sink { [weak self] _ in self?.cancelMediaSwipe() }
            .store(in: &swipeSubscriptions)
        controller.$activeSurface.dropFirst().sink { [weak self] _ in self?.cancelMediaSwipe() }
            .store(in: &swipeSubscriptions)
        controller.$isSourceVisible.dropFirst().filter { $0 }.sink { [weak self] _ in self?.cancelMediaSwipe() }
            .store(in: &swipeSubscriptions)
        controller.$isDismissed.dropFirst().filter { $0 }.sink { [weak self] _ in self?.cancelMediaSwipe() }
            .store(in: &swipeSubscriptions)
    }

    func cancelMediaSwipe() {
        swipeItem = nil
        if swipeTracker.consumesHorizontalGesture {
            // Keep this physical gesture claimed through release. Resetting
            // its axis would let changed events adopt the replacement card.
            isMediaSwipeCancelled = true
        } else {
            releaseSwipe()
            swipeTracker.reset()
        }
    }

    override func scrollWheel(with event: NSEvent) {
        if handleMediaSwipe(deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY,
                            phase: event.phase, momentum: event.momentumPhase,
                            timestamp: event.timestamp,
                            isDirectionInvertedFromDevice: event.isDirectionInvertedFromDevice) { return }
        super.scrollWheel(with: event)
    }

    /// The phase boundary also lets native tests exercise cancellation without
    /// constructing synthetic OS input or adopting a newly published source.
    @discardableResult
    func handleMediaSwipe(deltaX: CGFloat, deltaY: CGFloat, phase: NSEvent.Phase,
                          momentum: NSEvent.Phase, timestamp: TimeInterval,
                          isDirectionInvertedFromDevice: Bool = true) -> Bool {
        if phase.contains(.began) || phase.contains(.mayBegin) {
            releaseSwipe()
            swipeTracker.reset()
            isMediaSwipeCancelled = false
        }
        // Device wheel deltas point opposite a card's physical displacement;
        // natural scrolling has already reversed them. Keep finger direction
        // consistent with mouse dragging without changing the Space tracker.
        let displacementSign: CGFloat = isDirectionInvertedFromDevice ? 1 : -1
        let outcome = swipeTracker.handle(deltaX: deltaX * displacementSign, deltaY: deltaY * displacementSign,
                                          phase: phase, momentum: momentum, timestamp: timestamp)
        let consumed = handleMediaSwipe(outcome)
        if consumed, swipeTracker.consumesHorizontalGesture { retainSwipeOwnership() }
        if phase.contains(.ended) || phase.contains(.cancelled) || momentum.contains(.ended) {
            releaseSwipe()
            isMediaSwipeCancelled = false
        }
        // The first directional delta, rather than a zero-delta begin,
        // decides whether the sidebar receives vertical scrolling.
        return consumed || ((phase.contains(.began) || phase.contains(.mayBegin)) && deltaX == 0 && deltaY == 0)
    }

    @discardableResult
    private func handleMediaSwipe(_ outcome: SpaceSwipeTracker.Outcome) -> Bool {
        switch outcome {
        case .passthrough: return false
        case .consumed: return true
        case .update(_, _, let began):
            if began && !isMediaSwipeCancelled { swipeItem = mediaController?.item }
            return true
        case .end(let distance, let velocity, let cancelled):
            if !cancelled, !isMediaSwipeCancelled, distance != 0,
               SpaceSwipeTracker.shouldComplete(distance: distance, velocity: velocity, width: min(bounds.width, 114)),
               let item = swipeItem {
                mediaController?.cycleSource(for: item, direction: distance < 0 ? .next : .previous,
                                             from: mediaSurface)
            }
            swipeItem = nil
            return true
        }
    }

    private func retainSwipeOwnership() {
        guard swipeMonitor == nil, let ownerWindow = window else { return }
        swipeWindowCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: ownerWindow, queue: .main
        ) { [weak self] _ in self?.releaseSwipe() }
        swipeMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self, weak ownerWindow] event in
            guard let self else { return event }
            guard let ownerWindow else { self.releaseSwipe(); return event }
            guard event.window === ownerWindow else { return event }
            if event.phase.contains(.began) || event.phase.contains(.mayBegin) {
                self.releaseSwipe()
                self.swipeTracker.reset()
                self.isMediaSwipeCancelled = false
                return event
            }
            _ = self.handleMediaSwipe(deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY,
                                      phase: event.phase, momentum: event.momentumPhase,
                                      timestamp: event.timestamp,
                                      isDirectionInvertedFromDevice: event.isDirectionInvertedFromDevice)
            return nil
        }
    }

    private func releaseSwipe() {
        if let swipeMonitor { NSEvent.removeMonitor(swipeMonitor) }
        swipeMonitor = nil
        if let swipeWindowCloseObserver { NotificationCenter.default.removeObserver(swipeWindowCloseObserver) }
        swipeWindowCloseObserver = nil
        swipeItem = nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            cancelMediaSwipe()
            cancelHeightAnimation()
        }
    }

    isolated deinit {
        heightAnimationTimer?.invalidate()
        if let swipeMonitor { NSEvent.removeMonitor(swipeMonitor) }
        if let swipeWindowCloseObserver { NotificationCenter.default.removeObserver(swipeWindowCloseObserver) }
    }
}

/// Read the shared direction while animating, including for an outgoing card
/// whose previous view value was created for the opposite cycle direction.
struct SidebarMediaCardTransition: AnimatableModifier {
    @ObservedObject var controller: SidebarMediaController
    let isInsertion: Bool
    var progress: CGFloat
    let width: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    var horizontalOffset: CGFloat {
        let direction: CGFloat = controller.cycleDirection == .next ? 1 : -1
        return direction * (isInsertion ? 1 : -1) * width * progress
    }

    func body(content: Content) -> some View {
        content.offset(x: horizontalOffset).opacity(1 - Double(progress))
    }
}

private struct SidebarMediaTimelineFrameKey: PreferenceKey {
    static var defaultValue: CGRect { .zero }
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

private struct SidebarMediaVolumeFrameKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}


/// Shared feedback for transport, source, PiP and dismissal buttons.
private struct SidebarMediaButtonStyle: ButtonStyle {
    @Environment(\.phiTheme) private var theme
    @Environment(\.phiAppearance) private var appearance
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(RoundedRectangle(cornerRadius: 5))
            .background {
                RoundedRectangle(cornerRadius: 5)
                    .fill(ThemedColor.textPrimary.swiftUIColor(theme: theme, appearance: appearance)
                        .opacity(isEnabled ? (configuration.isPressed ? 0.18 : (isHovering ? 0.1 : 0)) : 0))
            }
            .opacity(isEnabled ? 1 : 0.4)
            .scaleEffect(isEnabled && configuration.isPressed && !reduceMotion ? 0.94 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isHovering)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: configuration.isPressed)
            .onHover { isHovering = $0 }
    }
}

/// Uses the selected presentation mode. The hosting view is
/// constrained to the sidebar's live width by SidebarViewController.
struct SidebarMediaPlayerView: View {
    private struct ScrubTarget: Equatable {
        let tabId: Int
        let wrapperId: ObjectIdentifier
        let documentEpoch: Int
        let sourceToken: String
        let token: String

        init(_ item: SidebarMediaController.Item) {
            tabId = item.tabId
            wrapperId = item.wrapperId
            documentEpoch = item.documentEpoch
            sourceToken = item.playback.sourceToken
            token = item.playback.token
        }
    }

    @ObservedObject var controller: SidebarMediaController
    let surface: SidebarMediaController.Surface
    @Environment(\.phiTheme) private var theme
    @Environment(\.phiAppearance) private var appearance
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var compactFocused: Bool
    @FocusState private var playPauseFocused: Bool
    @State private var keyboardExpanded = false
    @State private var scrubbing = false
    @State private var scrubCancelled = false
    @State private var scrubValue: Double = 0
    @State private var scrubTarget: ScrubTarget?
    @State private var isHovering = false
    @State private var hoverExitWorkItem: DispatchWorkItem?
    @State private var timelineFrame: CGRect = .zero
    @State private var volumeFrame: CGRect = .zero
    @State private var volumeTarget: SidebarMediaController.Item?
    @State private var cardDragItem: SidebarMediaController.Item?

    private var foreground: Color {
        ThemedColor.textPrimary.swiftUIColor(theme: theme, appearance: appearance)
    }

    private var secondary: Color {
        ThemedColor.textSecondary.swiftUIColor(theme: theme, appearance: appearance)
    }

    private var background: Color {
        // The sidebar itself uses windowOverlayBackground. Tint only this
        // card, preserving the user's sidebar palette and saturation setting.
        let sidebar = ThemedColor.windowOverlayBackground.resolve(
            theme: theme, appearance: appearance)
        // Expansion overlays tab rows, so an opaque surface keeps their text
        // from bleeding through the player's title and timeline.
        let alpha: CGFloat = 1
        // An achromatic Pure sidebar has no hue to saturate; keep it neutral.
        let saturation = sidebar.hsbSaturationComponent > 0.01
            ? min(sidebar.hsbSaturationComponent + 0.12, 1) : 0
        let colored = sidebar.withHSBSaturation(saturation, alpha: alpha)
        let brightness = min(max(colored.hsbBrightnessComponent
                                 + (appearance.isLight ? -0.03 : 0.05), 0), 1)
        return Color(nsColor: colored.withHSBBrightness(brightness, alpha: alpha))
    }

    var body: some View {
        Group {
            if let item = controller.item, controller.activeSurface == surface,
               !controller.isRevalidating,
               !controller.isSourceVisible, !controller.isDismissed {
                GeometryReader { geometry in
                    ZStack {
                      VStack(spacing: 0) {
                       GeometryReader { contentGeometry in
                        let detailsHeight = max(0, contentGeometry.size.height - 32)
                        let revealProgress = min(max((detailsHeight - 54) / 32, 0), 1)
                        ZStack(alignment: .bottom) {
                            // Reveal details near the end of expansion, reversing on collapse.
                            // Clip before filling the host so content cannot cover transport.
                            expandedDetails(item)
                                .frame(height: detailsHeight, alignment: .top)
                                .clipped()
                                .opacity(revealProgress)
                                .frame(maxHeight: .infinity, alignment: .top)
                                .allowsHitTesting(controller.isExpanded && revealProgress >= 0.95)
                                .accessibilityHidden(!controller.isExpanded || revealProgress < 0.95)
                            transportRow(item)
                        }
                       }
                       volumeRow(item)
                           .frame(height: controller.isVolumeExpanded ? 34 : 0)
                           .clipped()
                           .animation(reduceMotion ? nil : .easeInOut(duration: 0.2),
                                      value: controller.isVolumeExpanded)
                           // Hide immediately while the row height finishes collapsing.
                           .opacity(controller.isVolumeExpanded ? 1 : 0)
                           .animation(nil, value: controller.isVolumeExpanded)
                           .allowsHitTesting(controller.isVolumeExpanded)
                           .accessibilityHidden(!controller.isVolumeExpanded)
                      }
                      .id(item.tabId)
                      .transition(reduceMotion ? .opacity : .asymmetric(
                        insertion: .modifier(
                            active: SidebarMediaCardTransition(controller: controller, isInsertion: true,
                                                               progress: 1, width: geometry.size.width),
                            identity: SidebarMediaCardTransition(controller: controller, isInsertion: true,
                                                                 progress: 0, width: geometry.size.width)),
                        removal: .modifier(
                            active: SidebarMediaCardTransition(controller: controller, isInsertion: false,
                                                               progress: 1, width: geometry.size.width),
                            identity: SidebarMediaCardTransition(controller: controller, isInsertion: false,
                                                                 progress: 0, width: geometry.size.width))))
                    }
                    .clipped()
                    .animation(.easeInOut(duration: reduceMotion ? 0.12 : 0.22),
                               value: controller.cycleAnimationGeneration)
                }
                .coordinateSpace(name: "sidebarMedia.card")
                .onPreferenceChange(SidebarMediaTimelineFrameKey.self) { timelineFrame = $0 }
                .onPreferenceChange(SidebarMediaVolumeFrameKey.self) { volumeFrame = $0 }
                .contentShape(Rectangle())
                .simultaneousGesture(DragGesture(minimumDistance: 24, coordinateSpace: .named("sidebarMedia.card"))
                    .onChanged { value in
                        // Wheel gestures belong to the AppKit host. Only a
                        // pressed mouse drag may claim this parallel path.
                        guard NSEvent.pressedMouseButtons & 1 != 0,
                              controller.backgroundSourceCount > 1,
                              !timelineFrame.contains(value.startLocation), !volumeFrame.contains(value.startLocation),
                              controller.matchesCurrentSource(item) else { return }
                        if cardDragItem == nil { cardDragItem = item }
                    }
                    .onEnded { value in
                        defer { cardDragItem = nil }
                        guard let source = cardDragItem,
                              abs(value.translation.width) >= 40,
                              abs(value.translation.width) > abs(value.translation.height),
                              !timelineFrame.contains(value.startLocation), !volumeFrame.contains(value.startLocation) else { return }
                        controller.cycleSource(for: source,
                                               direction: value.translation.width < 0 ? .next : .previous,
                                               from: surface)
                    })
                .frame(maxWidth: .infinity)
                .frame(maxHeight: .infinity)
                .background {
                    if controller.backgroundSourceCount > 1 {
                        RoundedRectangle(cornerRadius: 9).fill(background)
                            .overlay(RoundedRectangle(cornerRadius: 9).stroke(secondary.opacity(0.3)))
                            .padding(.horizontal, 4).offset(y: -4)
                            .opacity(0.65)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                        .accessibilityIdentifier("sidebarMedia.stack")
                    }
                    RoundedRectangle(cornerRadius: 9).fill(background)
                }
                .overlay(RoundedRectangle(cornerRadius: 9)
                    .stroke(ThemedColor.border.swiftUIColor(theme: theme,
                                                            appearance: appearance)))
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("sidebarMedia.card")
                .onHover { hovering in
                    isHovering = hovering
                    hoverExitWorkItem?.cancel()
                    hoverExitWorkItem = nil
                    controller.setHovering(hovering, on: surface)
                    if !hovering && !keyboardExpanded && scrubTarget == nil {
                        scheduleHoverCollapse()
                    }
                }
                .onExitCommand { collapse() }
                .onChange(of: controller.presentationMode) { _, _ in
                    hoverExitWorkItem?.cancel()
                    hoverExitWorkItem = nil
                    keyboardExpanded = false
                    if isHovering { controller.setHovering(true, on: surface) }
                }
                .onChange(of: ScrubTarget(item)) { _, _ in
                    controller.setHovering(false, on: surface)
                    if isHovering { controller.setHovering(true, on: surface) }
                    keyboardExpanded = false
                    // Keep the original target locked through the active
                    // gesture. A later drag event must not adopt new media.
                    scrubCancelled = scrubTarget != nil
                    scrubbing = false
                    hoverExitWorkItem?.cancel()
                    hoverExitWorkItem = nil
                    if !isHovering && scrubTarget == nil { scheduleHoverCollapse() }
                }
                .onChange(of: item.playback.currentTime) { _, newValue in
                    if !scrubbing, let newValue { scrubValue = newValue }
                }
                .onDisappear {
                    controller.setHovering(false, on: surface)
                    hoverExitWorkItem?.cancel()
                    hoverExitWorkItem = nil
                    scrubTarget = nil
                    volumeTarget = nil
                    cardDragItem = nil
                    scrubCancelled = false
                    scrubbing = false
                    isHovering = false
                    keyboardExpanded = false
                    controller.setExpanded(false, on: surface)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
            }
        }
    }

    /// Keep the transport in one view at the card's bottom so the buttons do
    /// not move or change identity when pointer hover reveals the details.
    private func transportRow(_ item: SidebarMediaController.Item) -> some View {
        HStack(spacing: 4) {
            Button(action: { controller.showTab(for: item, from: surface) }) {
                siteIcon(item).frame(width: 24, height: 24)
            }
            .buttonStyle(SidebarMediaButtonStyle())
            .focusEffectDisabled()
            .focused($compactFocused)
            .help(openTabLabel)
            .accessibilityLabel(openTabLabel)
            .accessibilityIdentifier("sidebarMedia.sourceTab")
            .onChange(of: compactFocused) { _, focused in
                if focused && controller.presentationMode == .dynamic
                    && controller.matchesCurrentSource(item) {
                    keyboardExpanded = true
                    setExpanded(true)
                }
            }

            Spacer(minLength: 0)
            HStack(spacing: 2) {
                controlButton("backward.end.fill", label: previousTrackLabel,
                              enabled: item.playback.canPreviousTrack) {
                    controller.perform(.previousTrack, for: item, from: surface)
                }
                .accessibilityIdentifier("sidebarMedia.previousTrack")
                playPauseButton(item)
                controlButton("forward.end.fill", label: nextTrackLabel,
                              enabled: item.playback.canNextTrack) {
                    controller.perform(.nextTrack, for: item, from: surface)
                }
                .accessibilityIdentifier("sidebarMedia.nextTrack")
            }
            Spacer(minLength: 0)
            controlButton(item.isTabMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                          label: volumeLabel,
                          enabled: true, action: {
                              controller.volumeButtonClicked(for: item, from: surface,
                                  optionPressed: NSEvent.modifierFlags.contains(.option))
                          })
                .frame(width: 24)
                .accessibilityIdentifier("sidebarMedia.volumeButton")
                .accessibilityValue(item.isTabMuted ? mutedStatusLabel : unmutedStatusLabel)
        }
        .padding(.horizontal, 8)
        .frame(height: 32)
    }

    private func volumeRow(_ item: SidebarMediaController.Item) -> some View {
        HStack(spacing: 6) {
            Slider(value: Binding(
                get: { item.playback.volume ?? 1 },
                set: { controller.setVolume($0, for: volumeTarget ?? item, from: surface) }
            ), in: 0...1, onEditingChanged: { editing in
                volumeTarget = editing ? item : nil
            })
            .themedTint(.themeColor)
            .disabled(!item.playback.canSetVolume || controller.isChangingTrack)
            .accessibilityLabel(volumeSliderLabel)
            .accessibilityIdentifier("sidebarMedia.volumeSlider")
        }
        .padding(.horizontal, 10)
        .background(GeometryReader { geometry in
            Color.clear.preference(key: SidebarMediaVolumeFrameKey.self,
                                   value: geometry.frame(in: .named("sidebarMedia.card")))
        })
    }

    private func expandedDetails(_ item: SidebarMediaController.Item) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(item.playback.title.isEmpty ? fallbackTitle : item.playback.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(foreground)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("sidebarMedia.title")
                    if item.playback.canPictureInPicture {
                        Button {
                            controller.perform(.pictureInPicture, for: item, from: surface)
                        } label: {
                            Image(item.playback.isPictureInPicture
                                  ? "sidebar-media-pip-exit" : "sidebar-media-pip-enter")
                                .resizable()
                                .renderingMode(.template)
                                .scaledToFit()
                                .frame(width: 16, height: 16)
                                .frame(width: 22, height: 22)
                        }
                        .buttonStyle(SidebarMediaButtonStyle())
                        .focusEffectDisabled()
                        .foregroundStyle(foreground)
                        .help(item.playback.isPictureInPicture ? exitPictureInPictureLabel
                                                               : enterPictureInPictureLabel)
                        .accessibilityLabel(item.playback.isPictureInPicture
                                            ? exitPictureInPictureLabel
                                            : enterPictureInPictureLabel)
                        .accessibilityIdentifier("sidebarMedia.pictureInPicture")
                    }
                    if controller.presentationMode != .dynamic {
                      Button(action: { controller.dismissCurrent(for: item, from: surface) }) {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(SidebarMediaButtonStyle())
                    .focusEffectDisabled()
                    .foregroundStyle(secondary)
                    .help(dismissLabel)
                    .accessibilityLabel(dismissLabel)
                    .accessibilityIdentifier("sidebarMedia.dismiss")
                    }
                }
                if let artist = item.playback.artist {
                    Text(artist)
                        .font(.system(size: 10))
                        .foregroundStyle(secondary)
                        .lineLimit(1)
                }
            }

            if let duration = item.playback.duration, let position = item.playback.currentTime {
                VStack(spacing: 4) {
                    timeline(item, duration: duration, currentTime: position)
                    HStack {
                        Text(Self.timeString(position))
                            .accessibilityIdentifier("sidebarMedia.elapsed")
                        Spacer(minLength: 2)
                        Text(Self.timeString(duration))
                            .accessibilityIdentifier("sidebarMedia.duration")
                    }
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(secondary)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .frame(maxWidth: .infinity)
    }

    /// A single quiet progress line; the larger invisible hit area supports
    /// dragging, keyboard arrows, and VoiceOver adjustment without a knob.
    private func timeline(_ item: SidebarMediaController.Item,
                          duration: Double, currentTime: Double) -> some View {
        GeometryReader { geometry in
            let position = scrubbing ? scrubValue : currentTime
            let fraction = min(max(position / duration, 0), 1)
            ZStack(alignment: .leading) {
                Capsule().fill(secondary.opacity(0.34))
                Capsule().fill(foreground.opacity(0.8))
                    .frame(width: max(0, geometry.size.width * fraction))
            }
            .frame(height: 3)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    guard item.playback.canSeek else { return }
                    let target = ScrubTarget(item)
                    if scrubTarget == nil { scrubTarget = target }
                    guard !scrubCancelled, scrubTarget == target,
                          let current = controller.item,
                          ScrubTarget(current) == target else {
                        scrubCancelled = true
                        scrubbing = false
                        return
                    }
                    scrubbing = true
                    scrubValue = duration * min(max(value.location.x
                                                     / max(geometry.size.width, 1), 0), 1)
                }
                .onEnded { value in
                    guard item.playback.canSeek, !scrubCancelled,
                          let target = scrubTarget,
                          target == ScrubTarget(item),
                          let current = controller.item,
                          target == ScrubTarget(current) else {
                        scrubTarget = nil
                        scrubCancelled = false
                        scrubbing = false
                        if !isHovering { scheduleHoverCollapse() }
                        return
                    }
                    scrubValue = duration * min(max(value.location.x
                                                     / max(geometry.size.width, 1), 0), 1)
                    controller.perform(.seek(scrubValue), for: item, from: surface)
                    scrubTarget = nil
                    scrubCancelled = false
                    scrubbing = false
                    if !isHovering { scheduleHoverCollapse() }
                })
        }
        .frame(height: 18)
        .background(GeometryReader { geometry in
            Color.clear.preference(key: SidebarMediaTimelineFrameKey.self,
                                   value: geometry.frame(in: .named("sidebarMedia.card")))
        })
        .focusable(item.playback.canSeek)
        .focusEffectDisabled()
        .onMoveCommand { direction in
            guard item.playback.canSeek else { return }
            switch direction {
            case .left: controller.perform(.seek(currentTime - 5), for: item, from: surface)
            case .right: controller.perform(.seek(currentTime + 5), for: item, from: surface)
            default: break
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(progressLabel)
        .accessibilityIdentifier("sidebarMedia.timeline")
        .accessibilityValue(String(
            format: progressValueFormat,
            Self.timeString(currentTime), Self.timeString(duration)))
        .accessibilityAdjustableAction { direction in
            guard item.playback.canSeek else { return }
            switch direction {
            case .increment: controller.perform(.seek(currentTime + 5), for: item, from: surface)
            case .decrement: controller.perform(.seek(currentTime - 5), for: item, from: surface)
            @unknown default: break
            }
        }
    }

    private func siteIcon(_ item: SidebarMediaController.Item) -> some View {
        Group {
            if let data = item.faviconData, let image = NSImage(data: data) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "waveform")
                    .resizable().aspectRatio(contentMode: .fit)
                    .foregroundStyle(secondary)
            }
        }
        .frame(width: 18, height: 18)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func playPauseButton(_ item: SidebarMediaController.Item) -> some View {
        let button = Button {
            controller.perform(.playPause, for: item, from: surface)
        } label: {
            Image(systemName: item.playback.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(foreground)
                .frame(width: 28, height: 28)
        }
        .buttonStyle(SidebarMediaButtonStyle())
        .focusEffectDisabled()
        .disabled(!item.playback.canPlayPause)
        .focused($playPauseFocused)
        .help(item.playback.isPlaying ? pauseLabel : playLabel)
        .accessibilityLabel(item.playback.isPlaying ? pauseLabel : playLabel)
        .accessibilityIdentifier("sidebarMedia.playPause")
        button.accessibilityActions {
            if controller.backgroundSourceCount > 1 {
                Button(nextSourceLabel) { controller.cycleSource(for: item, from: surface) }
            }
            if controller.presentationMode == .dynamic {
                Button(showDetailsLabel) {
                    guard controller.matchesCurrentSource(item) else { return }
                    keyboardExpanded = true
                    setExpanded(true)
                }
            }
        }
    }

    private func controlButton(_ symbol: String, label: String, enabled: Bool,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(foreground)
                .frame(width: 22, height: 22)
        }
        .buttonStyle(SidebarMediaButtonStyle())
        .focusEffectDisabled()
        .disabled(!enabled)
        .help(label)
        .accessibilityLabel(label)
    }

    private func setExpanded(_ expanded: Bool) {
        guard controller.isExpanded != expanded else { return }
        controller.setExpanded(expanded, on: surface)
        if expanded && keyboardExpanded {
            DispatchQueue.main.async { playPauseFocused = true }
        }
    }

    private func scheduleHoverCollapse() {
        guard controller.presentationMode == .dynamic else { return }
        hoverExitWorkItem?.cancel()
        let task = DispatchWorkItem {
            hoverExitWorkItem = nil
            if controller.presentationMode == .dynamic,
               !keyboardExpanded && scrubTarget == nil && !isHovering {
                setExpanded(false)
            }
        }
        hoverExitWorkItem = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: task)
    }

    private func collapse() {
        controller.setHovering(false, on: surface)
        hoverExitWorkItem?.cancel()
        hoverExitWorkItem = nil
        keyboardExpanded = false
        setExpanded(false)
    }

    static func timeString(_ seconds: Double) -> String {
        let safeSeconds = seconds.isFinite ? min(max(0, seconds), Double(Int.max / 2)) : 0
        let whole = Int(safeSeconds)
        let minutes = whole / 60
        let remainder = whole % 60
        if minutes >= 60 {
            let minutePart = minutes % 60
            return "\(minutes / 60):\(minutePart < 10 ? "0" : "")\(minutePart):\(remainder < 10 ? "0" : "")\(remainder)"
        }
        return "\(minutes):\(remainder < 10 ? "0" : "")\(remainder)"
    }

    private var fallbackTitle: String {
        NSLocalizedString("sidebar.media.untitled", value: "Media",
                          comment: "Sidebar media player - Fallback title when the page and media session have no title")
    }
    private var nextSourceLabel: String {
        NSLocalizedString("sidebar.media.nextSource", value: "Next media source",
                          comment: "Sidebar media accessibility action - Cycle to the next background media tab without changing playback or tab focus")
    }
    private var dismissLabel: String {
        NSLocalizedString("sidebar.media.dismiss", value: "Dismiss media player",
                          comment: "Sidebar media player - Hide this media source without changing playback")
    }
    private var showDetailsLabel: String {
        NSLocalizedString("sidebar.media.showDetails", value: "Show media details",
                          comment: "Sidebar media player - VoiceOver action to reveal metadata and seeking controls without pointer hover")
    }
    private var progressLabel: String {
        NSLocalizedString("sidebar.media.progress", value: "Playback position",
                          comment: "Sidebar media player - Accessible label for the seek timeline")
    }
    private var progressValueFormat: String {
        NSLocalizedString("sidebar.media.progressValue", value: "%1$@ of %2$@",
                          comment: "Sidebar media player - Accessible playback position; first time is elapsed, second time is total duration")
    }
    private var mutedStatusLabel: String {
        NSLocalizedString("sidebar.media.mutedStatus", value: "Muted",
                          comment: "Sidebar media player - Accessible status when the source tab is muted")
    }
    private var unmutedStatusLabel: String {
        NSLocalizedString("sidebar.media.unmutedStatus", value: "Unmuted",
                          comment: "Sidebar media player - Accessible status when the source tab is not muted")
    }
    private var volumeLabel: String {
        NSLocalizedString("sidebar.media.volumeButton", value: "Volume (⌥-click to toggle mute)",
                          comment: "Sidebar media player - Open volume slider; Option-click toggles tab mute")
    }
    private var volumeSliderLabel: String {
        NSLocalizedString("sidebar.media.volumeSlider", value: "Playback volume",
                          comment: "Sidebar media player - Adjust the tab playback volume from zero to one hundred percent")
    }
    private var previousTrackLabel: String {
        NSLocalizedString("sidebar.media.previousTrack", value: "Previous track",
                          comment: "Sidebar media player - Play the previous track in the page queue")
    }
    private var nextTrackLabel: String {
        NSLocalizedString("sidebar.media.nextTrack", value: "Next track",
                          comment: "Sidebar media player - Play the next track in the page queue")
    }
    private var pauseLabel: String {
        NSLocalizedString("sidebar.media.pause", value: "Pause",
                          comment: "Sidebar media player - Pause the current page media")
    }
    private var playLabel: String {
        NSLocalizedString("sidebar.media.play", value: "Play",
                          comment: "Sidebar media player - Resume the current page media")
    }
    private var openTabLabel: String {
        NSLocalizedString("sidebar.media.openTab", value: "Show playing tab",
                          comment: "Sidebar media player - Switch to the tab that owns the media")
    }
    private var muteLabel: String {
        NSLocalizedString("sidebar.media.mute", value: "Mute tab",
                          comment: "Sidebar media player - Mute the tab that owns the media")
    }
    private var unmuteLabel: String {
        NSLocalizedString("sidebar.media.unmute", value: "Unmute tab",
                          comment: "Sidebar media player - Unmute the tab that owns the media")
    }
    private var enterPictureInPictureLabel: String {
        NSLocalizedString("sidebar.media.enterPictureInPicture",
                          value: "Open picture in picture",
                          comment: "Sidebar media player - Pop the playing video into a floating picture-in-picture window")
    }
    private var exitPictureInPictureLabel: String {
        NSLocalizedString("sidebar.media.exitPictureInPicture",
                          value: "Close picture in picture",
                          comment: "Sidebar media player - Return a picture-in-picture video to its page")
    }
}
