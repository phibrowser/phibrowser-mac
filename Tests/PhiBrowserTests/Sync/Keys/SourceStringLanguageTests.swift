import XCTest
@testable import Phi

/// **`Sources/**` 里不允许出现 CJK base 字符串**（§7.3）。目录的 `sourceLanguage`
/// 是 `en`，key 就是英文原文，所以一条中文 base 串既进不了目录、也没法被翻译。
///
/// **注释与文档注释里的中文照旧允许**——这条守卫管的是会被抽取成 key 的字符串字面量
/// （外加 `#Preview` 里那种不进目录但会上屏的裸字面量），不是注释语言。
final class SourceStringLanguageTests: XCTestCase {
    /// U+4E00–U+9FFF（统一表意文字）、U+3000–U+303F（CJK 标点）、U+FF00–U+FFEF（全角）。
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
            base 文案一律英文，Localizable.xcstrings 的 sourceLanguage 是 en：
            \(offenders.joined(separator: "\n"))
            """)
    }

    /// **必须能容忍行尾中文注释。** 只按行首前缀跳过是错的形状：本仓库的代码注释以
    /// 中文为主，第一条 `table.cursors[u] = cursor  // 按 syncUuid 键` 就会在一个与
    /// 文案毫无关系的 commit 上把守卫弄红——而本里程碑本身就要求写大量这种注释。
    ///
    /// 已知的刻意简化：`/* … */` 块注释按代码处理（本仓库不用它写中文注释）。
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
                break   // 行内注释从这里开始
            }
            out.append(character)
            index = next
        }
        return out
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        cjkRanges.contains { $0.contains(scalar.value) }
    }

    /// `…/Tests/PhiBrowserTests/Sync/Keys/SourceStringLanguageTests.swift` → 仓库根是
    /// 五个 `deletingLastPathComponent()`（与 `SyncUITextSelectionTests` 同款）。
    private static func repositoryRoot() -> URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url = url.deletingLastPathComponent() }
        return url
    }
}
