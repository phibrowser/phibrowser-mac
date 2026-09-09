import XCTest
@testable import Phi

/// Source-level guard against `.textSelection(.enabled)` in the sync UI.
///
/// `.textSelection(.enabled)` backs a SwiftUI `Text` with an `NSTextView`. On
/// device this deadlocked the main thread: AppKit's mouse-tracking loop
/// (`-[NSTextView mouseDown:]`) drains main-actor continuations, so an async
/// phase change — or the Devices pane's 3-second poll — could tear the view and
/// its window down mid-drag. The tracking loop then spins forever waiting for a
/// mouse-up that can never reach a closed window (100% CPU on CrBrowserMain).
///
/// The tracking loop cannot be reproduced in a unit test, so this scans the
/// sync UI sources instead. Use non-selectable `Text` plus a Copy button.
final class SyncUITextSelectionTests: XCTestCase {
    private static let scannedDirectories = [
        "Sources/Sync/Keys/UI",
        "Sources/Sync/Phi/UI",
        "Sources/UserInterface/Preferences/Devices",
    ]

    func testSyncUIHasNoSelectableText() throws {
        let root = Self.repositoryRoot()
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: root.appendingPathComponent("Sources").path),
            "Could not locate the repository root from #filePath (looked at \(root.path)). "
            + "If this test moved, fix the number of deletingLastPathComponent() hops.")

        let needle = "textSelection(.enabled)"
        for directory in Self.scannedDirectories {
            let url = root.appendingPathComponent(directory)
            let files = try FileManager.default
                .contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "swift" }
            XCTAssertFalse(
                files.isEmpty,
                "\(directory) contains no .swift files — the guard is scanning nothing.")

            for file in files {
                let source = try String(contentsOf: file, encoding: .utf8)
                XCTAssertFalse(
                    source.contains(needle),
                    "\(directory)/\(file.lastPathComponent) uses .textSelection(.enabled). "
                    + "Selectable text in the sync UI installs an NSTextView whose AppKit "
                    + "mouse-tracking loop is orphaned when an async phase change or a poll "
                    + "removes the view mid-drag, hanging the main thread. "
                    + "Use a non-selectable Text plus a Copy button instead.")
            }
        }
    }

    /// `…/Tests/PhiBrowserTests/Sync/Keys/SyncUITextSelectionTests.swift` →
    /// repository root is five `deletingLastPathComponent()` hops up.
    private static func repositoryRoot() -> URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url = url.deletingLastPathComponent() }
        return url
    }
}
