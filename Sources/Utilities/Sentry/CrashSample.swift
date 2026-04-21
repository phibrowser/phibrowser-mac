// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import SwiftUI

/// Enumerates crash scenarios that can be triggered to validate Sentry crash capture.
enum CrashScenario: String, CaseIterable, Identifiable {
    case fatalError = "fatalError(_:)"
    case forceUnwrapNil = "Force unwrap nil"
    case arrayOutOfBounds = "Array index out of range"
    case invalidCast = "Invalid type cast"
    case objectiveCException = "NSException"

    var id: String { rawValue }

    /// Human-readable title presented in the UI.
    var title: String { rawValue }

    /// Description of what the scenario does.
    var details: String {
        switch self {
        case .fatalError:
            return "Calls fatalError to crash immediately on the main thread."
        case .forceUnwrapNil:
            return "Force unwraps a nil optional to trigger a Swift trap."
        case .arrayOutOfBounds:
            return "Accesses an array index that is outside bounds."
        case .invalidCast:
            return "Performs an invalid downcast to crash at runtime."
        case .objectiveCException:
            return "Raises an Objective-C NSException."
        }
    }

    /// Executes the crash scenario.
    func trigger() {
        switch self {
        case .fatalError:
            Swift.fatalError("Sentry Crash Sample: fatalError triggered")
        case .forceUnwrapNil:
            let value: String? = nil
            _ = value!
        case .arrayOutOfBounds:
            let numbers = [0, 1, 2]
            _ = numbers[5]
        case .invalidCast:
            let value: Any = 42
            let stringValue = value as! String
            AppLogDebug(stringValue)
        case .objectiveCException:
            NSException(
                name: .invalidArgumentException,
                reason: "Sentry Crash Sample: Raised NSException",
                userInfo: nil
            ).raise()
        }
    }
}

/// Minimal SwiftUI view that lists crash scenarios with buttons to trigger them.
@MainActor
struct CrashSampleView: View {
    private let scenarios = CrashScenario.allCases

    var body: some View {
        List(scenarios) { scenario in
            Button {
                scenario.trigger()
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(scenario.title)
                        .font(.headline)
                    Text(scenario.details)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
            }
        }
        .navigationTitle("Crash Samples")
    }
}

#if DEBUG
struct CrashSampleView_Previews: PreviewProvider {
    static var previews: some View {
        CrashSampleView()
    }
}
#endif
