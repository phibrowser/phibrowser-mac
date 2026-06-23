// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

enum TimeMachineInstallerMainError: Error, LocalizedError {
    case missingValue(String)
    case invalidOperationID(String)
    case unsupportedArguments([String])

    var errorDescription: String? {
        switch self {
        case .missingValue(let flag):
            return "Missing value for \(flag)."
        case .invalidOperationID(let value):
            return "Invalid operation id \(value)."
        case .unsupportedArguments(let arguments):
            return "Unsupported Time Machine installer arguments: \(arguments.joined(separator: " "))."
        }
    }
}

do {
    try TimeMachineInstallerMain.run(arguments: Array(CommandLine.arguments.dropFirst()))
    exit(0)
} catch {
    let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    FileHandle.standardError.write(Data("PhiTimeMachineInstaller: \(message)\n".utf8))
    exit(1)
}

struct TimeMachineInstallerMain {
    static func run(arguments: [String]) throws {
        if let planPath = try value(after: "--plan", in: arguments) {
            let planURL = URL(fileURLWithPath: planPath, isDirectory: false)
            let plan = try TimeMachineInstallerCore.loadPlan(at: planURL)
            let paths = TimeMachinePaths(
                rootURL: TimeMachineInstallerCore.inferredRootURL(planURL: planURL),
                bundleIdentifier: plan.bundleIdentifier
            )
            try TimeMachineInstallerCore(paths: paths).restore(planURL: planURL)
            return
        }

        if arguments.contains("--time-machine-recover") {
            guard let operationIDValue = try value(after: "--operation-id", in: arguments) else {
                throw TimeMachineInstallerMainError.missingValue("--operation-id")
            }
            guard let operationID = UUID(uuidString: operationIDValue) else {
                throw TimeMachineInstallerMainError.invalidOperationID(operationIDValue)
            }
            guard let rootPath = try value(after: "--time-machine-root", in: arguments) else {
                throw TimeMachineInstallerMainError.missingValue("--time-machine-root")
            }

            let paths = TimeMachinePaths(rootURL: URL(fileURLWithPath: rootPath, isDirectory: true))
            try TimeMachineInstallerCore(paths: paths).recover(operationID: operationID)
            return
        }

        throw TimeMachineInstallerMainError.unsupportedArguments(arguments)
    }

    private static func value(after flag: String, in arguments: [String]) throws -> String? {
        guard let index = arguments.firstIndex(of: flag) else {
            return nil
        }
        let valueIndex = arguments.index(after: index)
        guard valueIndex < arguments.endIndex else {
            throw TimeMachineInstallerMainError.missingValue(flag)
        }
        return arguments[valueIndex]
    }
}
