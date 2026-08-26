import XCTest
import CryptoKit
@testable import Phi

final class PhiKeyCryptoTests: XCTestCase {
    func testHPKERoundTrip() throws {
        let ark = PhiKeyCrypto.generateARK()
        let device = PhiKeyCrypto.generateDeviceKeyPair()
        let arkBytes = ark.withUnsafeBytes { Data($0) }

        let envelope = try PhiKeyCrypto.sealToPublicKey(arkBytes, recipient: device.publicKey)
        XCTAssertEqual(envelope.first, 0x01)
        let opened = try PhiKeyCrypto.openWithPrivateKey(envelope, privateKey: device)
        XCTAssertEqual(opened, arkBytes)
    }

    func testHPKEWrongKeyFails() throws {
        let device = PhiKeyCrypto.generateDeviceKeyPair()
        let other = PhiKeyCrypto.generateDeviceKeyPair()
        let envelope = try PhiKeyCrypto.sealToPublicKey(Data("secret".utf8), recipient: device.publicKey)
        XCTAssertThrowsError(try PhiKeyCrypto.openWithPrivateKey(envelope, privateKey: other))
    }

    func testSymmetricRoundTripAndTamper() throws {
        let key = PhiKeyCrypto.generateARK()
        let envelope = try PhiKeyCrypto.sealWithSymmetric(Data("ark".utf8), key: key)
        XCTAssertEqual(try PhiKeyCrypto.openWithSymmetric(envelope, key: key), Data("ark".utf8))

        var tampered = envelope
        tampered[tampered.count - 1] ^= 0xFF
        XCTAssertThrowsError(try PhiKeyCrypto.openWithSymmetric(tampered, key: key))
    }

    func testDeriveRecoveryKeyIsDeterministic() {
        let entropy = Data(repeating: 7, count: 16)
        let salt = Data(repeating: 9, count: 16)
        let k1 = PhiKeyCrypto.deriveRecoveryKey(entropy: entropy, salt: salt)
        let k2 = PhiKeyCrypto.deriveRecoveryKey(entropy: entropy, salt: salt)
        XCTAssertEqual(k1, k2)
        let k3 = PhiKeyCrypto.deriveRecoveryKey(entropy: entropy, salt: Data(repeating: 1, count: 16))
        XCTAssertNotEqual(k1, k3)
    }

    func testBadVersionRejected() {
        let key = PhiKeyCrypto.generateARK()
        let envelope = try! PhiKeyCrypto.sealWithSymmetric(Data("x".utf8), key: key)
        var wrong = envelope
        wrong[0] = 0x02
        XCTAssertThrowsError(try PhiKeyCrypto.openWithSymmetric(wrong, key: key))
    }

    func testVerificationCodeIsDeterministic() {
        let pk = Data((0..<32).map { UInt8($0) })
        XCTAssertEqual(PhiKeyCrypto.verificationCode(forPublicKey: pk),
                       PhiKeyCrypto.verificationCode(forPublicKey: pk))
    }

    func testVerificationCodeFormat() {
        let code = PhiKeyCrypto.verificationCode(forPublicKey: Data((0..<32).map { UInt8($0) }))
        XCTAssertEqual(code.count, 9)
        XCTAssertEqual(Array(code)[4], "-")
        let alphabet = Set("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
        XCTAssertTrue(code.filter { $0 != "-" }.allSatisfy { alphabet.contains($0) })
    }

    func testDifferentKeysDifferentCodes() {
        let a = Data((0..<32).map { UInt8($0) })
        let b = Data((0..<32).map { UInt8($0 &+ 1) })
        XCTAssertNotEqual(PhiKeyCrypto.verificationCode(forPublicKey: a),
                          PhiKeyCrypto.verificationCode(forPublicKey: b))
    }
}
