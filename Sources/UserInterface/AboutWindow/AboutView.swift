// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import SwiftUI

struct AboutView: View {
    private let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ??
                         Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Phi"

    private let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"

    private let buildNumber = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"

    private static let chromiumInfoKey = "Chromium version"
    private static let frameworkShortVersionKey = "CFBundleShortVersionString"

    private var currentYear: Int {
        Calendar.current.component(.year, from: Date())
    }

    private var chromiumVersion: String {
        #if DEBUG
        if let version = Self.chromiumVersionFromFramework() {
            return version
        }
        #endif

        if let version = Bundle.main.object(forInfoDictionaryKey: Self.chromiumInfoKey) as? String,
           !version.isEmpty {
            return version
        }

        return "Unknown"
    }

    private static func chromiumVersionFromFramework() -> String? {
        let frameworksURL = Bundle.main.privateFrameworksURL ??
            Bundle.main.bundleURL.appendingPathComponent("Contents/Frameworks")
        let infoPlistURL = frameworksURL.appendingPathComponent(
            "Phi Framework.framework/Versions/Current/Resources/Info.plist"
        )

        guard let info = NSDictionary(contentsOf: infoPlistURL) as? [String: Any],
              let version = info[frameworkShortVersionKey] as? String,
              !version.isEmpty else {
            return nil
        }

        return version
    }
    
    var body: some View {
        VStack {
            Spacer(minLength: 10)

            VStack(spacing: 10) {
                // App Icon
                Group {
                    if let appIcon = NSApp.applicationIconImage {
                        Image(nsImage: appIcon)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 58, height: 58)
                    } else {
                        Image(systemName: "app.fill")
                            .font(.system(size: 64))
                            .foregroundColor(.accentColor)
                            .frame(width: 48, height: 48)
                    }
                }
                .shadow(color: .black.opacity(0.2), radius: 10, x: 0, y: 5)

                Text(appName)
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundColor(.primary)
                
                VStack(spacing: 2) {
                    Text(String(format: NSLocalizedString("Version %@ (%@)", comment: "About window - App version and build number label"), appVersion, buildNumber))
                        .font(.system(size: 10))
                        .foregroundColor(Color(NSColor.labelColor))

                    Text(String(format: NSLocalizedString("Chromium Engine Version %@", comment: "About window - Chromium engine version label"), chromiumVersion))
                        .font(.system(size: 10))
                        .foregroundColor(Color(NSColor.labelColor))
                }

                VStack(spacing: 0) {
                    Text(String(format: NSLocalizedString("© %d Phinomenon. All rights reserved.", comment: "About window - Copyright notice at bottom"), currentYear))
                        .font(.caption)
                        .foregroundColor(Color(NSColor.labelColor))
                        .padding(.top, 5)
                }
            }

            Spacer(minLength: 20)
        }
        .padding(20)
        .frame(width: 290, height: 200)
        .background(Color(NSColor.windowBackgroundColor))
    }
}

#Preview {
    AboutView()
}
