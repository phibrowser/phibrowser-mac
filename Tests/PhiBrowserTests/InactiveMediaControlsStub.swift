// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
@testable import Phi

final class InactiveMediaControlsStub: NSObject, PhiMediaControls {
    func startObserving(_ observer: @escaping ([String: Any]?) -> Void) {
        observer(nil)
    }

    func stopObserving() {}

    func snapshot() -> [String: Any]? { nil }

    func setVolume(_ volume: Double, expectedToken: String) -> Bool { false }

    func perform(_ action: PhiMediaControlAction, expectedToken: String, seconds: Double) -> Bool {
        false
    }
}
