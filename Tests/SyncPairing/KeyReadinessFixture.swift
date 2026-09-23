import Foundation

final class KeyReadinessFixture {
    var paired = false
    var resolved: [String: (uuid: String, passphrase: String)] = ["local": ("remote", "secret")]
    var isPairingComplete: () -> Bool { { [unowned self] in paired } }
    /* PRODUCTION_KEY_ACCESSOR */
}
