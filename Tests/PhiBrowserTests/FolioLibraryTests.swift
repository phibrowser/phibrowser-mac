// Copyright 2026 Phinomenon Inc.
// Use of this source code is governed by an Apache license in the LICENSE file.

import Foundation
import XCTest
@testable import Phi

final class FolioLibraryTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("FolioTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: folder) }

    private func write(_ name: String, _ text: String) throws {
        try text.write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    func testMirageFrontmatterPreservesQuotedTitlesAndURLColons() {
        let parsed = FolioLibrary.frontmatter(#"""
        ---
        title: "A \"quote\": C:\\notes"
        source: https://example.com/read?q=a:b
        type: video
        ---

        # A title

        Body
        """#)
        XCTAssertEqual(parsed.fields["title"], "A \"quote\": C:\\notes")
        XCTAssertEqual(parsed.fields["source"], "https://example.com/read?q=a:b")
        XCTAssertEqual(parsed.fields["type"], "video")
        XCTAssertEqual(parsed.body, "# A title\n\nBody")
    }

    func testMalformedFrontmatterDoesNotDiscardTheArticle() {
        let text = "---\ntitle: unfinished\n\nArticle text"
        XCTAssertEqual(FolioLibrary.frontmatter(text).body, text)
        XCTAssertTrue(FolioLibrary.frontmatter(text).fields.isEmpty)
        XCTAssertEqual(FolioLibrary.frontmatter("---\r\ntitle: Hello\r\n---\r\nBody").fields["title"], "Hello")
    }

    func testListingPairsArchivesAndKeepsProfileFoldersSeparate() throws {
        try write("Article.md", "---\ntitle: Read me\nsource: https://www.example.com/article\nsaved: 2026-09-17T10:00:00.000Z\n---\n\n# Read me\n\nBody")
        try write("Article.mhtml", "archive")
        try write("Video highlight.md", "---\ntype: video\n---\n\n# Video\n\n## Highlights\n\n### Highlight\n\n> A quote")
        try write("Orphan.mhtml", "archive")
        try write("Unrelated.txt", "ignore")
        let items = try FolioLibrary.list(folder: folder)
        XCTAssertEqual(items.count, 2)
        let article = try XCTUnwrap(items.first { $0.basename == "Article" })
        XCTAssertEqual(article.title, "Read me")
        XCTAssertEqual(article.domain, "example.com")
        XCTAssertTrue(article.hasWebpage)
        XCTAssertEqual(article.saved.timeIntervalSince1970, 1789639200, accuracy: 1)
        let video = try XCTUnwrap(items.first { $0.isVideo })
        XCTAssertTrue(video.hasHighlights)
        XCTAssertFalse(video.hasWebpage)
        let other = folder.appendingPathComponent("other-profile")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        XCTAssertTrue(try FolioLibrary.list(folder: other).isEmpty)
        XCTAssertEqual(try FolioLibrary.list(folder: folder, previous: items), items)
    }

    func testMissingFolderIsEmptyButAFileAtFolderPathIsAnError() throws {
        XCTAssertTrue(try FolioLibrary.list(folder: folder.appendingPathComponent("missing")).isEmpty)
        try write("not-a-folder", "contents")
        XCTAssertThrowsError(try FolioLibrary.list(folder: folder.appendingPathComponent("not-a-folder")))
    }

    func testNativeReaderRejectsSymlinksAndTraversal() throws {
        try write("real.md", "secret")
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("linked.md"),
                                                  withDestinationURL: folder.appendingPathComponent("real.md"))
        XCTAssertEqual(try FolioLibrary.list(folder: folder).map(\.basename), ["real"])
        XCTAssertThrowsError(try FolioLibrary.fileURL(basename: "linked", ext: "md", folder: folder))
        XCTAssertThrowsError(try FolioLibrary.fileURL(basename: "../real", ext: "md", folder: folder))
    }

    func testDocumentSeparatesHighlightsAndPreservesMarkdownStructure() throws {
        let document = try FolioDocument(markdown: """
        ---
        title: An article
        ---

        # An article

        ## The idea

        A **strong** opening and [a source](https://example.com).

        - First point
        - Second point

        ```swift
        let answer = 42
        ```

        ## Highlights

        ### Highlight

        > A passage to keep.

        A personal note.
        """, source: nil)
        XCTAssertEqual(document.blocks.first?.heading, 2)
        XCTAssertTrue(document.blocks.contains { $0.isCode })
        XCTAssertEqual(document.blocks.filter { $0.marker != nil }.count, 2)
        XCTAssertTrue(document.highlights.contains { $0.isQuote })
        XCTAssertFalse(document.blocks.contains { String($0.text.characters).contains("personal note") })
        XCTAssertTrue(document.highlights.contains { String($0.text.characters).contains("personal note") })
        XCTAssertTrue(document.blocks.flatMap { Array($0.text.runs) }.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
    }

    func testUnsafeLinksAreNotActionable() throws {
        for url in ["file:///etc/passwd", "javascript:alert(1)", "data:text/html,hello", "phi://settings", "https:relative"] {
            XCTAssertNil(FolioLibrary.webURL(url))
        }
        let document = try FolioDocument(markdown: "[bad](file:///etc/passwd) and [good](/page)", source: URL(string: "https://example.com"))
        let links = document.blocks.flatMap { $0.text.runs.compactMap(\.link) }
        XCTAssertEqual(links, [URL(string: "https://example.com/page")!])
    }

    func testHighlightHeadingInsideCodeDoesNotSplitTheArticle() throws {
        let document = try FolioDocument(markdown: "# Title\n\n```markdown\n## Highlights\n```\n\nStill the article.", source: nil)
        XCTAssertTrue(document.highlights.isEmpty)
        XCTAssertTrue(document.blocks.contains { $0.isCode && String($0.text.characters).contains("Highlights") })
        XCTAssertTrue(document.blocks.contains { String($0.text.characters) == "Still the article." })
        XCTAssertTrue(try FolioDocument(markdown: "# Title", source: nil).blocks.isEmpty)
    }

    func testMarkdownTableRetainsRowsAndInlineFormatting() throws {
        let document = try FolioDocument(markdown: "| Name | Value |\n| --- | --- |\n| **Alpha** | 42 |\n| Beta | 7 |", source: nil)
        XCTAssertEqual(document.blocks.count, 3)
        XCTAssertTrue(document.blocks[0].isTableHeader)
        XCTAssertEqual(document.blocks[0].cells?.map { String($0.characters) }, ["Name", "Value"])
        XCTAssertEqual(document.blocks[1].cells?.map { String($0.characters) }, ["Alpha", "42"])
    }

    func testListingRefreshesMetadataWhenFileChanges() throws {
        try write("Article.md", "---\ntitle: Before\n---\nBody")
        let previous = try FolioLibrary.list(folder: folder)
        try write("Article.md", "---\ntitle: After editing\n---\nA longer body")
        try write("Article.mhtml", "archive")
        let updated = try FolioLibrary.list(folder: folder, previous: previous)
        XCTAssertEqual(updated.first?.title, "After editing")
        XCTAssertEqual(updated.first?.hasWebpage, true)
    }

    @MainActor
    func testModelSearchFilterAndProfileFolderChangesKeepSelectionValid() async throws {
        let profile = "folio-test-" + UUID().uuidString
        PhiPreferences.SaveForLater.setFolderOverride(folder.path, forProfile: profile)
        defer { PhiPreferences.SaveForLater.setFolderOverride(nil, forProfile: profile) }
        try write("Article.md", "---\ntitle: A quiet morning\nsource: https://example.com\n---\n\n# A quiet morning\n\nAn article.")
        try write("Video.md", "---\ntitle: Creative work\ntype: video\n---\n\n# Creative work\n\nA video summary.")
        let model = FolioLibraryModel(profileId: profile)
        await model.refresh()
        XCTAssertEqual(model.items.count, 2)
        model.filter = .videos
        model.reconcileSelection()
        XCTAssertEqual(model.selectedItem?.basename, "Video")
        await model.readSelection()
        XCTAssertEqual(model.document?.blocks.first.map { String($0.text.characters) }, "A video summary.")
        model.filter = .all
        model.search = "EXAMPLE.COM"
        model.reconcileSelection()
        XCTAssertEqual(model.selectedItem?.basename, "Article")
        model.search = "no match"
        model.reconcileSelection()
        await model.readSelection()
        XCTAssertNil(model.selection)
        XCTAssertNil(model.document)
        let other = folder.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        PhiPreferences.SaveForLater.setFolderOverride(other.path, forProfile: profile)
        await model.refresh()
        XCTAssertEqual(model.folder, other)
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertNil(model.document)
    }
}
