import CryptoKit
import Foundation

func localSHA256(_ path: String) async throws -> String {
    let task = Task.detached(priority: .utility) {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        var hash = SHA256()
        while true {
            try Task.checkCancellation()
            let data = try handle.read(upToCount: 1_048_576) ?? Data()
            if data.isEmpty { break }
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    return try await withTaskCancellationHandler(
        operation: { try await task.value }, onCancel: { task.cancel() })
}

extension ADB {
    func sha256(_ path: String, serial: String) async throws -> String {
        let data = try await shell("sha256sum \(shellQuote(path))", serial: serial, timeout: 3600)
        let hash = String(String(decoding: data, as: UTF8.self).prefix(64)).lowercased()
        guard hash.count == 64, hash.allSatisfy({ "0123456789abcdef".contains($0) }) else {
            throw BridgeError(message: "Could not read the SHA-256 hash on Android.")
        }
        return hash
    }
}

private struct MergeFile {
    let source: String
    let destination: String
    let size: Int64
    let hash: String
}

extension AppModel {
    func mergeTransfer(
        _ item: Transfer, destination: String, sourceManifest: [String: Int64]
    ) async throws {
        let service = adb
        let fm = FileManager.default
        update(item.id) {
            $0.state = .verifying
            $0.progress = nil
            $0.destination = destination
            $0.detail = "Comparing SHA-256 hashes…"
        }
        let targetIsDirectory: Bool
        if item.from == .mac {
            let data = try await service.shell(
                "if [ -L \(shellQuote(destination)) ]; then exit 1; fi; "
                    + "if [ -d \(shellQuote(destination)) ]; then printf 1; else printf 0; fi",
                serial: item.serial)
            targetIsDirectory = String(decoding: data, as: UTF8.self) == "1"
        } else {
            let values = try URL(fileURLWithPath: destination).resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                throw BridgeError(message: "The destination is a symbolic link.")
            }
            targetIsDirectory = values.isDirectory == true
        }
        guard targetIsDirectory == item.source.directory else {
            throw BridgeError(
                message: "A file and folder have the same name. Use Replace or Keep Both instead.")
        }
        let targetManifest: [String: Int64]
        if item.from == .mac {
            targetManifest = try await service.manifest(
                destination, directory: item.source.directory, serial: item.serial)
        } else {
            targetManifest = try await Task.detached {
                try localManifest(destination, directory: item.source.directory)
            }.value
        }
        for (relative, size) in sourceManifest {
            if let target = targetManifest[relative], (size == -1) != (target == -1) {
                throw BridgeError(
                    message:
                        "A file and folder collide at \(relative). Use Replace or Keep Both instead."
                )
            }
        }
        func path(_ root: String, _ relative: String) -> String {
            relative == "." || relative.isEmpty
                ? root : childPath(root, String(relative.dropFirst(2)))
        }
        var pending: [MergeFile] = []
        var skipped = 0
        for relative in sourceManifest.keys.sorted() where sourceManifest[relative]! >= 0 {
            try Task.checkCancellation()
            let source = path(item.source.path, relative)
            let target = path(destination, relative)
            let size = sourceManifest[relative]!
            update(item.id) { $0.detail = "Checking \((source as NSString).lastPathComponent)…" }
            let sourceHash =
                item.from == .mac
                ? try await localSHA256(source)
                : try await service.sha256(source, serial: item.serial)
            if targetManifest[relative] == size {
                let targetHash =
                    item.from == .mac
                    ? try await service.sha256(target, serial: item.serial)
                    : try await localSHA256(target)
                if sourceHash == targetHash {
                    skipped += 1
                    continue
                }
            }
            pending.append(
                MergeFile(source: source, destination: target, size: size, hash: sourceHash))
        }
        try Task.checkCancellation()
        let total = pending.reduce(Int64(0)) { $0 + $1.size }
        update(item.id) {
            $0.totalBytes = total
            $0.transferredBytes = 0
            $0.progress = total > 0 ? 0 : nil
            $0.started = Date()
        }
        // Preflight all type conflicts before making any changes. Extra paths stay untouched.
        for relative in sourceManifest.keys.sorted()
        where sourceManifest[relative] == -1 && targetManifest[relative] == nil {
            try Task.checkCancellation()
            let folder = path(destination, relative)
            if item.from == .mac {
                _ = try await service.shell("mkdir -p \(shellQuote(folder))", serial: item.serial)
            } else {
                try await Task.detached {
                    try fm.createDirectory(atPath: folder, withIntermediateDirectories: true)
                }.value
            }
        }
        let staging = childPath(item.destinationFolder, ".glassbridge-merge-" + item.id.uuidString)
        var completed: Int64 = 0
        var copied = 0
        var warnings: [String] = []
        var monitor: Task<Void, Never>?
        do {
            if !pending.isEmpty {
                if item.from == .mac {
                    _ = try await service.shell("mkdir \(shellQuote(staging))", serial: item.serial)
                } else {
                    try fm.createDirectory(atPath: staging, withIntermediateDirectories: false)
                }
            }
            for (index, file) in pending.enumerated() {
                try Task.checkCancellation()
                let temp = childPath(staging, "file-\(index)")
                update(item.id) {
                    $0.state = .running
                    $0.detail = "Updating \((file.source as NSString).lastPathComponent)"
                    $0.transferredBytes = completed
                }
                monitor = monitorTransfer(
                    item, staging: temp, total: total, directory: false, completedBytes: completed)
                let arguments =
                    item.from == .mac
                    ? ["-s", item.serial, "push", file.source, temp]
                    : ["-s", item.serial, "pull", "-a", file.source, temp]
                _ = try await service.command(
                    arguments, timeout: 86_400, limit: 262_144, progress: { _ in })
                monitor?.cancel()
                await monitor?.value
                monitor = nil
                update(item.id) {
                    $0.state = .verifying
                    $0.transferredBytes = completed + file.size
                    $0.progress = total > 0 ? Double(completed + file.size) / Double(total) : 1
                    $0.detail = "Verifying SHA-256: \((file.source as NSString).lastPathComponent)"
                }
                let copiedHash =
                    item.from == .mac
                    ? try await service.sha256(temp, serial: item.serial)
                    : try await localSHA256(temp)
                guard copiedHash == file.hash else {
                    throw BridgeError(
                        message:
                            "Hash verification failed for \((file.source as NSString).lastPathComponent). Its existing copy was kept."
                    )
                }
                try Task.checkCancellation()
                let warning: String?
                if item.from == .mac {
                    // Finish the verified rename/rollback even if Cancel is pressed here.
                    warning = try await Task.detached {
                        try await service.publish(
                            staging: temp, destination: file.destination, replacing: true,
                            serial: item.serial)
                    }.value
                } else {
                    warning = try await Task.detached {
                        try publishLocal(
                            staging: temp, destination: file.destination, replacing: true)
                    }.value
                }
                if let warning { warnings.append(warning) }
                completed += file.size
                copied += 1
            }
        } catch {
            monitor?.cancel()
            await monitor?.value
            let cleaned = await cleanMergeStaging(
                staging, from: item.from, service: service, serial: item.serial)
            if !cleaned {
                throw BridgeError(
                    message: error.localizedDescription + " Temporary data remains at \(staging).")
            }
            throw error
        }
        if !pending.isEmpty,
            !(await cleanMergeStaging(
                staging, from: item.from, service: service, serial: item.serial))
        {
            warnings.append("Temporary folder remains at \(staging)")
        }
        update(item.id) {
            $0.state = .done
            $0.progress = 1
            $0.transferredBytes = total
            $0.totalBytes = total
            $0.secondsRemaining = nil
            $0.detail =
                "\(copied) updated · \(skipped) unchanged · SHA-256 verified"
                + (warnings.isEmpty ? "" : " · " + warnings.joined(separator: "; "))
        }
    }
}

private func cleanMergeStaging(_ path: String, from: Side, service: ADB, serial: String) async
    -> Bool
{
    await Task.detached {
        do {
            if from == .mac {
                _ = try await service.shell(
                    "rm -rf \(shellQuote(path))", serial: serial, timeout: 10)
            } else if FileManager.default.fileExists(atPath: path) {
                try FileManager.default.removeItem(atPath: path)
            }
            return true
        } catch { return false }
    }.value
}
