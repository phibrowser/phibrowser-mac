// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
final class DefaultExtensionManifestWriter: NSObject {
    /// The framework's default-app provider only seeds fresh profiles. Its
    /// per-user external provider also upgrades CRXs in existing profiles.
    @objc(registerTrialExtensionsFromFramework:inUserDataDirectory:error:)
    static func registerTrialExtensions(framework: String, userDataDirectory: String) throws {
        #if ATHENA_CANARY_TRIAL
        let packages = URL(fileURLWithPath: framework, isDirectory: true)
            .appendingPathComponent("Versions/Current/Default Apps", isDirectory: true)
        let registry = URL(fileURLWithPath: userDataDirectory, isDirectory: true)
            .appendingPathComponent("External Extensions", isDirectory: true)
        let registrations = try PhiExtensionID.canaryManaged.map { id -> (URL, Data) in
            let name = id + ".json"
            let descriptor = try Data(contentsOf: packages.appendingPathComponent(name))
            guard var values = try JSONSerialization.jsonObject(with: descriptor) as? [String: String],
                  let filename = values["external_crx"], let version = values["external_version"],
                  filename.hasPrefix(id + "-" + version + "-"), filename.hasSuffix(".crx"),
                  !filename.contains("/"), values.count == 2 else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let crx = packages.appendingPathComponent(filename)
            guard FileManager.default.isReadableFile(atPath: crx.path) else {
                throw CocoaError(.fileReadNoSuchFile)
            }
            values["external_crx"] = crx.path
            let data = try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])
            return (registry.appendingPathComponent(name), data)
        }
        try FileManager.default.createDirectory(at: registry, withIntermediateDirectories: true)
        for (url, data) in registrations where (try? Data(contentsOf: url)) != data {
            try data.write(to: url, options: .atomic)
        }
        #endif
    }

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

/// Chrome Web Store ids of well-known extensions. Single source of truth
/// shared by the OOBE password-manager screen, the per-new-profile
/// auto-install in `ProfileManager`, and the Profiles pane's password-manager
/// section.
enum PhiExtensionID {
    static let canaryManaged = ["pjlnhbfabokjejbhmgghmjiaknfhnima",
                                  "pjgdkljlcbjgedgeppodjijjphfcplno",
                                  "fenmfiepnpdlhplemgijlimpbebebljo",
                                  "ickhcgejficcoofnjnnobadfdnfbilnm"]
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
