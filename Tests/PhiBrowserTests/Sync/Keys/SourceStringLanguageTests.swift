import XCTest
@testable import Phi

/// CJK base strings are forbidden in Sources (§7.3): the catalog sourceLanguage is en
/// and keys are English source text, so a Chinese base string cannot be cataloged or translated.
///
/// This guard checks literals extracted as keys and visible bare Preview literals.
/// It skips comments and documentation comments; repository comment-language rules apply separately.
final class SourceStringLanguageTests: XCTestCase {
    /// U+4E00–U+9FFF unified ideographs, U+3000–U+303F CJK punctuation, U+FF00–U+FFEF fullwidth forms.
    private static let cjkRanges: [ClosedRange<UInt32>] = [
        0x4E00...0x9FFF, 0x3000...0x303F, 0xFF00...0xFFEF
    ]

    func testNoSourceFileCarriesACJKBaseString() throws {
        let root = Self.repositoryRoot()
        let sources = root.appendingPathComponent("Sources")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: sources.path),
            "Could not locate the repository root from #filePath (looked at \(root.path)). "
            + "If this test moved, fix the number of deletingLastPathComponent() hops.")

        var offenders: [String] = []
        let enumerator = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let source = try String(contentsOf: url, encoding: .utf8)
            let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
            for (index, line) in lines.enumerated() {
                let code = Self.strippingComments(String(line))
                guard code.unicodeScalars.contains(where: Self.isCJK) else { continue }
                offenders.append("\(url.lastPathComponent):\(index + 1): "
                                 + line.trimmingCharacters(in: .whitespaces))
            }
        }
        XCTAssertTrue(offenders.isEmpty, """
            Base strings must be English; Localizable.xcstrings has sourceLanguage en:
            \(offenders.joined(separator: "\n"))
            """)
    }

    /// Ignore trailing comments as well as whole comment lines. A line-prefix-only
    /// filter incorrectly treats CJK in an inline comment as a base-string violation,
    /// failing unrelated changes. This scanner targets string language, not comment language.
    /// Known deliberate simplification: block comments are treated as code; the repository
    /// does not use them for CJK comments.
    private static func strippingComments(_ line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("//") || trimmed.hasPrefix("*") { return "" }
        var out = ""
        var inString = false
        var escaped = false
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            let next = line.index(after: index)
            if escaped {
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" {
                inString.toggle()
            } else if !inString, character == "/", next < line.endIndex, line[next] == "/" {
                break   // An inline comment starts here
            }
            out.append(character)
            index = next
        }
        return out
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        cjkRanges.contains { $0.contains(scalar.value) }
    }

    /// Five deletingLastPathComponent() calls reach the repository root from
    /// Tests/PhiBrowserTests/Sync/Keys/SourceStringLanguageTests.swift, as in SyncUITextSelectionTests.
    private static func repositoryRoot() -> URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url = url.deletingLastPathComponent() }
        return url
    }
}
