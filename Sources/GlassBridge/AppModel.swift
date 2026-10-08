import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor final class AppModel: ObservableObject {
    @Published var devices: [Device] = []
    @Published var selectedDevice = ""
    @Published var macPath = FileManager.default.homeDirectoryForCurrentUser.path
    @Published var androidPath = "/sdcard"
    @Published var macFiles: [FileEntry] = []
    @Published var androidFiles: [FileEntry] = []
    @Published var macSelection = Set<String>()
    @Published var androidSelection = Set<String>()
    @Published var macBusy = false
    @Published var androidBusy = false
    @Published var macError: String?
    @Published var androidError: String?
    @Published var connectionError: String?
    @Published var alert: String?
    @Published var conflict: ConflictPrompt?
    var conflictResolver: ((ConflictPrompt) async -> ConflictResolution)?
    private var conflictContinuation: CheckedContinuation<ConflictResolution, Never>?
    @Published var transfers: [Transfer] = []
    @Published var showTransfers = true
    @Published var showHidden = false
    @Published var adbPath = ADB.discover() ?? ""
    private var pollTask: Task<Void, Never>?
    private var macLoad: Task<Void, Never>?
    private var androidLoad: Task<Void, Never>?
    private var queueTask: Task<Void, Never>?
    private var activeTask: Task<Void, Never>?
    private var macGeneration = UUID()
    private var androidGeneration = UUID()
    var adb: ADB { ADB(executable: adbPath) }
    var device: Device? { devices.first { $0.id == selectedDevice } }
    var connected: Bool { device?.ready == true }
    var activeCount: Int {
        transfers.filter { [.waiting, .running, .verifying, .deciding].contains($0.state) }.count
    }

    func start() {
        guard pollTask == nil else { return }
        loadMac()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshDevices()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }
    func refreshDevices() async {
        guard !adbPath.isEmpty else {
            connectionError = "Choose ADB in Settings to connect your phone."
            return
        }
        do {
            let found = parseDevices(try await adb.command(["devices", "-l"], timeout: 8).text)
            let wasConnected = connected
            if devices != found { devices = found }
            connectionError = nil
            if selectedDevice.isEmpty, let first = found.first(where: \.ready) ?? found.first {
                selectDevice(first.id)
            }
            if connected && !wasConnected && !androidBusy { loadAndroid() }
            if wasConnected && !connected {
                androidLoad?.cancel()
                androidGeneration = UUID()
                androidFiles = []
                androidSelection = []
                androidBusy = false
            }
        } catch is CancellationError {} catch { connectionError = error.localizedDescription }
    }
    func selectDevice(_ serial: String) {
        androidLoad?.cancel()
        selectedDevice = serial
        androidPath = "/sdcard"
        androidFiles = []
        androidSelection = []
        androidError = nil
        if connected { loadAndroid() }
    }
    func loadMac(_ path: String? = nil) {
        if let path {
            macPath = URL(fileURLWithPath: path).standardizedFileURL.path
            macSelection = []
        }
        macLoad?.cancel()
        macGeneration = UUID()
        let generation = macGeneration
        let current = macPath
        macBusy = true
        macError = nil
        macLoad = Task {
            do {
                let entries = try await Task.detached(priority: .userInitiated) {
                    try localListing(current)
                }.value
                guard generation == macGeneration else { return }
                macFiles = entries
                macSelection.formIntersection(Set(entries.map(\.id)))
            } catch {
                if generation == macGeneration {
                    macError = error.localizedDescription
                    macFiles = []
                }
            }
            if generation == macGeneration { macBusy = false }
        }
    }
    func loadAndroid(_ path: String? = nil) {
        if let path {
            androidPath = path
            androidSelection = []
        }
        androidLoad?.cancel()
        androidGeneration = UUID()
        let generation = androidGeneration
        guard connected else {
            androidFiles = []
            androidBusy = false
            return
        }
        let current = androidPath
        let serial = selectedDevice
        let service = adb
        androidBusy = true
        androidError = nil
        androidLoad = Task {
            do {
                let entries = try await service.list(current, serial: serial)
                guard generation == androidGeneration else { return }
                androidFiles = entries
                androidSelection.formIntersection(Set(entries.map(\.id)))
            } catch is CancellationError {} catch {
                if generation == androidGeneration {
                    androidError = error.localizedDescription
                    androidFiles = []
                }
            }
            if generation == androidGeneration { androidBusy = false }
        }
    }
    func goUp(_ side: Side) {
        let path = side == .mac ? macPath : androidPath
        let parent = (path as NSString).deletingLastPathComponent
        if side == .mac {
            loadMac(parent.isEmpty ? "/" : parent)
        } else {
            loadAndroid(parent.isEmpty ? "/" : parent)
        }
    }
    func chooseMacFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.prompt = "Open folder"
        panel.directoryURL = URL(fileURLWithPath: macPath)
        if panel.runModal() == .OK, let url = panel.url { loadMac(url.path) }
    }
    func chooseADB() {
        let panel = NSOpenPanel()
        panel.title = "Choose the adb executable"
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let path = panel.url?.path,
            FileManager.default.isExecutableFile(atPath: path)
        {
            adbPath = path
            UserDefaults.standard.set(path, forKey: "adbPath")
            Task { await refreshDevices() }
        }
    }
    func enqueueSelection(_ side: Side) {
        let selection = side == .mac ? macSelection : androidSelection
        let files = side == .mac ? macFiles : androidFiles
        enqueue(files.filter { selection.contains($0.id) }, from: side)
    }
    func enqueue(_ entries: [FileEntry], from: Side, folder: String? = nil, serial: String? = nil) {
        guard let device = devices.first(where: { $0.id == (serial ?? selectedDevice) && $0.ready })
        else {
            alert = "Connect and authorize an Android device before transferring."
            return
        }
        guard !entries.isEmpty else { return }
        if entries.contains(where: \.symbolicLink) {
            alert = "Select original files and folders. Symbolic links are not supported."
            return
        }
        for entry in entries {
            transfers.append(
                Transfer(
                    id: UUID(), source: entry, from: from, serial: device.id,
                    destinationFolder: folder ?? (from == .mac ? androidPath : macPath),
                    deviceName: device.name))
        }
        showTransfers = true
        startQueue()
    }
    func receive(_ payload: DragPayload, on side: Side, folder: String, serial: String) {
        guard payload.side != side else { return }
        if payload.side == .android && payload.serial != serial {
            alert = "This selection belongs to a different Android device."
            return
        }
        enqueue(payload.entries, from: payload.side, folder: folder, serial: serial)
    }
    func receiveLocalURLs(_ urls: [URL], folder: String? = nil, serial: String? = nil) {
        let targetFolder = folder ?? androidPath
        let targetSerial = serial ?? selectedDevice
        Task {
            do {
                let entries = try await Task.detached(priority: .userInitiated) {
                    try urls.map { url in
                        let value = try url.resourceValues(forKeys: [
                            .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey,
                            .contentModificationDateKey,
                        ])
                        return FileEntry(
                            path: url.path, name: url.lastPathComponent,
                            directory: value.isDirectory ?? false,
                            symbolicLink: value.isSymbolicLink ?? false,
                            size: Int64(value.fileSize ?? 0),
                            modified: value.contentModificationDate ?? .distantPast)
                    }
                }.value
                enqueue(entries, from: .mac, folder: targetFolder, serial: targetSerial)
            } catch { alert = error.localizedDescription }
        }
    }
    func resolveConflict(_ resolution: ConflictResolution) {
        let continuation = conflictContinuation
        conflictContinuation = nil
        conflict = nil
        continuation?.resume(returning: resolution)
    }
    private func chooseConflict(_ prompt: ConflictPrompt) async throws -> ConflictResolution {
        if let conflictResolver { return await conflictResolver(prompt) }
        try Task.checkCancellation()
        let resolution = await withTaskCancellationHandler(
            operation: {
                await withCheckedContinuation { continuation in
                    conflictContinuation = continuation
                    conflict = prompt
                }
            }, onCancel: { [weak self] in Task { @MainActor in self?.resolveConflict(.cancel) } })
        try Task.checkCancellation()
        return resolution
    }
    private func monitorTransfer(_ item: Transfer, staging: String, total: Int64) -> Task<
        Void, Never
    > {
        let service = adb
        return Task {
            var samples: [(Date, Int64)] = [(Date(), 0)]
            while !Task.isCancelled {
                do {
                    let bytes: Int64
                    if item.from == .mac {
                        bytes = try await service.transferredBytes(
                            staging, directory: item.source.directory, serial: item.serial)
                    } else {
                        bytes = await Task.detached(priority: .utility) {
                            localTransferBytes(staging, directory: item.source.directory)
                        }.value
                    }
                    guard !Task.isCancelled else { break }
                    let now = Date()
                    let count = min(total, max(0, bytes))
                    samples.append((now, count))
                    samples.removeAll { now.timeIntervalSince($0.0) > 5 }
                    let first = samples.first ?? (now, count)
                    let duration = now.timeIntervalSince(first.0)
                    let speed = duration > 0.05 ? max(0, Double(count - first.1) / duration) : 0
                    update(item.id) { transfer in
                        guard transfer.state == .running else { return }
                        transfer.transferredBytes = count
                        transfer.totalBytes = total
                        transfer.progress = total > 0 ? Double(count) / Double(total) : nil
                        transfer.bytesPerSecond = speed
                        transfer.secondsRemaining =
                            speed > 1 && count < total ? Double(total - count) / speed : nil
                    }
                } catch is CancellationError { break } catch
                { /* The transfer command reports connection errors. */  }
                do { try await Task.sleep(for: .milliseconds(item.from == .mac ? 650 : 350)) } catch
                {
                    break
                }
            }
        }
    }
    func shutdown() async {
        pollTask?.cancel()
        macLoad?.cancel()
        androidLoad?.cancel()
        for item in transfers where item.state == .waiting { cancel(item.id) }
        activeTask?.cancel()
        await queueTask?.value
    }
    func cancel(_ id: UUID) {
        guard let i = transfers.firstIndex(where: { $0.id == id }) else { return }
        if transfers[i].state == .waiting {
            transfers[i].state = .cancelled
            transfers[i].detail = "Removed from queue"
        } else if [.running, .verifying, .deciding].contains(transfers[i].state) {
            activeTask?.cancel()
        }
    }
    func retry(_ id: UUID) {
        guard let old = transfers.first(where: { $0.id == id }) else { return }
        transfers.append(
            Transfer(
                id: UUID(), source: old.source, from: old.from, serial: old.serial,
                destinationFolder: old.destinationFolder, deviceName: old.deviceName))
        startQueue()
    }
    func update(_ id: UUID, _ action: (inout Transfer) -> Void) {
        guard let i = transfers.firstIndex(where: { $0.id == id }) else { return }
        action(&transfers[i])
    }
    private func startQueue() {
        guard queueTask == nil else { return }
        queueTask = Task {
            while let next = transfers.first(where: { $0.state == .waiting }) {
                activeTask = Task { await perform(next) }
                await activeTask?.value
                activeTask = nil
            }
            queueTask = nil
            loadMac()
            if connected { loadAndroid() }
        }
    }
    private func perform(_ item: Transfer) async {
        let service = adb
        let fm = FileManager.default
        update(item.id) {
            $0.state = .running
            $0.started = Date()
            $0.detail = "Preparing transfer…"
        }
        var staging: String?
        var published = false
        var monitor: Task<Void, Never>?
        do {
            guard devices.contains(where: { $0.id == item.serial && $0.ready }) else {
                throw BridgeError(
                    message:
                        "The selected phone is disconnected or not authorized. Reconnect it and retry."
                )
            }
            let sourceManifest: [String: Int64]
            if item.from == .mac {
                sourceManifest = try await Task.detached(priority: .userInitiated) {
                    try localManifest(item.source.path, directory: item.source.directory)
                }.value
            } else {
                sourceManifest = try await service.manifest(
                    item.source.path, directory: item.source.directory, serial: item.serial)
            }
            try Task.checkCancellation()
            let total = sourceManifest.values.filter { $0 >= 0 }.reduce(0, +)
            var name = item.source.name
            var destination = childPath(item.destinationFolder, name)
            var suffix = 2
            var replacing = false
            let existing =
                item.from == .mac
                ? try await service.exists(destination, serial: item.serial)
                : localPathExists(destination)
            if existing {
                update(item.id) {
                    $0.state = .deciding
                    $0.detail = "Choose what to do with the existing item"
                    $0.totalBytes = total
                }
                let choice = try await chooseConflict(
                    ConflictPrompt(
                        id: item.id, name: name, destination: destination,
                        directory: item.source.directory,
                        destinationName: item.from == .mac ? item.deviceName : "your Mac"))
                switch choice {
                case .replace: replacing = true
                case .skip:
                    update(item.id) {
                        $0.state = .skipped
                        $0.detail = "Existing item kept"
                    }
                    return
                case .cancel: throw CancellationError()
                case .keepBoth:
                    repeat {
                        let url = URL(fileURLWithPath: item.source.name)
                        let ext = item.source.directory ? "" : url.pathExtension
                        let base =
                            ext.isEmpty
                            ? item.source.name : url.deletingPathExtension().lastPathComponent
                        name = "\(base) (\(suffix))" + (ext.isEmpty ? "" : "." + ext)
                        destination = childPath(item.destinationFolder, name)
                        suffix += 1
                        try Task.checkCancellation()
                    } while item.from == .mac
                        ? try await service.exists(destination, serial: item.serial)
                        : localPathExists(destination)
                }
            }
            let temp = childPath(item.destinationFolder, ".glassbridge-" + item.id.uuidString)
            staging = temp
            update(item.id) {
                $0.state = .running
                $0.destination = destination
                $0.totalBytes = total
                $0.started = Date()
                $0.detail = "Copying to \(name)"
            }
            monitor = monitorTransfer(item, staging: temp, total: total)
            if item.from == .mac {
                _ = try await service.command(
                    ["-s", item.serial, "push", item.source.path, temp], timeout: 86_400,
                    limit: 262_144,
                    progress: { _ in })
            } else {
                _ = try await service.command(
                    ["-s", item.serial, "pull", "-a", item.source.path, temp], timeout: 86_400,
                    limit: 262_144, progress: { _ in })
            }
            monitor?.cancel()
            await monitor?.value
            monitor = nil
            update(item.id) {
                $0.transferredBytes = total
                $0.progress = total > 0 ? 1 : nil
                $0.secondsRemaining = nil
            }
            if item.source.directory {
                let directories = sourceManifest.filter { $0.value == -1 }.keys.sorted()
                if item.from == .mac {
                    var batch: [String] = []
                    var length = 0
                    for relative in directories {
                        try Task.checkCancellation()
                        let directory =
                            relative == "." ? temp : childPath(temp, String(relative.dropFirst(2)))
                        let quoted = shellQuote(directory)
                        if length + quoted.utf8.count > 16000 && !batch.isEmpty {
                            _ = try await service.shell(
                                "mkdir -p " + batch.joined(separator: " "), serial: item.serial)
                            batch = []
                            length = 0
                        }
                        batch.append(quoted)
                        length += quoted.utf8.count + 1
                    }
                    if !batch.isEmpty {
                        _ = try await service.shell(
                            "mkdir -p " + batch.joined(separator: " "), serial: item.serial)
                    }
                } else {
                    try await Task.detached(priority: .userInitiated) {
                        for relative in directories {
                            let directory =
                                relative == "."
                                ? temp : childPath(temp, String(relative.dropFirst(2)))
                            try fm.createDirectory(
                                atPath: directory, withIntermediateDirectories: true)
                        }
                    }.value
                }
            }
            try Task.checkCancellation()
            update(item.id) {
                $0.state = .verifying
                $0.progress = nil
                $0.detail = "Checking file names and sizes…"
            }
            let targetManifest: [String: Int64]
            if item.from == .mac {
                targetManifest = try await service.manifest(
                    temp, directory: item.source.directory, serial: item.serial)
            } else {
                targetManifest = try await Task.detached(priority: .userInitiated) {
                    try localManifest(temp, directory: item.source.directory)
                }.value
            }
            guard sourceManifest == targetManifest else {
                let missing = Set(sourceManifest.keys).subtracting(targetManifest.keys).sorted()
                    .first
                let extra = Set(targetManifest.keys).subtracting(sourceManifest.keys).sorted().first
                let changed = sourceManifest.keys.sorted().first {
                    targetManifest[$0] != sourceManifest[$0]
                }
                let reason =
                    missing.map { "Missing item: " + $0 } ?? extra.map { "Unexpected item: " + $0 }
                    ?? changed.map { "Size mismatch: " + $0 } ?? "Folder contents differ."
                throw BridgeError(
                    message: "Verification failed. " + reason
                        + " The incomplete copy was not published. Retry the transfer.")
            }
            try Task.checkCancellation()
            let publicationWarning: String?
            if item.from == .mac {
                publicationWarning = try await Task.detached {
                    try await service.publish(
                        staging: temp, destination: destination, replacing: replacing,
                        serial: item.serial)
                }.value
            } else {
                publicationWarning = try await Task.detached {
                    try publishLocal(staging: temp, destination: destination, replacing: replacing)
                }.value
            }
            published = true
            let bytes = sourceManifest.values.filter { $0 >= 0 }.reduce(0, +)
            let elapsed = Date().timeIntervalSince(
                transfers.first { $0.id == item.id }?.started ?? Date())
            update(item.id) {
                $0.state = .done
                $0.progress = 1
                $0.transferredBytes = bytes
                $0.totalBytes = bytes
                $0.detail =
                    "\(readableSize(bytes)) · \(String(format: "%.1f", elapsed))s · Sizes verified"
                    + (publicationWarning.map { " · " + $0 } ?? "")
            }
        } catch is CancellationError {
            update(item.id) {
                $0.state = .cancelled
                $0.detail = "Transfer cancelled"
                $0.progress = nil
            }
        } catch {
            update(item.id) {
                $0.state = .failed
                $0.detail = error.localizedDescription
                $0.progress = nil
            }
        }
        monitor?.cancel()
        await monitor?.value
        if let staging, !published {
            // Cleanup is independent of the cancelled transfer task, and only targets its UUID path.
            let cleanup = Task.detached { () -> Bool in
                do {
                    if item.from == .mac {
                        _ = try await service.shell(
                            "rm -rf \(shellQuote(staging))", serial: item.serial, timeout: 10)
                    } else if fm.fileExists(atPath: staging) {
                        try fm.removeItem(atPath: staging)
                    }
                    return true
                } catch { return false }
            }
            if !(await cleanup.value) {
                update(item.id) { $0.detail += " Partial data may remain at \(staging)." }
            }
        }
    }
}
