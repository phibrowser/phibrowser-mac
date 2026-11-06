// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import CryptoKit
import Foundation
import Network

/// Length-prefixed JSON messages over one TLS connection. Callbacks run on
/// the main queue.
final class AgentRemoteChannel {
    static let maxMessageBytes = 16 * 1024 * 1024

    let connection: NWConnection
    var onReady: (() -> Void)?
    var onMessage: ((AgentRemoteMessage) -> Void)?
    var onClose: (() -> Void)?
    private var closed = false

    init(_ connection: NWConnection) {
        self.connection = connection
    }

    /// TLS with a pre-shared key: a peer without the key fails the handshake.
    /// ponytail: TLS 1.2 PSK has no forward secrecy; move to TLS 1.3 PSK with
    /// (EC)DHE once Network.framework exposes it for PSK identities.
    static func parameters(key: SymmetricKey) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let psk = key.withUnsafeBytes { DispatchData(bytes: $0) }
        let identity = Data("phi-agent-presence".utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(
            tls.securityProtocolOptions, psk as __DispatchData, identity as __DispatchData)
        sec_protocol_options_append_tls_ciphersuite(
            tls.securityProtocolOptions,
            tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 5
        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.includePeerToPeer = true
        return parameters
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.onReady?()
                self?.receiveLength()
            case .failed(let error):
                AppLogInfo("[AgentRemote] connection failed: \(error)")
                self?.close()
            case .cancelled:
                self?.close()
            case .waiting(let error):
                // A PSK mismatch (another account) or an unreachable peer;
                // retrying would only repeat it.
                AppLogInfo("[AgentRemote] connection waiting: \(error)")
                self?.close()
            default:
                break
            }
        }
        connection.start(queue: .main)
    }

    /// `sent` fires once the bytes left this process, so a producer can keep
    /// at most one frame in flight instead of queueing behind a slow link.
    func send(_ message: AgentRemoteMessage, sent: (() -> Void)? = nil) {
        // `sent` always fires, or a producer waiting on it would hang forever.
        guard !closed, let body = try? JSONEncoder().encode(message) else { return sent?() ?? () }
        var length = UInt32(body.count).bigEndian
        var packet = Data(bytes: &length, count: 4)
        packet.append(body)
        connection.send(content: packet, completion: .contentProcessed { [weak self] error in
            if error != nil { self?.close() }
            sent?()
        })
    }

    func close() {
        guard !closed else { return }
        closed = true
        connection.cancel()
        onClose?()
    }

    private func receiveLength() {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, _, error in
            guard let self else { return }
            guard let data, data.count == 4, error == nil else { return self.close() }
            let length = Int(data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.bigEndian)
            guard length > 0, length <= Self.maxMessageBytes else { return self.close() }
            self.receiveBody(length)
        }
    }

    private func receiveBody(_ length: Int) {
        connection.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] data, _, _, error in
            guard let self else { return }
            guard let data, data.count == length, error == nil else { return self.close() }
            if let message = try? JSONDecoder().decode(AgentRemoteMessage.self, from: data) {
                self.onMessage?(message)
            }
            self.receiveLength()
        }
    }
}
