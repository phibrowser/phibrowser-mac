// Copyright 2026 Phinomenon Inc.
// Use of this source code is governed by an Apache license in the LICENSE file.

import Foundation
import Markdown
import SwiftUI
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
        let document = FolioDocument(markdown: """
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
        let article = Document(parsing: document.article)
        let nodes = descendants(article)
        XCTAssertEqual((article.child(at: 0) as? Heading)?.level, 2)
        XCTAssertTrue(nodes.contains { $0 is CodeBlock })
        XCTAssertEqual(nodes.filter { $0 is ListItem }.count, 2)
        XCTAssertTrue(descendants(Document(parsing: document.highlights)).contains { $0 is BlockQuote })
        XCTAssertFalse(document.article.contains("personal note"))
        XCTAssertTrue(document.highlights.contains("personal note"))
        XCTAssertTrue(nodes.contains { $0 is Strong })
    }

    func testUnsafeLinksAreNotActionable() {
        for url in ["file:///etc/passwd", "javascript:alert(1)", "data:text/html,hello", "phi://settings", "https:relative"] {
            XCTAssertNil(FolioLibrary.webURL(url))
        }
        let document = FolioDocument(
            markdown: "[bad](file:///etc/passwd) and [good](/page) and [script](javascript:alert) and [upper](HTTPS://example.com/upper)",
            source: URL(string: "https://example.com"))
        let links = descendants(Document(parsing: document.article)).compactMap { ($0 as? Markdown.Link)?.destination }
        XCTAssertEqual(links, ["https://example.com/page", "https://example.com/upper"])
        XCTAssertTrue(document.article.contains("bad"))
    }

    func testHighlightHeadingInsideCodeOrQuoteDoesNotSplitTheArticle() {
        let document = FolioDocument(markdown: "# Title\n\n```markdown\n## Highlights\n```\n\n> ## Highlights\n\nStill the article.", source: nil)
        XCTAssertTrue(document.highlights.isEmpty)
        XCTAssertTrue(descendants(Document(parsing: document.article)).contains {
            ($0 as? CodeBlock)?.code.contains("Highlights") == true
        })
        XCTAssertTrue(document.article.contains("Still the article."))
        XCTAssertTrue(FolioDocument(markdown: "# Title", source: nil).article.isEmpty)
    }

    func testMarkdownTableRetainsRowsAndInlineFormatting() throws {
        let document = FolioDocument(markdown: "| Name | Value |\n| --- | --- |\n| **Alpha** | 42 |\n| Beta | 7 |", source: nil)
        let table = try XCTUnwrap(Document(parsing: document.article).child(at: 0) as? Markdown.Table)
        XCTAssertEqual(Array(table.body.rows).count, 2)
        XCTAssertEqual(table.head.cells.map(\.plainText), ["Name", "Value"])
        XCTAssertTrue(descendants(table).contains { $0 is Strong })
    }

    func testSanitizationRemovesActiveContentButPreservesTextAndNestedLists() {
        let document = FolioDocument(markdown: """
        # Title

        <iframe src="https://example.com"></iframe>

        Keep <b>this text</b> and ![picture](https://example.com/tracker.svg).
        ![relative](../image.png) ![local](file:///tmp/image.png)

        - Parent
          - Nested **point**

        ```html
        <script>sample()</script>
        ```
        """, source: URL(string: "https://example.com/article"))
        let nodes = descendants(Document(parsing: document.article))
        XCTAssertFalse(nodes.contains { $0 is HTMLBlock || $0 is InlineHTML || $0 is Markdown.Image })
        XCTAssertTrue(document.article.contains("this text"))
        XCTAssertTrue(document.article.contains("picture"))
        XCTAssertEqual(nodes.filter { $0 is UnorderedList }.count, 2)
        XCTAssertTrue(nodes.contains { ($0 as? CodeBlock)?.code.contains("<script>") == true })
    }

    @MainActor
    func testReaderSelectsAndCopiesAcrossWrappedLinesAndParagraphs() async throws {
        let first = "First paragraph with enough words to wrap over several lines in a narrow reader."
        let last = "Last paragraph remains in the same selection."
        let view = FolioMarkdownView(markdown: first + "\n\n## A heading\n\nA [linked phrase](https://example.com).\n\n> Quoted passage.\n\n" + last,
                                     fontSize: 17, accent: .brown)
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        window.orderFront(nil)
        for _ in 0..<10 {
            host.layoutSubtreeIfNeeded()
            if textViews(in: host).first?.string.contains(last) == true { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let readers = textViews(in: host)
        XCTAssertEqual(readers.count, 1)
        let reader = try XCTUnwrap(readers.first)
        XCTAssertTrue(reader.isSelectable)
        XCTAssertFalse(reader.isEditable)
        let text = reader.string as NSString
        let start = text.range(of: "paragraph").location
        let end = NSMaxRange(text.range(of: "same selection"))
        let range = NSRange(location: start, length: end - start)
        reader.setSelectedRange(range)
        XCTAssertEqual(reader.selectedRange(), range)
        let copied = try XCTUnwrap(reader.attributedSubstring(forProposedRange: reader.selectedRange(), actualRange: nil))
        XCTAssertTrue(copied.string.contains("A heading"))
        XCTAssertTrue(copied.string.contains("Last paragraph"))
        XCTAssertTrue(copied.string.contains("linked phrase"))
        XCTAssertTrue(copied.string.contains("Quoted passage."))
        XCTAssertTrue(copied.string.hasPrefix("paragraph"))
        XCTAssertTrue(copied.string.hasSuffix("same selection"))
        let firstRect = reader.firstRect(forCharacterRange: NSRange(location: start, length: 1), actualRange: nil)
        let lastRect = reader.firstRect(forCharacterRange: NSRange(location: end - 1, length: 1), actualRange: nil)
        XCTAssertNotEqual(firstRect.minY, lastRect.minY)
    }

    private func descendants(_ markup: Markup) -> [Markup] {
        [markup] + markup.children.flatMap { descendants($0) }
    }

    @MainActor
    private func textViews(in view: NSView) -> [NSTextView] {
        (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap { textViews(in: $0) }
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
        XCTAssertEqual(model.document?.article, "A video summary.")
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
