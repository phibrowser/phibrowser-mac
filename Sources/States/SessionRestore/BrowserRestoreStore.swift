// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

final class BrowserRestoreStore {
    private let fileURL: URL
    
    init(account: Account) {
        let restoreDir = account.userDataStorage.appendingPathComponent("restore", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: restoreDir, withIntermediateDirectories: true)
        } catch {
            AppLogError("Failed to create restore directory: \(error.localizedDescription)")
        }
        self.fileURL = restoreDir.appendingPathComponent("browser_restore.json")
    }
    
    func load() -> BrowserRestoreState? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }
        do {
            let data = try Data(contentsOf: fileURL)
            return try JSONDecoder().decode(BrowserRestoreState.self, from: data)
        } catch {
            AppLogError("Failed to load browser restore state: \(error.localizedDescription)")
            return nil
        }
    }
    
    func save(_ state: BrowserRestoreState) {
        do {
            let data = try JSONEncoder().encode(state)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            AppLogError("Failed to save browser restore state: \(error.localizedDescription)")
        }
    }
    
    func clear() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch {
            AppLogError("Failed to clear browser restore state: \(error.localizedDescription)")
        }
    }
}
