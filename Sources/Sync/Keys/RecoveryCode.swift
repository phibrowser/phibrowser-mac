import CryptoKit
import Foundation

/// 恢复码 = 128-bit 随机熵,Base32-Crockford 编码 + 1 位校验字符,分组显示。
/// 高熵随机、非用户密码,因此无需 memory-hard KDF(派生见 PhiKeyCrypto.deriveRecoveryKey)。
enum RecoveryCode {
    static let entropyBytes = 16
    private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")  // Crockford,去 I L O U
    private static let dataChars = 26  // ceil(128/5)

    static func generate() -> (display: String, entropy: Data) {
        var entropy = Data(count: entropyBytes)
        _ = entropy.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, entropyBytes, $0.baseAddress!) }
        let body = encodeBase32(entropy, count: dataChars)
        let check = checksumChar(entropy)
        let full = body + String(check)
        return (group(full), entropy)
    }

    static func decode(_ input: String) -> Data? {
        let norm = normalize(input)
        guard norm.count == dataChars + 1 else { return nil }
        let chars = Array(norm)
        guard let entropy = decodeBase32(String(chars[0..<dataChars])) else { return nil }
        guard chars[dataChars] == checksumChar(entropy) else { return nil }
        return entropy
    }

    // --- helpers ---
    private static func normalize(_ s: String) -> String {
        String(s.uppercased().compactMap { ch -> Character? in
            switch ch {
            case "-", " ": return nil
            case "O": return "0"
            case "I", "L": return "1"
            case "U": return nil  // 非法字符,保留会导致长度不符 → nil
            default: return ch
            }
        })
    }

    private static func group(_ s: String) -> String {
        stride(from: 0, to: s.count, by: 5).map {
            String(Array(s)[$0..<min($0 + 5, s.count)])
        }.joined(separator: "-")
    }

    private static func encodeBase32(_ data: Data, count: Int) -> String {
        var bits = 0, value = 0, out = ""
        for byte in data {
            value = (value << 8) | Int(byte); bits += 8
            while bits >= 5 { out.append(alphabet[(value >> (bits - 5)) & 31]); bits -= 5 }
        }
        if bits > 0 { out.append(alphabet[(value << (5 - bits)) & 31]) }
        return String(out.prefix(count)).padding(toLength: count, withPad: "0", startingAt: 0)
    }

    private static func decodeBase32(_ s: String) -> Data? {
        var bits = 0, value = 0
        var out = Data()
        for ch in s {
            guard let idx = alphabet.firstIndex(of: ch) else { return nil }
            value = (value << 5) | idx; bits += 5
            if bits >= 8 { out.append(UInt8((value >> (bits - 8)) & 0xFF)); bits -= 8 }
        }
        return out.count >= entropyBytes ? out.prefix(entropyBytes) : nil
    }

    private static func checksumChar(_ entropy: Data) -> Character {
        let digest = SHA256.hash(data: entropy)
        return alphabet[Int(Array(digest)[0]) & 31]
    }
}
