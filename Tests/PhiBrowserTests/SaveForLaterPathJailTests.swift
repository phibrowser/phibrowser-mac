// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import XCTest
@testable import Phi

/// The Folio broker's jail. Mirage names files, the app decides what a legal
/// name in the destination folder is, and these two helpers are that whole
/// decision — so they are worth pinning down, in both directions: what they
/// must refuse, and what they must NOT refuse. The second half is not
/// paranoia. They once disagreed, and an ordinary title carrying an ellipsis
/// ("Wait... what?") saved fine and then could not be deleted or revealed,
/// because only one side treated ".." as a traversal attempt.
final class SaveForLaterPathJailTests: XCTestCase {
    private let folder = URL(fileURLWithPath: "/Users/x/Documents/PhiFolio",
                             isDirectory: true)

    // MARK: - What the jail refuses

    func testBrokerFileNameRefusesAnythingThatCouldLeaveTheFolder() {
        for name in [
            "../escape.md",
            "..\\escape.md",
            "sub/dir.md",
            "/etc/passwd.md",
            "a\u{0}b.md",
            ".hidden.md",
            "",
        ] {
            XCTAssertNil(SaveForLaterService.brokerFileName(name),
                         "should refuse \(name)")
        }
    }

    func testBrokerFileNameRefusesExtensionsFolioDoesNotWrite() {
        for name in ["notes.txt", "script.sh", "page.html", "archive.mhtml.zip",
                     "bare"] {
            XCTAssertNil(SaveForLaterService.brokerFileName(name),
                         "should refuse \(name)")
        }
    }

    func testLibraryFileURLRefusesTraversalInTheBasename() {
        for basename in ["../escape", "sub/dir", ".hidden", ""] {
            XCTAssertNil(
                SaveForLaterService.libraryFileURL(
                    basename: basename, ext: "md", folder: folder),
                "should refuse \(basename)")
        }
    }

    // MARK: - What the jail must let through

    func testOrdinaryNamesAreAccepted() {
        for name in ["2026-08-31 How to Do Great Work.md",
                     "2026-08-31 How to Do Great Work.mhtml",
                     "2026-08-31 深く考える技術.md",
                     "2026-08-31 A title with spaces 2.md"] {
            XCTAssertEqual(SaveForLaterService.brokerFileName(name), name)
        }
    }

    /// The regression: an ellipsis is punctuation, not a path.
    func testATitleWithAnEllipsisResolvesOnBothPaths() {
        let basename = "2026-08-31 Wait... what?"
        XCTAssertEqual(SaveForLaterService.brokerFileName(basename + ".md"),
                       basename + ".md")
        let url = SaveForLaterService.libraryFileURL(
            basename: basename, ext: "md", folder: folder)
        XCTAssertEqual(url?.lastPathComponent, basename + ".md")
        XCTAssertEqual(url?.deletingLastPathComponent().path, folder.path)
    }

    /// A title ending in a period is legal too — the extension trims it out
    /// of basenames, but a name that arrives with one must still resolve.
    func testATrailingPeriodIsAnOrdinaryName() {
        XCTAssertEqual(SaveForLaterService.brokerFileName("worth knowing..md"),
                       "worth knowing..md")
    }

    // MARK: - The two helpers agree

    func testBothHelpersAgreeOnEveryCandidate() {
        let candidates = [
            "Ordinary", "Wait... what?", "worth knowing.", "深く考える",
            "../escape", "sub/dir", ".hidden", "", "a\u{0}b", "trailing ",
        ]
        for basename in candidates {
            let brokerAccepts =
                SaveForLaterService.brokerFileName(basename + ".md") != nil
            let libraryAccepts = SaveForLaterService.libraryFileURL(
                basename: basename, ext: "md", folder: folder) != nil
            XCTAssertEqual(brokerAccepts, libraryAccepts,
                           "write and read disagree about \(basename)")
        }
    }

    /// Whatever it accepts must stay inside the folder once resolved.
    func testAcceptedNamesNeverEscapeTheFolder() {
        for basename in ["Ordinary", "Wait... what?", "worth knowing.",
                         "深く考える", "a.b.c"] {
            guard let url = SaveForLaterService.libraryFileURL(
                basename: basename, ext: "mhtml", folder: folder) else {
                continue
            }
            XCTAssertEqual(url.standardizedFileURL.deletingLastPathComponent()
                .standardizedFileURL.path, folder.path,
                "\(basename) resolved outside the folder")
        }
    }
}
