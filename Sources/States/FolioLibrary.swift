// Copyright 2026 Phinomenon Inc.
// Use of this source code is governed by an Apache license in the LICENSE file.

import Foundation
import Markdown
import Observation

struct FolioItem: Identifiable, Equatable, Sendable {
    var id: String { basename }
    let basename: String
    let title: String
    let source: String
    let site: String
    let isVideo: Bool
    let hasHighlights: Bool
    let hasWebpage: Bool
    let saved: Date
    let modified: Date
    let size: Int

    var sourceURL: URL? { FolioLibrary.webURL(source) }
    var domain: String { sourceURL?.host()?.replacingOccurrences(of: "www.", with: "") ?? site }
}

/// Reads the same flat Markdown/MHTML pairs that Mirage writes. No database or
/// second copy of the library is maintained by the native reader.
enum FolioLibrary {
    static func webURL(_ value: String) -> URL? {
        guard let url = URL(string: value),
              ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              url.host() != nil else { return nil }
        return url
    }

    static func frontmatter(_ text: String) -> (fields: [String: String], body: String) {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        guard lines.first == "---",
              let end = lines.dropFirst().firstIndex(of: "---") else {
            return ([:], normalized)
        }
        var fields: [String: String] = [:]
        for line in lines[1..<end] {
            guard let colon = line.firstIndex(of: ":") else { continue }
            var value = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.first == "\"", value.last == "\"" {
                value = String(value.dropFirst().dropLast())
                    .replacingOccurrences(of: "\\\"", with: "\"")
                    .replacingOccurrences(of: "\\\\", with: "\\")
            }
            fields[String(line[..<colon])] = value
        }
        return (fields, lines.dropFirst(end + 1).joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func fileURL(basename: String, ext: String, folder: URL) throws -> URL {
        guard let url = SaveForLaterService.libraryFileURL(basename: basename, ext: ext, folder: folder) else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        // Native reading must not follow a manually placed symlink outside the library.
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
        guard values.isSymbolicLink != true, values.isRegularFile == true else {
            throw CocoaError(.fileReadNoPermission)
        }
        return url
    }

    static func list(folder: URL, previous: [FolioItem] = []) throws -> [FolioItem] {
        let manager = FileManager.default
        let files: [URL]
        do {
            files = try manager.contentsOfDirectory(at: folder, includingPropertiesForKeys:
                [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles])
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return [] // The destination is only created by the first save.
        }
        let archives = Set(files.filter { $0.pathExtension == "mhtml" }.map { $0.deletingPathExtension().lastPathComponent })
        let cached = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })
        let dateParser = ISO8601DateFormatter()
        var items: [FolioItem] = []
        for url in files where url.pathExtension == "md" {
            let basename = url.deletingPathExtension().lastPathComponent
            guard SaveForLaterService.libraryFileURL(basename: basename, ext: "md", folder: folder) != nil else { continue }
            let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            let modified = values.contentModificationDate ?? .distantPast
            let size = values.fileSize ?? 0
            let hasWebpage = archives.contains(basename)
            if let item = cached[basename], item.modified == modified, item.size == size, item.hasWebpage == hasWebpage {
                items.append(item)
                continue
            }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let head = String(decoding: try handle.read(upToCount: 64 * 1024) ?? Data(), as: UTF8.self)
            let fields = frontmatter(head).fields
            let savedString = fields["saved"] ?? ""
            let saved = dateParser.date(from: savedString) ?? {
                dateParser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                defer { dateParser.formatOptions = [.withInternetDateTime] }
                return dateParser.date(from: savedString)
            }() ?? modified
            items.append(FolioItem(
                basename: basename, title: fields["title"].flatMap { $0.isEmpty ? nil : $0 } ?? basename,
                source: fields["source"] ?? "", site: fields["site"] ?? "",
                isVideo: fields["type"] == "video",
                hasHighlights: head.contains("\n## Highlights\n") || basename.range(of: #" highlight( \d+)?$"#, options: .regularExpression) != nil,
                hasWebpage: hasWebpage, saved: saved, modified: modified, size: size))
        }
        return items.sorted { $0.modified == $1.modified ? $0.id < $1.id : $0.modified > $1.modified }
    }

    static func read(item: FolioItem, folder: URL) throws -> FolioDocument {
        let url = try fileURL(basename: item.basename, ext: "md", folder: folder)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let limit = 16 * 1024 * 1024
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw CocoaError(.fileReadTooLarge) }
        return FolioDocument(markdown: String(decoding: data, as: UTF8.self), source: item.sourceURL)
    }

    static func trash(item: FolioItem, folder: URL) throws {
        // Move the copy first so a partial failure leaves a visible Markdown row.
        for ext in ["mhtml", "md"] {
            do {
                let url = try fileURL(basename: item.basename, ext: ext, folder: folder)
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                continue
            }
        }
    }
}

struct FolioDocument: Sendable {
    let article: String
    let highlights: String

    init(markdown: String, source: URL?) {
        let document = Document(parsing: FolioLibrary.frontmatter(markdown).body)
        var children = Array(document.blockChildren)
        if let heading = children.first as? Heading, heading.level == 1 {
            children.removeFirst()
        }
        // Split semantic headings only; fenced samples and nested quotes are content.
        let split = children.firstIndex {
            guard let heading = $0 as? Heading else { return false }
            return heading.level == 2 && heading.plainText == "Highlights"
        }
        var sanitizer = FolioMarkdownSanitizer(source: source)
        func sanitizedMarkdown(_ blocks: ArraySlice<BlockMarkup>) -> String {
            sanitizer.visit(Document(blocks))?.format()
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        article = sanitizedMarkdown(children[..<(split ?? children.endIndex)])
        highlights = split.map { sanitizedMarkdown(children[($0 + 1)...]) } ?? ""
    }
}

/// Preserve the native reader's passive-content policy before passing content to
/// MarkdownView, whose default HTML and image renderers can load web resources.
private struct FolioMarkdownSanitizer: MarkupRewriter {
    let source: URL?

    mutating func visitHTMLBlock(_ html: HTMLBlock) -> Markup? { nil }
    mutating func visitInlineHTML(_ html: InlineHTML) -> Markup? { nil }
    mutating func visitImage(_ image: Markdown.Image) -> Markup? {
        Markdown.Text(image.plainText)
    }

    mutating func visitLink(_ link: Markdown.Link) -> Markup? {
        guard var rewritten = defaultVisit(link) as? Markdown.Link else { return nil }
        let resolved = link.destination.flatMap { URL(string: $0, relativeTo: source)?.absoluteURL }
        let allowed = resolved.flatMap { FolioLibrary.webURL($0.absoluteString) }
        var components = allowed.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: true) }
        let scheme = components?.scheme?.lowercased()
        components?.scheme = scheme
        rewritten.destination = components?.url?.absoluteString
        return rewritten
    }
}

@MainActor @Observable
final class FolioLibraryModel {
    let profileId: String
    private(set) var folder: URL
    private(set) var items: [FolioItem] = []
    private(set) var document: FolioDocument?
    private(set) var isLoading = true
    private(set) var isReading = false
    var error: String?
    private(set) var loadError: String?
    var selection: String?
    var search = ""
    var filter: Filter = .all
    var oldestFirst = false
    private var refreshing = false
    private var readGeneration = 0

    enum Filter: CaseIterable { case all, articles, videos, highlights }

    init(profileId: String) {
        self.profileId = profileId
        folder = URL(fileURLWithPath: PhiPreferences.SaveForLater.effectiveFolderPath(forProfile: profileId), isDirectory: true)
    }

    var visibleItems: [FolioItem] {
        let filtered = items.filter { item in
            let matches: Bool
            switch filter {
            case .all: matches = true
            case .articles: matches = !item.isVideo
            case .videos: matches = item.isVideo
            case .highlights: matches = item.hasHighlights
            }
            let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
            return matches && (query.isEmpty || item.title.localizedStandardContains(query)
                || item.domain.localizedStandardContains(query) || item.site.localizedStandardContains(query))
        }
        return oldestFirst ? Array(filtered.reversed()) : filtered
    }

    var selectedItem: FolioItem? { items.first { $0.id == selection } }

    func reconcileSelection() {
        if !visibleItems.contains(where: { $0.id == selection }) { selection = visibleItems.first?.id }
    }

    func refresh() async {
        guard !refreshing else { return }
        guard SaveForLaterService.featureEnabled, !ApplicationState.shared.isGuest else {
            clear()
            return
        }
        refreshing = true
        defer { refreshing = false; isLoading = false }
        let resolved = URL(fileURLWithPath: PhiPreferences.SaveForLater.effectiveFolderPath(forProfile: profileId), isDirectory: true)
        if resolved != folder {
            clear()
            folder = resolved
        }
        let target = folder
        let previous = items
        do {
            let loaded = try await Task.detached(priority: .utility) { try FolioLibrary.list(folder: target, previous: previous) }.value
            guard !Task.isCancelled, SaveForLaterService.featureEnabled, !ApplicationState.shared.isGuest else { return }
            items = loaded
            loadError = nil
            reconcileSelection()
        } catch {
            if !Task.isCancelled { loadError = error.localizedDescription }
        }
    }

    func readSelection() async {
        readGeneration += 1
        let generation = readGeneration
        document = nil
        error = nil
        defer { if generation == readGeneration { isReading = false } }
        guard let item = selectedItem, SaveForLaterService.featureEnabled, !ApplicationState.shared.isGuest else {
            isReading = false
            return
        }
        isReading = true
        let target = folder
        do {
            let loaded = try await Task.detached(priority: .userInitiated) { try FolioLibrary.read(item: item, folder: target) }.value
            guard generation == readGeneration, selection == item.id, target == folder, !Task.isCancelled,
                  SaveForLaterService.featureEnabled, !ApplicationState.shared.isGuest else { return }
            document = loaded
            error = nil
        } catch {
            if generation == readGeneration { self.error = error.localizedDescription }
        }
    }

    func trash(_ item: FolioItem) async {
        guard SaveForLaterService.featureEnabled, !ApplicationState.shared.isGuest else { return }
        let target = folder
        do {
            try await Task.detached(priority: .utility) { try FolioLibrary.trash(item: item, folder: target) }.value
            await refresh()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func clear() {
        readGeneration += 1
        items = []
        selection = nil
        document = nil
        error = nil
        loadError = nil
        isReading = false
    }
}
