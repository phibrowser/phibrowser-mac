// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import UniformTypeIdentifiers

enum ReaderExportError: Error {
    case noTarget
    case transportUnavailable
    case captureFailed
}

/// Saves what the reader is showing, as a single file.
///
/// Two exports, because the reader is a view of a page rather than a
/// replacement for it: the distilled article, and the page it came from. Both
/// are self-contained — an export that still needs the network to render is
/// not really a saved copy.
@MainActor
enum ReaderExportService {

    /// MHTML has no system-declared type, so it is described by extension.
    /// Falling back to `.data` keeps the save panel usable rather than
    /// refusing the export outright.
    static let mhtmlType = UTType(filenameExtension: "mhtml") ?? .data

    /// The live page as MHTML: markup and every subresource in one file, which
    /// is Chromium's own complete-page format. Captured over the app's CDP
    /// session, the same transport extraction uses, so this needs nothing new
    /// from the framework.
    static func captureOriginalPage(tab: Tab) async throws -> Data {
        guard let wrapper = tab.webContentWrapper,
              let targetId = wrapper.devToolsTargetId,
              !targetId.isEmpty else {
            throw ReaderExportError.noTarget
        }

        let session: AppDevToolsPageSession
        do {
            session = try await AppDevToolsPageSession.open(targetId: targetId)
        } catch {
            throw ReaderExportError.transportUnavailable
        }
        defer { session.close() }

        // A large page with many subresources takes a while to serialise.
        let reply = try? await session.command("Page.captureSnapshot",
                                               params: ["format": "mhtml"],
                                               timeout: 60)
        guard let text = reply?["data"] as? String,
              let data = text.data(using: .utf8), !data.isEmpty else {
            throw ReaderExportError.captureFailed
        }
        return data
    }

    /// The distilled article as one HTML file.
    ///
    /// The same document the reader renders, minus the copy controls — their
    /// links are handled by the app and would be dead in a saved file — and
    /// with images inlined so it opens without the network.
    /// - Parameter inlineImages: false leaves images as origin URLs. Only the
    ///   agent API passes this, for a caller that wants the document without
    ///   carrying megabytes of base64 through the message channel; a saved file
    ///   always inlines, because a file that needs the network is not a copy.
    static func makeArticleDocument(article: ReaderArticle,
                                    style: ReaderStyle,
                                    appearanceIsDark: Bool,
                                    inlineImages: Bool = true) async -> Data {
        let document = ReaderDocumentBuilder.makeDocument(
            article: article,
            style: style,
            appearanceIsDark: appearanceIsDark)
        guard inlineImages else { return Data(document.utf8) }
        let inlined = await ReaderImageInliner().inlineImages(in: document)
        return Data(inlined.utf8)
    }

    /// A filename built from the article title.
    static func suggestedFileName(title: String, extension ext: String) -> String {
        "\(sanitizedBaseName(title: title)).\(ext)"
    }

    /// A filesystem-safe basename built from a title. Shared with Save for
    /// Later, whose file pair derives both names from one reserved basename.
    ///
    /// Path separators and the characters Finder and the common filesystems
    /// object to are replaced rather than stripped, so words do not run
    /// together, and the result is capped well under the 255-byte limit —
    /// which counts bytes, not characters, so a CJK title hits it far sooner.
    static func sanitizedBaseName(title: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:?%*|\"<>\u{0}")
            .union(.controlCharacters)
        let cleaned = title.components(separatedBy: forbidden).joined(separator: " ")
        let collapsed = cleaned
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Leading dots hide the file; an empty title would produce one.
        var base = collapsed.hasPrefix(".") ? String(collapsed.dropFirst()) : collapsed
        if base.isEmpty {
            base = NSLocalizedString(
                "browser.readerView.untitledArticle",
                value: "Article",
                comment: "Reader View - Fallback file name when an article has no title")
        }
        while base.utf8.count > 120, !base.isEmpty {
            base.removeLast()
        }
        return base
    }
}
