// Copyright 2026 Phinomenon Inc.
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

/// Ranks Phi pins, bookmarks and commands with Chromium's results, in the Mac
/// omnibox and in the NTP search box. Chromium reads this through the bridge.
enum UnifiedOmnibox {
    #if NIGHTLY_BUILD
    // Plain Debug also defines NIGHTLY_BUILD, so canary is told by bundle ID.
    static let isEnabled = Bundle.main.bundleIdentifier == "com.phibrowser.canary.Mac"
    #else
    static let isEnabled = false
    #endif
}

extension PhiChromiumCoordinator {
    func isUnifiedOmniboxEnabled() -> Bool {
        UnifiedOmnibox.isEnabled
    }

    func advanceNativeOmniboxSession(_ sessionID: String, bindingToken: String,
                                    request: UInt64, windowId: Int64) -> Bool {
        guard Thread.isMainThread, let windowID = Int(exactly: windowId) else { return false }
        return MainActor.assumeIsolated {
            let advanced = SpaceSessionControllersManager.shared.controller(for: windowID)?
                .browserState.omniboxNativeSearchAdapter?.advance(
                    sessionID: sessionID, token: bindingToken, request: request) ?? false
            AppLogDebug("[OmniboxNative] advance request=\(request) ok=\(advanced)")
            return advanced
        }
    }

    func beginNativeOmniboxSession(_ sessionID: String, windowId: Int64,
                                  profileId: String, targetTabId: NSNumber?) -> String? {
        guard Thread.isMainThread, let windowID = Int(exactly: windowId), windowID > 0 else { return nil }
        return MainActor.assumeIsolated {
            guard let state = SpaceSessionControllersManager.shared.controller(for: windowID)?.browserState,
                  let adapter = state.omniboxSearchAdapterIfAvailable() else { return nil }
            let targetID: Int?
            if let targetTabId {
                guard targetTabId.int64Value > 0,
                      targetTabId == NSNumber(value: targetTabId.int64Value),
                      let exact = Int(exactly: targetTabId.int64Value) else { return nil }
                targetID = exact
            } else { targetID = nil }
            return adapter.beginSession(sessionID, profileID: profileId, targetID: targetID)?.token
        }
    }

    func queryNativeOmniboxSession(_ sessionID: String, bindingToken: String, request: UInt64,
                                  windowId: Int64, completion: @escaping (String?, String) -> Void) {
        guard Thread.isMainThread, let windowID = Int(exactly: windowId) else {
            completion(nil, "unavailable")
            return
        }
        MainActor.assumeIsolated {
            guard let adapter = SpaceSessionControllersManager.shared.controller(for: windowID)?
                .browserState.omniboxNativeSearchAdapter else {
                AppLogDebug("[OmniboxNative] query request=\(request) no adapter")
                completion(nil, "unavailable")
                return
            }
            let started = DispatchTime.now().uptimeNanoseconds
            adapter.query(sessionID: sessionID, token: bindingToken, request: request) { result in
                let elapsed = (DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
                switch result {
                case .success(let snapshot):
                    AppLogDebug("[OmniboxNative] query request=\(request) \(elapsed)ms " +
                        "bookmarks=\(snapshot.bookmarks.status.rawValue)/\(snapshot.bookmarks.entities.count) " +
                        "pins=\(snapshot.pins.status.rawValue)/\(snapshot.pins.entities.count)")
                case .failure(let error):
                    AppLogDebug("[OmniboxNative] query request=\(request) \(elapsed)ms failed=\(error)")
                }
                do {
                    let data = try result.get().encoded()
                    guard let json = String(data: data, encoding: .utf8) else {
                        completion(nil, "unavailable")
                        return
                    }
                    completion(json, "complete")
                } catch let error as OmniboxNativeQueryError {
                    switch error {
                    case .cancelled: completion(nil, "cancelled")
                    case .expired: completion(nil, "timeout")
                    default: completion(nil, "unavailable")
                    }
                } catch { completion(nil, "unavailable") }
            }
        }
    }

    func stopNativeOmniboxSession(_ sessionID: String, request: UInt64, windowId: Int64) {
        guard Thread.isMainThread, let windowID = Int(exactly: windowId) else { return }
        AppLogDebug("[OmniboxNative] stop request=\(request)")
        MainActor.assumeIsolated {
            SpaceSessionControllersManager.shared.controller(for: windowID)?
                .browserState.omniboxNativeSearchAdapter?.stop(sessionID: sessionID, request: request)
        }
    }

    func endNativeOmniboxSession(_ sessionID: String, windowId: Int64) {
        guard Thread.isMainThread, let windowID = Int(exactly: windowId) else { return }
        MainActor.assumeIsolated {
            SpaceSessionControllersManager.shared.controller(for: windowID)?
                .browserState.omniboxNativeSearchAdapter?.endSession(sessionID)
        }
    }

    func recordOrdinaryOmniboxChoice(_ sessionID: String, bindingToken: String, request: UInt64,
                                     windowId: Int64, learningText: String) {
        guard Thread.isMainThread, let windowID = Int(exactly: windowId), learningText.utf8.count <= 256 else { return }
        MainActor.assumeIsolated {
            SpaceSessionControllersManager.shared.controller(for: windowID)?
                .browserState.omniboxNativeSearchAdapter?.recordOrdinaryChoice(
                    sessionID: sessionID, token: bindingToken, request: request, learningText: learningText)
        }
    }

    func omniboxHistoryDeleted(profileId: String, begin: Double, end: Double) {
        guard Thread.isMainThread, begin <= end else { return }
        MainActor.assumeIsolated {
            guard let account = AccountController.shared.localDataAccount else { return }
            OmniboxLearningStore.store(directory: account.userDataStorage, profileID: profileId)
                .removeEntries(lastUsedFrom: begin, to: end)
        }
    }

    func executeNativeOmniboxCommand(_ sessionID: String, bindingToken: String, request: UInt64,
                                     windowId: Int64, commandId: String,
                                     completion: @escaping (String) -> Void) {
        guard Thread.isMainThread, let windowID = Int(exactly: windowId) else {
            completion("stale")
            return
        }
        MainActor.assumeIsolated {
            let status = SpaceSessionControllersManager.shared.controller(for: windowID)?
                .browserState.omniboxNativeSearchAdapter?.executeCommand(
                    sessionID: sessionID, token: bindingToken, request: request, commandID: commandId) ?? "stale"
            AppLogDebug("[OmniboxNative] command request=\(request) id=\(commandId) status=\(status)")
            completion(status)
        }
    }

    func executeNativeOmniboxSession(_ sessionID: String, bindingToken: String, request: UInt64,
                                    windowId: Int64, frozenEntityJSON: String,
                                    mutationEpoch: String, pinScope: String, learningText: String,
                                    completion: @escaping (String, String?) -> Void) {
        guard Thread.isMainThread, let windowID = Int(exactly: windowId),
              frozenEntityJSON.utf8.count <= 512 * 1024, learningText.utf8.count <= 256,
              mutationEpoch.utf8.count <= 20, UInt64(mutationEpoch) != nil,
              pinScope.utf8.count <= 32,
              let data = frozenEntityJSON.data(using: .utf8),
              let entity = try? JSONDecoder().decode(OmniboxNativeEntity.self, from: data) else {
            AppLogDebug("[OmniboxNative] execute request=\(request) rejected: invalid payload")
            completion("stale", nil)
            return
        }
        AppLogDebug("[OmniboxNative] execute request=\(request) kind=\(entity.kind.rawValue) id=\(entity.entityID)")
        MainActor.assumeIsolated {
            guard let adapter = SpaceSessionControllersManager.shared.controller(for: windowID)?
                .browserState.omniboxNativeSearchAdapter else {
                AppLogDebug("[OmniboxNative] execute request=\(request) rejected: no adapter")
                completion("stale", nil)
                return
            }
            Task { @MainActor in
                let effect = await adapter.execute(sessionID: sessionID, token: bindingToken,
                    request: request, entity: entity, expectedEpoch: mutationEpoch,
                    expectedPinScope: pinScope, learningText: learningText)
                AppLogDebug("[OmniboxNative] execute request=\(request) effect=\(effect?.rawValue ?? "nil")")
                completion(effect == nil ? "stale" : "accepted", effect?.rawValue)
            }
        }
    }
}
