// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

struct SystemUtils {

    private static let osVersion = ProcessInfo.processInfo.operatingSystemVersion

    static func isRunningOnOrLater(major: Int, minor: Int = 0, patch: Int = 0) -> Bool {
        let current = osVersion
        if current.majorVersion != major { return current.majorVersion > major }
        if current.minorVersion != minor { return current.minorVersion > minor }
        return current.patchVersion >= patch
    }

    static var osVersionString: String {
        "\(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)"
    }

    static var isMacOS26OrLater: Bool { isRunningOnOrLater(major: 26) }

    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    static var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
    }

    static var appVersionWithBuild: String {
        "\(appVersion) (\(buildNumber))"
    }

    static var modelIdentifier: String {
        var size: size_t = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &model, &size, nil, 0)
        return String(cString: model)
    }

    static var isAppleSilicon: Bool {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }

    static var physicalMemoryGB: Double {
        Double(ProcessInfo.processInfo.physicalMemory) / (1024 * 1024 * 1024)
    }

    static var processorCount: Int {
        ProcessInfo.processInfo.processorCount
    }
}
