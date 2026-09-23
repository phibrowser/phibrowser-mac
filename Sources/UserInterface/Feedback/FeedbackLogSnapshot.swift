// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Darwin
import Foundation

/// Stored with the job so retries never substitute a later session's logs.
struct FeedbackLogSnapshot: Codable {
    struct File: Codable {
        let archivePath: String
        var relativePath: String?
        var originalBytes: Int64?
        var offset: Int64 = 0
        var collectedBytes: Int64 = 0
        var truncated = false
        var status: String
        var capturedAt = Date()
    }

    var primary: [File]
    var sentinel: [File]
}

enum FeedbackSentinelLogCollector {
    static let perStreamBytes: Int64 = 5 * 1024 * 1024
    static let totalBytes: Int64 = 64 * 1024 * 1024

    private struct Source {
        let root: URL
        let path: String
        var record: FeedbackLogSnapshot.File
    }

    static func collect(
        mainLogsURL: URL,
        serviceLogsURL: URL?,
        jobRoot: URL,
        perStreamLimit: Int64 = perStreamBytes,
        totalLimit: Int64 = totalBytes
    ) throws -> [FeedbackLogSnapshot.File] {
        var sources: [Source] = []
        func add(_ root: URL, _ path: String, _ archivePath: String) {
            sources.append(Source(root: root, path: path, record: .init(
                archivePath: archivePath, status: "pending"
            )))
        }
        for name in ["boot.log", "runner.log", "ai-gateway.log", "ai-gateway-process.log"] {
            add(mainLogsURL, name, "main/\(name)")
        }
        var directoryRecords: [FeedbackLogSnapshot.File] = []
        if let serviceLogsURL {
            do {
                let components = try directories(in: serviceLogsURL)
                for component in components where component != "runner" && component != "llm" {
                    for stream in ["stdout.log", "stderr.log"] {
                        add(serviceLogsURL, "\(component)/\(stream)", "services/\(component)/\(stream)")
                    }
                }
                // Include known services even when they have not created a directory yet.
                for component in ["system.service-broker", "system.ai-gateway", "privacy-guard"]
                    where !components.contains(component) {
                    for stream in ["stdout.log", "stderr.log"] {
                        add(serviceLogsURL, "\(component)/\(stream)", "services/\(component)/\(stream)")
                    }
                }
                add(serviceLogsURL, "runner/ipc-audit.log", "audit/runner/ipc-audit.log")
                let llmURL = serviceLogsURL.appendingPathComponent("llm", isDirectory: true)
                do {
                    for name in try children(in: llmURL) where name.hasSuffix(".log") {
                        add(serviceLogsURL, "llm/\(name)", "services/llm/\(name)")
                    }
                } catch {
                    directoryRecords.append(.init(archivePath: "services/llm/", status: failureStatus(error)))
                }
            } catch {
                directoryRecords.append(.init(archivePath: "services/", status: failureStatus(error)))
            }
        } else {
            directoryRecords.append(.init(archivePath: "services/", status: "account_unavailable"))
        }
        sources.sort { $0.record.archivePath < $1.record.archivePath }

        // Inspect first, then share the budget fairly. A large early stream must
        // not consume the budget before later services receive any coverage.
        for index in sources.indices {
            do {
                let handle = try openSource(root: sources[index].root, path: sources[index].path)
                defer { try? handle.close() }
                sources[index].record.originalBytes = try size(of: handle)
            } catch {
                sources[index].record.status = failureStatus(error)
            }
        }
        let budgets = fairBudgets(
            sizes: sources.map { min($0.record.originalBytes ?? 0, max(perStreamLimit, 0)) },
            total: max(totalLimit, 0)
        )
        for index in sources.indices where sources[index].record.originalBytes != nil {
            var record = sources[index].record
            let relativePath = "logs/sentinel/\(record.archivePath)"
            let destination = jobRoot.appendingPathComponent(relativePath)
            do {
                let input = try openSource(root: sources[index].root, path: sources[index].path)
                defer { try? input.close() }
                let originalBytes = try size(of: input)
                record.originalBytes = originalBytes
                let length = min(originalBytes, budgets[index])
                let offset = originalBytes - length
                try input.seek(toOffset: UInt64(offset))
                // Bounded even for non-rotating, multi-gigabyte model logs.
                var data = Data()
                while data.count < length {
                    let chunk = try input.read(upToCount: min(64 * 1024, Int(length) - data.count)) ?? Data()
                    if chunk.isEmpty { break }
                    data.append(chunk)
                }
                var boundaryTrim = 0
                if offset > 0, let newline = data.firstIndex(of: 0x0A), newline + 1 < data.count {
                    boundaryTrim = newline + 1
                    data.removeFirst(boundaryTrim)
                }
                record.offset = offset + Int64(boundaryTrim)
                record.collectedBytes = Int64(data.count)
                record.truncated = record.offset > 0 || record.collectedBytes < originalBytes
                record.status = originalBytes == 0 ? "empty" : (data.isEmpty ? "budget_exhausted" : "collected")
                record.capturedAt = Date()
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: destination, options: .atomic)
                record.relativePath = relativePath
            } catch {
                // Do not store localized OS errors: they can contain account paths.
                record.status = failureStatus(error)
                try? FileManager.default.removeItem(at: destination)
            }
            sources[index].record = record
        }
        return sources.map(\.record) + directoryRecords
    }

    static func fairBudgets(sizes: [Int64], total: Int64) -> [Int64] {
        var result = [Int64](repeating: 0, count: sizes.count)
        var remaining = max(total, 0)
        let ordered = sizes.indices.sorted {
            sizes[$0] == sizes[$1] ? $0 < $1 : sizes[$0] < sizes[$1]
        }
        for (position, index) in ordered.enumerated() {
            let amount = min(max(sizes[index], 0), remaining / Int64(ordered.count - position))
            result[index] = amount
            remaining -= amount
        }
        return result
    }

    private static func size(of handle: FileHandle) throws -> Int64 {
        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0 else { throw posixError() }
        guard info.st_mode & S_IFMT == S_IFREG else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL)) }
        return max(info.st_size, 0)
    }

    /// Walk with openat/O_NOFOLLOW so component directories cannot redirect the
    /// collector outside the selected channel/account, even during replacement.
    private static func openSource(root: URL, path: String) throws -> FileHandle {
        var descriptor = try openDirectory(root)
        defer { close(descriptor) }
        let components = path.split(separator: "/").map(String.init)
        for component in components.dropLast() {
            let next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw posixError() }
            close(descriptor)
            descriptor = next
        }
        guard let filename = components.last else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL)) }
        let file = openat(descriptor, filename, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard file >= 0 else { throw posixError() }
        return FileHandle(fileDescriptor: file, closeOnDealloc: true)
    }

    private static func openDirectory(_ url: URL) throws -> Int32 {
        // Resolve only system aliases, such as /var -> /private/var. Reject
        // symlinks in the application/account/log directory hierarchy.
        var path = url.standardizedFileURL.path
        for alias in ["/var", "/tmp"] where path.hasPrefix(alias + "/") {
            // Foundation may normalize /private/var back to /var, which would
            // reintroduce the symlink before the O_NOFOLLOW directory walk.
            guard let resolved = realpath(alias, nil) else { throw posixError() }
            path = String(cString: resolved) + path.dropFirst(alias.count)
            free(resolved)
        }
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw posixError() }
        for component in path.split(separator: "/") {
            let next = openat(descriptor, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if next < 0 {
                let error = posixError()
                close(descriptor)
                throw error
            }
            close(descriptor)
            descriptor = next
        }
        return descriptor
    }

    private static func children(in directory: URL) throws -> [String] {
        let descriptor = try openDirectory(directory)
        guard let stream = fdopendir(descriptor) else {
            let error = posixError()
            close(descriptor)
            throw error
        }
        defer { closedir(stream) }
        var names: [String] = []
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name != ".", name != "..", !name.hasPrefix(".") { names.append(name) }
        }
        return names.sorted()
    }

    private static func directories(in root: URL) throws -> [String] {
        try children(in: root).filter { name in
            var info = stat()
            let path = root.appendingPathComponent(name).path
            return lstat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
        }
    }

    private static func posixError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }

    private static func failureStatus(_ error: Error) -> String {
        let error = error as NSError
        return error.domain == NSPOSIXErrorDomain ? "unavailable_errno_\(error.code)" : "read_failed"
    }
}
