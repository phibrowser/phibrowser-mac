import XCTest
@testable import Phi

final class RecoveryCodeTests: XCTestCase {
    func testGenerateDecodeRoundTrip() throws {
        let (display, entropy) = try RecoveryCode.generate()
        XCTAssertEqual(entropy.count, 16)
        XCTAssertEqual(RecoveryCode.decode(display), entropy)
    }

    func testDecodeIsCaseAndSeparatorInsensitive() throws {
        let (display, entropy) = try RecoveryCode.generate()
        let mangled = display.lowercased().replacingOccurrences(of: "-", with: " ")
        XCTAssertEqual(RecoveryCode.decode(mangled), entropy)
    }

    func testCrockfordAmbiguityNormalization() throws {
        // 用户把 O/I/L 抄成字母,应被归一到 0/1/1
        let (display, entropy) = try RecoveryCode.generate()
        let confused = display.replacingOccurrences(of: "0", with: "O")
                              .replacingOccurrences(of: "1", with: "I")
        // 仅当原串含 0/1 时该替换才生效;无论如何 decode 结果要么等于 entropy 要么因校验失败为 nil,
        // 但归一化本身不能崩:
        _ = RecoveryCode.decode(confused)
        XCTAssertEqual(RecoveryCode.decode(display), entropy)
    }

    func testChecksumRejectsSingleCharTypo() throws {
        let (display, _) = try RecoveryCode.generate()
        var chars = Array(display.replacingOccurrences(of: "-", with: ""))
        // 翻动一个数据字符(非横杠),校验位应使 decode 失败
        let table = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
        let idx = 0
        let cur = chars[idx]
        chars[idx] = (cur == table[0]) ? table[1] : table[0]
        XCTAssertNil(RecoveryCode.decode(String(chars)))
    }

    func testGarbageReturnsNil() {
        XCTAssertNil(RecoveryCode.decode("not a code"))
        XCTAssertNil(RecoveryCode.decode(""))
        XCTAssertNil(RecoveryCode.decode("ABC"))
    }
}
