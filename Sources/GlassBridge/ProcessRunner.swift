import Darwin
import Foundation

struct CommandResult: Sendable {
    let output: Data
    let error: Data
    let status: Int32
    var text: String { String(decoding: output, as: UTF8.self) }
}
/// Both pipes are drained concurrently. Process work never occupies the UI thread.
final class ProcessJob: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private var timedOut = false
    func cancel(timeout: Bool = false) {
        lock.lock()
        cancelled = true
        timedOut = timedOut || timeout
        let p = process
        lock.unlock()
        if let p, p.isRunning {
            p.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if p.isRunning { kill(p.processIdentifier, SIGKILL) }
            }
        }
    }
    func run(
        executable: String, arguments: [String], timeout: TimeInterval, limit: Int,
        progress: (@Sendable (String) -> Void)?
    ) async throws -> CommandResult {
        try await withTaskCancellationHandler(
            operation: {
                try Task.checkCancellation()
                return try await withCheckedThrowingContinuation { continuation in
                    DispatchQueue.global(qos: .userInitiated).async {
                        let p = Process()
                        let out = Pipe()
                        let err = Pipe()
                        p.executableURL = URL(fileURLWithPath: executable)
                        p.arguments = arguments
                        p.standardOutput = out
                        p.standardError = err
                        var environment = ProcessInfo.processInfo.environment
                        environment["LC_ALL"] = "C"
                        p.environment = environment
                        self.lock.lock()
                        if self.cancelled {
                            self.lock.unlock()
                            continuation.resume(throwing: CancellationError())
                            return
                        }
                        self.process = p
                        do { try p.run() } catch {
                            self.process = nil
                            self.lock.unlock()
                            continuation.resume(throwing: error)
                            return
                        }
                        self.lock.unlock()
                        let timer = DispatchSource.makeTimerSource(queue: .global())
                        timer.schedule(deadline: .now() + timeout)
                        timer.setEventHandler { self.cancel(timeout: true) }
                        timer.resume()
                        let group = DispatchGroup()
                        let buffers = OutputBuffers()
                        for (pipe, isError) in [(out, false), (err, true)] {
                            group.enter()
                            DispatchQueue.global(qos: .userInitiated).async {
                                while true {
                                    let chunk = pipe.fileHandleForReading.availableData
                                    if chunk.isEmpty { break }
                                    buffers.append(chunk, error: isError, limit: limit)
                                    progress?(String(decoding: chunk, as: UTF8.self))
                                }
                                group.leave()
                            }
                        }
                        p.waitUntilExit()
                        group.wait()
                        timer.cancel()
                        self.lock.lock()
                        let stopped = self.cancelled
                        let expired = self.timedOut
                        self.process = nil
                        self.lock.unlock()
                        if expired {
                            continuation.resume(
                                throwing: BridgeError(
                                    message:
                                        "The phone did not respond in time. Check its connection and retry."
                                ))
                        } else if stopped {
                            continuation.resume(throwing: CancellationError())
                        } else if buffers.overflow && progress == nil {
                            continuation.resume(
                                throwing: BridgeError(
                                    message: "This folder listing is too large to display safely."))
                        } else {
                            continuation.resume(
                                returning: CommandResult(
                                    output: buffers.output, error: buffers.error,
                                    status: p.terminationStatus))
                        }
                    }
                }
            }, onCancel: { self.cancel() })
    }
}
private final class OutputBuffers: @unchecked Sendable {
    private let lock = NSLock()
    var output = Data()
    var error = Data()
    var overflow = false
    func append(_ data: Data, error isError: Bool, limit: Int) {
        lock.lock()
        defer { lock.unlock() }
        if isError {
            error.append(data)
            if error.count > limit {
                error.removeFirst(error.count - limit)
                overflow = true
            }
        } else {
            output.append(data)
            if output.count > limit {
                output.removeFirst(output.count - limit)
                overflow = true
            }
        }
    }
}
struct ADB: Sendable {
    let executable: String
    static func discover() -> String? {
        let fm = FileManager.default
        let candidates: [String?] = [
            Bundle.main.url(forResource: "adb", withExtension: nil)?.path,
            UserDefaults.standard.string(forKey: "adbPath"),
            fm.homeDirectoryForCurrentUser.appendingPathComponent(
                "Library/Android/sdk/platform-tools/adb"
            ).path,
            "/opt/homebrew/bin/adb", "/usr/local/bin/adb",
        ]
        return candidates.compactMap { $0 }.first { fm.isExecutableFile(atPath: $0) }
    }
    func command(
        _ args: [String], timeout: TimeInterval = 30, limit: Int = 16_777_216,
        progress: (@Sendable (String) -> Void)? = nil
    ) async throws -> CommandResult {
        let result = try await ProcessJob().run(
            executable: executable, arguments: args, timeout: timeout, limit: limit,
            progress: progress)
        guard result.status == 0 else {
            let error = String(
                decoding: result.error.isEmpty ? result.output : result.error, as: UTF8.self
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            throw BridgeError(
                message: error.isEmpty
                    ? "ADB exited with status \(result.status)." : String(error.suffix(1200)))
        }
        return result
    }
    func shell(_ script: String, serial: String, timeout: TimeInterval = 30) async throws -> Data {
        try await command(
            ["-s", serial, "exec-out", "sh -c " + shellQuote(script)], timeout: timeout
        )
        .output
    }
    func list(_ path: String, serial: String) async throws -> [FileEntry] {
        let script = """
            dir=\(shellQuote(path))
            [ -d "$dir" ] && [ -r "$dir" ] && [ -x "$dir" ] || { echo 'This folder is unavailable or access is denied.' >&2; exit 1; }
            for p in "$dir"/* "$dir"/.[!.]* "$dir"/..?*; do
              [ -e "$p" ] || [ -L "$p" ] || continue
              kind=x; [ ! -f "$p" ] || kind=f; [ ! -d "$p" ] || kind=d; [ ! -L "$p" ] || kind=l
              metadata=$(stat -c '%s %Y' "$p") || exit 1
              size=${metadata%% *}; stamp=${metadata#* }
              printf '%s\\0%s\\0%s\\0%s\\0' "${p##*/}" "$kind" "$size" "$stamp"
            done
            """
        return try parseRemoteListing(await shell(script, serial: serial), parent: path)
    }
    func exists(_ path: String, serial: String) async throws -> Bool {
        let data = try await shell(
            "if [ -e \(shellQuote(path)) ] || [ -L \(shellQuote(path)) ]; then printf yes; else printf no; fi",
            serial: serial)
        return String(decoding: data, as: UTF8.self) == "yes"
    }
    func manifest(_ path: String, directory: Bool, serial: String) async throws -> [String: Int64] {
        if !directory {
            let data = try await shell("stat -c %s \(shellQuote(path))", serial: serial)
            guard
                let size = Int64(
                    String(decoding: data, as: UTF8.self).trimmingCharacters(
                        in: .whitespacesAndNewlines))
            else { throw BridgeError(message: "Could not verify the file size on Android.") }
            return ["": size]
        }
        let script = """
            cd \(shellQuote(path)) || exit 1
            find . -exec sh -c 'for p do
              if [ -L "$p" ]; then echo "Symbolic links cannot be safely verified." >&2; exit 1; fi
              if [ -d "$p" ]; then size=-1; elif [ -f "$p" ]; then size=$(stat -c %s "$p") || exit 1; else echo "Special files cannot be transferred safely." >&2; exit 1; fi
              printf "%s\\0%s\\0" "$p" "$size"
            done' sh {} +
            """
        let binary = try await shell(script, serial: serial, timeout: 120)
        return try parseManifest(binary)
    }
}
func parseManifest(_ data: Data) throws -> [String: Int64] {
    var fields = data.split(separator: 0, omittingEmptySubsequences: false).map {
        String(decoding: $0, as: UTF8.self)
    }
    if fields.last == "" { fields.removeLast() }
    guard fields.count % 2 == 0 else {
        throw BridgeError(message: "Could not read the complete verification manifest.")
    }
    var result: [String: Int64] = [:]
    for i in stride(from: 0, to: fields.count, by: 2) {
        guard let size = Int64(fields[i + 1]), result[fields[i]] == nil else {
            throw BridgeError(message: "Invalid verification manifest.")
        }
        result[fields[i]] = size
    }
    return result
}
func localListing(_ path: String) throws -> [FileEntry] {
    let urls = try FileManager.default.contentsOfDirectory(
        at: URL(fileURLWithPath: path),
        includingPropertiesForKeys: [
            .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey,
        ])
    return try sortedEntries(
        urls.map { url in
            let values = try url.resourceValues(forKeys: [
                .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey,
            ])
            return FileEntry(
                path: url.path, name: url.lastPathComponent, directory: values.isDirectory ?? false,
                symbolicLink: values.isSymbolicLink ?? false, size: Int64(values.fileSize ?? 0),
                modified: values.contentModificationDate ?? .distantPast)
        })
}
func localManifest(_ path: String, directory: Bool) throws -> [String: Int64] {
    let fm = FileManager.default
    guard let resolved = realpath(path, nil) else {
        throw BridgeError(message: "The source path is unavailable.")
    }
    let root = URL(fileURLWithPath: String(cString: resolved))
    free(resolved)
    if !directory {
        return ["": (try fm.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0]
    }
    var walkingError: Error?
    guard
        let walker = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [
                .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey,
            ],
            errorHandler: { _, error in
                walkingError = error
                return false
            })
    else { throw BridgeError(message: "Could not inspect the source folder.") }
    var result: [String: Int64] = [".": -1]
    for case let url as URL in walker {
        let values = try url.resourceValues(forKeys: [
            .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey,
        ])
        if values.isSymbolicLink == true {
            throw BridgeError(
                message: "This folder contains symbolic links. Copy the original files instead.")
        }
        if values.isDirectory == true {
            result["./" + String(url.path.dropFirst(root.path.count + 1))] = -1
        }
        if values.isRegularFile != true && values.isDirectory != true {
            throw BridgeError(message: "Special files cannot be transferred safely.")
        }
        if values.isRegularFile == true {
            result["./" + String(url.path.dropFirst(root.path.count + 1))] = Int64(
                values.fileSize ?? 0)
        }
    }
    if let walkingError { throw walkingError }
    return result
}
