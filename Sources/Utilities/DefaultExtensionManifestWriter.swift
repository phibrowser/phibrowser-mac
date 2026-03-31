// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
struct DefaultExtensionManifestWriter {
    enum Extension: CaseIterable {
        case onePassword, icloudPasswords
        
        var content: String {
            switch self {
            case .onePassword:
                return """
                    {
                      "name": "com.1password.1password",
                      "description": "1Password BrowserSupport",
                      "path": "/Applications/1Password.app/Contents/Library/LoginItems/1Password Browser Helper.app/Contents/MacOS/1Password-BrowserSupport",
                      "type": "stdio",
                      "allowed_origins": [
                        "chrome-extension://hjlinigoblmkhjejkmbegnoaljkphmgo/",
                        "chrome-extension://bkpbhnjcbehoklfkljkkbbmipaphipgl/",
                        "chrome-extension://gejiddohjgogedgjnonbofjigllpkmbf/",
                        "chrome-extension://khgocmkkpikpnmmkgmdnfckapcdkgfaf/",
                        "chrome-extension://aeblfdkhhhdcdjpifhhbdiojplfjncoa/",
                        "chrome-extension://dppgmdbiimibapkepcbdbmkaabgiofem/"
                      ]
                    }
                    """
            case .icloudPasswords:
                return """
                    {
                      "name": "com.apple.passwordmanager",
                      "description": "PasswordManagerBrowserExtensionHelper",
                      "path": "/System/Cryptexes/App/System/Library/CoreServices/PasswordManagerBrowserExtensionHelper.app/Contents/MacOS/PasswordManagerBrowserExtensionHelper",
                      "type": "stdio",
                      "allowed_origins": ["chrome-extension://pejdijmoenmkgeppbflobdenhhabjlaj/"]
                    }
                    """
            }
        }
        
        var fileName: String {
            switch self {
            case .onePassword:
                return "com.1password.1password.json"
            case .icloudPasswords:
                return "com.apple.passwordmanager.json"
            }
        }
    }
    static var running = false
    static func start() {
        guard !running else {
            return
        }
        
        running = true
        DispatchQueue.global(qos: .background).async {
            let writingDir = (FileSystemUtils.applicationSupportDirctory() as NSString)
                .appendingPathComponent("NativeMessagingHosts")
            let fileManager = FileManager.default
            try? fileManager.createDirectory(atPath: writingDir, withIntermediateDirectories: true)
            Extension.allCases.forEach { ext in
                let filePath = (writingDir as NSString).appendingPathComponent(ext.fileName)
                do {
                    try ext.content.write(toFile: filePath, atomically: true, encoding: .utf8)
                } catch {
                    AppLogError("Failed to write \(ext.fileName): \(error)")
                }
            }
            running = false
        }
    }
}
