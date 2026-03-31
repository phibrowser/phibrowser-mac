// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

struct ExtensionMessageContext {
    let type: String
    let payload: String
    let requestId: String
}

typealias ExtensionMessageHandler = (ExtensionMessageContext) -> String?

final class ExtensionMessageRouter {
    static let shared = ExtensionMessageRouter()

    private var handlers: [String: ExtensionMessageHandler] = [:]
    private var configured = false

    func register(type: String, handler: @escaping ExtensionMessageHandler) {
        handlers[type] = handler
    }

    func handle(type: String, payload: String, requestId: String) -> String? {
        configureIfNeeded()
        let context = ExtensionMessageContext(type: type, payload: payload, requestId: requestId)
        if let handler = handlers[type] {
            return handler(context)
        }
        return CommonMessageRouter.shared.handle(context)
    }

    private func configureIfNeeded() {
        guard !configured else { return }
        configured = true

        register(type: "notification") { context in
            NotificationCardManager.shared.handleRequest(context: context)
            return nil
        }

        register(type: "imagePreview") { context in
            ImagePreviewMessageHandler.handle(context)
            return nil
        }

        register(type: "showDialog") { context in
            ExtensionDialogManager.shared.handleRequest(context: context)
            return nil
        }
    }
}
