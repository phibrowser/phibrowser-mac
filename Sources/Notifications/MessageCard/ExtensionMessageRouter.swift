// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

struct ExtensionMessageContext {
    let type: String
    let payload: String
    let requestId: String
    /// The sender's extension id, or a synthetic id for non-extension origins
    /// ("cdp" for the PhiAgentSpace DevTools tunnel, "debug-extension" for the
    /// debug panel). Empty when the bridge didn't attribute a sender.
    let senderId: String
}

typealias ExtensionMessageHandler = (ExtensionMessageContext) -> String?

final class ExtensionMessageRouter {
    static let shared = ExtensionMessageRouter()

    private var handlers: [String: ExtensionMessageHandler] = [:]
    private var configured = false

    func register(type: String, handler: @escaping ExtensionMessageHandler) {
        handlers[type] = handler
    }

    func handle(type: String, payload: String, requestId: String, senderId: String = "") -> String? {
        configureIfNeeded()
        let context = ExtensionMessageContext(type: type, payload: payload, requestId: requestId, senderId: senderId)
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

        register(type: "getServiceExports") { context in
            Task {
                do {
                    let result = try await SentinelIPCClient.shared.getComponentExports()
                    await ExtensionMessaging.shared.sendResponse(result, requestId: context.requestId)
                } catch {
                    await ExtensionMessaging.shared.sendError(error.localizedDescription, requestId: context.requestId)
                }
            }
            return nil
        }

        register(type: "toggleAgentAnimation") { context in
            return AgentAnimationManager.shared.handleRequest(context: context)
        }

        register(type: "agentSpace.create") { context in
            AgentSpaceRouter.handleCreate(context: context)
            return nil  // async reply via ExtensionMessaging
        }
        register(type: "agentSpace.list") { context in
            return AgentSpaceRouter.handleList(context: context)
        }
        register(type: "agentSpace.listProfiles") { context in
            return AgentSpaceRouter.handleListProfiles(context: context)
        }
        register(type: "agentSpace.setState") { context in
            return AgentSpaceRouter.handleSetState(context: context)
        }
        register(type: "agentSpace.cursor") { context in
            return AgentSpaceRouter.handleCursor(context: context)
        }
        register(type: "agentSpace.markError") { context in
            return AgentSpaceRouter.handleMarkError(context: context)
        }
        register(type: "agentSpace.complete") { context in
            return AgentSpaceRouter.handleComplete(context: context)
        }
        register(type: "agentSpace.getOwnership") { context in
            return AgentSpaceRouter.handleGetOwnership(context: context)
        }
        register(type: "agentSpace.handoff") { context in
            return AgentSpaceRouter.handleHandoff(context: context)
        }
        register(type: "agentSpace.takeover") { context in
            return AgentSpaceRouter.handleTakeover(context: context)
        }
        register(type: "agentSpace.openTab") { context in
            return AgentSpaceRouter.handleOpenTab(context: context)
        }

        register(type: "farringdon.organizeDidFinish") { _ in
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .farringdonOrganizeDidFinish, object: nil)
            }
            return nil
        }
    }
}
