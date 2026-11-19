// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
struct DefaultExtensionManifestWriter {
    enum Extension: CaseIterable {
        case onePassword, icloudPasswords
        /// Bitwarden's desktop app bridge, which the Bitwarden extension uses
        /// to unlock with Touch ID. The desktop app writes this manifest only
        /// into the browsers it knows; the content matches the one it writes
        /// for Chrome.
        case bitwarden
        
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
            case .bitwarden:
                return """
                    {
                      "name": "com.8bit.bitwarden",
                      "description": "Bitwarden desktop <-> browser bridge",
                      "path": "/Applications/Bitwarden.app/Contents/MacOS/desktop_proxy",
                      "type": "stdio",
                      "allowed_origins": [
                        "chrome-extension://nngceckbapebfimnlniiiahkandclblb/",
                        "chrome-extension://hccnnhgbibccigepcmlgppchkpfdophk/",
                        "chrome-extension://jbkfoedolllekgbhcbcoahefnbanhhlh/",
                        "chrome-extension://ccnckbpmaceehanjmeomladnmlffdjgn/"
                      ]
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
            case .bitwarden:
                return "com.8bit.bitwarden.json"
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

/// Chrome Web Store ids of well-known extensions. Single source of truth
/// shared by the OOBE password-manager screen, the per-new-profile
/// auto-install in `ProfileManager`, and the Profiles pane's password-manager
/// section.
enum PhiExtensionID {
    static let icloudPasswords = "pejdijmoenmkgeppbflobdenhhabjlaj"
    /// Chrome Web Store id of the Bitwarden Password Manager extension. Shared
    /// by the OOBE password-manager screen and the per-new-profile auto-install.
    static let bitwarden = "nngceckbapebfimnlniiiahkandclblb"
    static let onePassword = "aeblfdkhhhdcdjpifhhbdiojplfjncoa"
    static let lastPass = "hdokiejnpimakedhajhdlcegeplioahd"
    static let dashlane = "fdjamakpfbbddfjaooikfcpapjohcfmg"
    static let protonPass = "ghmbeldphafepmbegfdlkpapadhbakde"
    static let nordPass = "eiaeiblijfjekdanodkjadfinkhbfgcd"
    /// NordPass's previous store listing, now titled "NordPass (legacy)".
    /// Detection-only — installs use `nordPass`.
    static let nordPassLegacy = "fooolghllnmhmmndgjiamiiodkpenpbb"
    static let keeper = "bfogiafebfohielmmehodmfbbebbbpei"
    static let keePassXC = "oboonakemofpalcgghocfoadofidjkkk"
}
