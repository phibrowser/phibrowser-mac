import CryptoKit
import Foundation
import SwiftProtobuf

/// Encodes/decodes a `Phi_PhiEntity` (the plaintext phi payload schema) to/from
/// the AES-GCM ciphertext bytes stored in `SyncPb_PhiSpecifics.ciphertext`
/// (EntitySpecifics field 2000). Sealing/opening is done with the Phi domain
/// key via `PhiKeyCrypto`'s direct symmetric primitives -- no Nigori, and the
/// server only ever sees the resulting ciphertext.
enum PhiEntityCodec {
    static func encrypt(_ entity: Phi_PhiEntity, key: SymmetricKey) throws -> Data {
        try PhiKeyCrypto.sealWithSymmetric(try entity.serializedData(), key: key)
    }

    static func decrypt(_ ciphertext: Data, key: SymmetricKey) throws -> Phi_PhiEntity {
        try Phi_PhiEntity(serializedBytes: try PhiKeyCrypto.openWithSymmetric(ciphertext, key: key))
    }
}
