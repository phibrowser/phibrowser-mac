// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import Combine
import Foundation

final class WindowThemeMessageRouter {
    static let shared = WindowThemeMessageRouter()

    private struct RequestPayload: Decodable {
        let windowId: Int
    }

    private struct ThemePayload: Encodable {
        let name: String
        let windowBackground: ColorPayload
        let contentBackground: ColorPayload
        let accent: ColorPayload
        let actionAccent: ColorPayload
    }

    private struct ColorPayload: Encodable {
        let light: String
        let dark: String
    }

    private struct WindowThemePayload: Encodable {
        let windowId: Int
        let theme: ThemePayload
    }

    private let messenger: ExtensionMessagingProtocol
    private var subscriptions: [Int: AnyCancellable] = [:]

    init(messenger: ExtensionMessagingProtocol = ExtensionMessaging.shared) {
        self.messenger = messenger
    }

    func observeWindow(_ browserState: BrowserState) {
        let windowId = browserState.windowId
        guard subscriptions[windowId] == nil else { return }

        subscriptions[windowId] = browserState.themeContext.themePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak browserState] _ in
                guard let self, let browserState else { return }
                self.broadcastThemeChanged(for: browserState)
            }
    }

    func stopObservingWindow(windowId: Int) {
        subscriptions[windowId]?.cancel()
        subscriptions[windowId] = nil
    }

    func handleGetWindowTheme(_ context: ExtensionMessageContext) {
        guard let request = decodeRequest(context.payload) else {
            messenger.sendError("Invalid window theme request", requestId: context.requestId)
            return
        }

        guard let browserState = MainBrowserWindowControllersManager.shared.getBrowserState(for: request.windowId) else {
            messenger.sendError("Window not found", requestId: context.requestId)
            return
        }

        guard let json = encodeWindowTheme(for: browserState) else {
            messenger.sendError("Encode window theme failed", requestId: context.requestId)
            return
        }

        messenger.sendResponse(json, requestId: context.requestId)
    }

    private func broadcastThemeChanged(for browserState: BrowserState) {
        guard let json = encodeWindowTheme(for: browserState) else { return }
        messenger.broadcast(type: "windowThemechanged", payload: json)
    }

    private func decodeRequest(_ payload: String) -> RequestPayload? {
        guard let data = payload.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(RequestPayload.self, from: data)
    }

    private func encodeWindowTheme(for browserState: BrowserState) -> String? {
        let payload = WindowThemePayload(
            windowId: browserState.windowId,
            theme: makeThemePayload(from: browserState.themeContext.currentTheme)
        )
        guard let data = try? JSONEncoder().encode(payload) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func makeThemePayload(from theme: Theme) -> ThemePayload {
        ThemePayload(
            name: theme.name,
            windowBackground: colorPayload(for: .windowOverlayBackground, in: theme),
            contentBackground: colorPayload(for: .windowBackground, in: theme),
            accent: colorPayload(for: .themeColor, in: theme),
            actionAccent: colorPayload(for: .extensionActonColor, in: theme)
        )
    }

    private func colorPayload(for role: ColorRole, in theme: Theme) -> ColorPayload {
        ColorPayload(
            light: theme.color(for: role, appearance: .light).hexRGBString,
            dark: theme.color(for: role, appearance: .dark).hexRGBString
        )
    }
}

private extension NSColor {
    var hexRGBString: String {
        let color = usingColorSpace(.sRGB) ?? self
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)

        let r = Int(round(red * 255))
        let g = Int(round(green * 255))
        let b = Int(round(blue * 255))
        return String(format: "#%02x%02x%02x", r, g, b)
    }
}
