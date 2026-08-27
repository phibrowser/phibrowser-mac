import Darwin
import Foundation

/// Accepts exactly one connection on a temporary Unix domain socket, captures
/// the request head, and replies with a fixed response. Shared by every test
/// that needs a fake service-broker peer.
final class UnixHTTPTestServer: @unchecked Sendable {
    let socketPath: String

    private let listener: Int32
    private let response: Data
    private let lock = NSLock()
    private var capturedRequest = Data()

    init(response: String) {
        socketPath = "/tmp/phi-broker-\(UUID().uuidString).sock"
        self.response = Data(response.utf8)
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        precondition(listener >= 0)

        var address = sockaddr_un()
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            socketPath.withCString { source in
                strncpy(buffer.baseAddress!.assumingMemoryBound(to: CChar.self), source, buffer.count - 1)
            }
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        precondition(result == 0)
        precondition(listen(listener, 1) == 0)

        DispatchQueue.global().async { [self] in
            serveOneRequest()
        }
    }

    deinit {
        close(listener)
        unlink(socketPath)
    }

    var requestMethod: String? { requestLine?.split(separator: " ").first.map(String.init) }

    var requestTarget: String? {
        let parts = requestLine?.split(separator: " ")
        return parts?.dropFirst().first.map(String.init)
    }

    var requestHeaders: [String: String] {
        guard let request = String(data: requestData, encoding: .utf8),
              let separator = request.range(of: "\r\n\r\n") else {
            return [:]
        }
        return request[..<separator.lowerBound]
            .split(separator: "\r\n")
            .dropFirst()
            .reduce(into: [:]) { headers, line in
                guard let colon = line.firstIndex(of: ":") else { return }
                headers[line[..<colon].lowercased()] = line[line.index(after: colon)...]
                    .trimmingCharacters(in: .whitespaces)
            }
    }

    private var requestData: Data {
        lock.lock()
        defer { lock.unlock() }
        return capturedRequest
    }

    private var requestLine: String? {
        guard let request = String(data: requestData, encoding: .utf8) else { return nil }
        return request.components(separatedBy: "\r\n").first
    }

    private func serveOneRequest() {
        let connection = accept(listener, nil, nil)
        guard connection >= 0 else { return }
        defer { close(connection) }
        var noSigPipe: Int32 = 1
        _ = setsockopt(
            connection,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSigPipe,
            socklen_t(MemoryLayout<Int32>.size)
        )

        var request = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = read(connection, &buffer, buffer.count)
            guard count > 0 else { return }
            request.append(buffer, count: count)
            if request.range(of: Data("\r\n\r\n".utf8)) != nil {
                lock.lock()
                capturedRequest = request
                lock.unlock()
                break
            }
        }

        response.withUnsafeBytes { bytes in
            guard let pointer = bytes.baseAddress else { return }
            var written = 0
            while written < bytes.count {
                let count = write(connection, pointer.advanced(by: written), bytes.count - written)
                guard count > 0 else { return }
                written += count
            }
        }
    }
}
