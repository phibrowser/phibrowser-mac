// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

#if DEBUG
import AppKit
import QuartzCore

/// Debug overlay reporting how well the main thread keeps up with the display.
///
/// A display link delivers one callback per refresh on the main run loop, so a
/// gap between callbacks is a frame the app could not commit (a commit hitch).
/// Render-server hitches and web content frames (GPU / renderer processes) are
/// not visible from here; use Instruments for those.
@MainActor
final class DebugFrameRateMonitor: NSObject {
    static let shared = DebugFrameRateMonitor()

    private static let panelSize = NSSize(width: 230, height: 22)
    private static let screenInset: CGFloat = 12
    private static let sampleWindow: CFTimeInterval = 1
    /// A gap this long is logged as a hitch.
    private static let hitchLogThreshold: CFTimeInterval = 0.05
    /// Longer gaps are a paused link (display sleep, screen lock), not a hitch.
    private static let discontinuityThreshold: CFTimeInterval = 5

    private(set) var isRunning = false
    private var panel: NSPanel?
    private var label: NSTextField?
    private var displayLink: CADisplayLink?

    private var lastTimestamp: CFTimeInterval?
    private var sampleStart: CFTimeInterval = 0
    private var frameCount = 0
    private var droppedCount = 0
    private var maxFrameInterval: CFTimeInterval = 0

    func toggle() {
        isRunning ? stop() : start()
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        let panel = makePanel()
        self.panel = panel
        positionPanel()
        panel.orderFrontRegardless()

        guard let contentView = panel.contentView else { return }
        let link = contentView.displayLink(target: self, selector: #selector(displayLinkFired(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link

        NotificationCenter.default.addObserver(self, selector: #selector(keyWindowChanged(_:)),
                                               name: NSWindow.didBecomeKeyNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyWindowChanged(_:)),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        AppLogDebug("[FrameRateMonitor] started")
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        displayLink?.invalidate()
        displayLink = nil
        NotificationCenter.default.removeObserver(self)
        panel?.orderOut(nil)
        panel = nil
        label = nil
        resetSample()
        AppLogDebug("[FrameRateMonitor] stopped")
    }

    @objc private func keyWindowChanged(_ notification: Notification) {
        positionPanel()
    }

    @objc private func displayLinkFired(_ link: CADisplayLink) {
        let now = link.timestamp
        let refreshInterval = link.targetTimestamp - link.timestamp
        defer { lastTimestamp = now }
        guard let last = lastTimestamp, refreshInterval > 0 else {
            sampleStart = now
            return
        }

        let gap = now - last
        if gap > Self.discontinuityThreshold {
            resetSample()
            sampleStart = now
            return
        }

        frameCount += 1
        maxFrameInterval = max(maxFrameInterval, gap)
        if gap > refreshInterval * 1.5 {
            let dropped = max(1, Int((gap / refreshInterval).rounded()) - 1)
            droppedCount += dropped
            if gap >= Self.hitchLogThreshold {
                AppLogDebug(String(format: "[FrameRateMonitor] hitch %.1f ms, %d frame(s) dropped",
                                   gap * 1000, dropped))
            }
        }

        let elapsed = now - sampleStart
        guard elapsed >= Self.sampleWindow else { return }
        render(fps: Double(frameCount) / elapsed)
        frameCount = 0
        droppedCount = 0
        maxFrameInterval = 0
        sampleStart = now
    }

    private func render(fps: Double) {
        guard let label else { return }
        let maxFPS = max(1, panel?.screen?.maximumFramesPerSecond ?? 60)
        label.stringValue = String(format: "%3.0f/%d fps · drop %d · max %.1f ms",
                                   fps, maxFPS, droppedCount, maxFrameInterval * 1000)
        let ratio = fps / Double(maxFPS)
        label.textColor = droppedCount == 0 && ratio >= 0.95 ? .systemGreen
            : ratio >= 0.75 ? .systemYellow
            : .systemRed
    }

    private func resetSample() {
        lastTimestamp = nil
        frameCount = 0
        droppedCount = 0
        maxFrameInterval = 0
    }

    private func positionPanel() {
        guard let panel,
              let screen = (NSApp.keyWindow ?? NSApp.mainWindow)?.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let origin = NSPoint(x: visible.maxX - Self.panelSize.width - Self.screenInset,
                             y: visible.minY + Self.screenInset)
        panel.setFrameOrigin(origin)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.panelSize),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let background = NSView(frame: NSRect(origin: .zero, size: Self.panelSize))
        background.wantsLayer = true
        background.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.75).cgColor
        background.layer?.cornerRadius = 6

        let label = NSTextField(labelWithString: "-- fps")
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        label.lineBreakMode = .byClipping
        label.frame = NSRect(x: 6, y: (Self.panelSize.height - 15) / 2,
                             width: Self.panelSize.width - 12, height: 15)
        background.addSubview(label)

        panel.contentView = background
        self.label = label
        return panel
    }
}
#endif
