import Foundation

struct LiveMergeChecks {
    @MainActor func run(serial: String, adbPath: String) async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            "glassbridge-live-merge-" + UUID().uuidString)
        let source = root.appendingPathComponent("Merge ' 😀")
        let receive = root.appendingPathComponent("receive")
        let remote = "/sdcard/Download/.glassbridge-merge-test-" + UUID().uuidString
        let service = ADB(executable: adbPath)
        try fm.createDirectory(
            at: source.appendingPathComponent("empty"), withIntermediateDirectories: true)
        try fm.createDirectory(at: receive, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let name = "same '\n😀.bin"
        try Data([1, 2, 3]).write(to: source.appendingPathComponent(name))
        _ = try await service.shell("mkdir -p " + shellQuote(remote), serial: serial)
        do {
            let model = AppModel()
            model.adbPath = adbPath
            model.devices = [Device(id: serial, state: "device", name: "Test Android")]
            model.selectedDevice = serial
            model.androidPath = remote
            model.macPath = receive.path
            model.conflictResolver = { _ in .merge }
            let entry = FileEntry(
                path: source.path, name: source.lastPathComponent, directory: true,
                symbolicLink: false, size: 0, modified: Date())
            model.enqueue([entry], from: .mac)
            try await idle(model)
            try requireDone(model)
            let destination = childPath(remote, entry.name)
            let extra = childPath(destination, "extra.txt")
            _ = try await service.shell("printf extra > " + shellQuote(extra), serial: serial)
            try Data([4, 5, 6]).write(to: source.appendingPathComponent(name))
            try Data([7]).write(to: source.appendingPathComponent("new.bin"))
            model.enqueue([entry], from: .mac)
            try await idle(model)
            try requireDone(model)
            guard model.transfers.last?.detail.contains("2 updated") == true,
                try await service.exists(extra, serial: serial),
                try await service.sha256(childPath(destination, name), serial: serial)
                    == localSHA256(source.appendingPathComponent(name).path)
            else { throw BridgeError(message: "Live merge contents did not match") }
            let remoteEntry = FileEntry(
                path: destination, name: entry.name, directory: true,
                symbolicLink: false, size: 0, modified: Date())
            model.enqueue([remoteEntry], from: .android)
            try await idle(model)
            try requireDone(model)
            model.enqueue([remoteEntry], from: .android)
            try await idle(model)
            try requireDone(model)
            guard model.transfers.last?.totalBytes == 0 else {
                throw BridgeError(message: "Unchanged live merge copied file data")
            }
            let deleteEntry = FileEntry(
                path: childPath(destination, "new.bin"), name: "new.bin",
                directory: false, symbolicLink: false, size: 1, modified: Date())
            try await service.delete(deleteEntry, folder: destination, serial: serial)
            guard !(try await service.exists(deleteEntry.path, serial: serial)),
                try await service.exists(extra, serial: serial)
            else { throw BridgeError(message: "Live deletion changed the wrong item") }
            _ = try await service.shell("rm -rf " + shellQuote(remote), serial: serial)
        } catch {
            _ = try? await service.shell("rm -rf " + shellQuote(remote), serial: serial)
            throw error
        }
    }
    @MainActor private func idle(_ model: AppModel) async throws {
        let deadline = Date().addingTimeInterval(90)
        while model.activeCount > 0 {
            if Date() > deadline {
                await model.shutdown()
                throw BridgeError(message: "Live merge timed out")
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        try await Task.sleep(for: .milliseconds(150))
    }
    @MainActor private func requireDone(_ model: AppModel) throws {
        guard model.transfers.last?.state == .done else {
            throw BridgeError(message: model.transfers.last?.detail ?? "Transfer did not finish")
        }
    }
}

func checkMacTrashRoundTrip() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent(
        "glassbridge-trash-test-" + UUID().uuidString)
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    let source = root.appendingPathComponent("restore me ' 😀.txt")
    try Data([1, 2, 3]).write(to: source)
    var trashed: NSURL?
    try fm.trashItem(at: source, resultingItemURL: &trashed)
    guard let trashURL = trashed as URL?, !fm.fileExists(atPath: source.path) else {
        throw BridgeError(message: "Mac Trash did not return a recoverable item")
    }
    try fm.moveItem(at: trashURL, to: source)
    guard try Data(contentsOf: source) == Data([1, 2, 3]) else {
        throw BridgeError(message: "Restored Trash contents differ")
    }
}
