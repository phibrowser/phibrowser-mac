// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import Combine
class OverlayWindowController: NSWindowController {
    private var eventMonitor: Any?
    private var cancellabls = Set<AnyCancellable>()
    
    init(contentView: NSView, parentWindow: NSWindow) {
        let overlayWindow = KeyableWindow(
            contentRect: .zero,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        
        super.init(window: overlayWindow)
        
        setupWindow(contentView: contentView, parentWindow: parentWindow)
        
        
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupWindow(contentView: NSView, parentWindow: NSWindow) {
        guard let window = window else { return }
        
        window.isOpaque = false
        window.backgroundColor = NSColor.clear
        window.hasShadow = true
        window.level = .floating
        window.isMovable = false
        

        contentView.frame = window.contentView?.bounds ?? NSRect.zero
        contentView.autoresizingMask = [.width, .height]
        
        let containerView = NSView(frame: window.contentView?.bounds ?? NSRect.zero)
        containerView.layer?.backgroundColor = .clear
        containerView.addSubview(contentView)
        
        window.contentView = containerView
        
        centerOnParentWindow(parentWindow)
        
        NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)
            .sink { [weak self] noti in
                guard (noti.object as? NSWindow) == self?.window else {
                    return
                }
                self?.closeWithAnimation()
            }
            .store(in: &cancellabls)
            
        
    }
    
    private func centerOnParentWindow(_ parentWindow: NSWindow) {
        guard let window = window else { return }
        
        let parentFrame = parentWindow.frame
        let windowSize = window.frame.size
        let centeredFrame = NSRect(
            x: parentFrame.midX - windowSize.width / 2,
            y: parentFrame.midY - windowSize.height / 2,
            width: windowSize.width,
            height: windowSize.height
        )
        
        window.setFrame(centeredFrame, display: false)
    }
    
    private func setupClickOutsideToClose() {
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let strongSelf = self, let window = strongSelf.window else { return event }
            if event.type == .keyDown, event.keyCode ==  53 {
                strongSelf.closeWithAnimation()
                return nil
            } else if event.type == .leftMouseDown || event.type == .rightMouseDown {
                let mouseLocation = NSEvent.mouseLocation
                let windowFrame = window.frame
                
                if !windowFrame.contains(mouseLocation) {
                    strongSelf.closeWithAnimation()
                    return nil
                }
                return event
            } else {
                return event
            }
        }
    }
    
    func showWithAnimation() {
        guard let window = window else { return }
        
        window.alphaValue = 0
        window.makeKeyAndOrderFront(nil)
        
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1.0
        }
        
        setupClickOutsideToClose()
    }
    
    func closeWithAnimation() {
        guard let window = window else { return }
        
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
        
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().alphaValue = 0
        }, completionHandler: {
            self.close()
        })
    }
    
    override func windowDidLoad() {
        super.windowDidLoad()
    }
    
    deinit {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}

// Allows the overlay to receive keyboard focus.
private class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool {
        return true
    }
    
    override var canBecomeMain: Bool {
        return true
    }
}
