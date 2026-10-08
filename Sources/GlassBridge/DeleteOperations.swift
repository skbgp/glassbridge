import Foundation
import SwiftUI

func validateDeletion(_ entry: FileEntry, folder: String) throws {
    let normalized = (entry.path as NSString).standardizingPath
    let parent = (normalized as NSString).deletingLastPathComponent
    guard entry.path.hasPrefix("/"), !entry.name.isEmpty,
        entry.name != ".", entry.name != "..", !entry.name.contains("/"),
        normalized == childPath((folder as NSString).standardizingPath, entry.name),
        parent == (folder as NSString).standardizingPath,
        !["/", "/sdcard", "/storage", "/storage/emulated", "/storage/emulated/0"].contains(
            normalized)
    else { throw BridgeError(message: "This item cannot be deleted from the file list.") }
}

extension ADB {
    func delete(_ entry: FileEntry, folder: String, serial: String) async throws {
        try validateDeletion(entry, folder: folder)
        _ = try await shell("rm -rf -- \(shellQuote(entry.path))", serial: serial, timeout: 120)
        guard !(try await exists(entry.path, serial: serial)) else {
            throw BridgeError(message: "Android did not delete \(entry.name).")
        }
    }
}

extension AppModel {
    func requestDeleteSelection(_ side: Side) {
        guard !deleting, deletePrompt == nil else { return }
        let selection = side == .mac ? macSelection : androidSelection
        let entries = (side == .mac ? macFiles : androidFiles).filter { selection.contains($0.id) }
        guard !entries.isEmpty else { return }
        if side == .android && !connected {
            alert = "Connect the phone before deleting files."
            return
        }
        do {
            let folder = side == .mac ? macPath : androidPath
            for entry in entries {
                try validateDeletion(entry, folder: folder)
                try ensureNotTransferring(entry, side: side, serial: selectedDevice)
            }
            deletePrompt = DeletePrompt(
                entries: entries, side: side, folder: folder, serial: selectedDevice,
                deviceName: side == .mac ? "Your Mac" : device?.name ?? "Android")
        } catch { alert = error.localizedDescription }
    }
    func ensureNotTransferring(_ entry: FileEntry, side: Side, serial: String) throws {
        func overlaps(_ path: String) -> Bool {
            path == entry.path || path.hasPrefix(entry.path + "/")
                || entry.path.hasPrefix(path + "/")
        }
        let busy = transfers.contains { transfer in
            guard [.waiting, .running, .verifying, .deciding].contains(transfer.state) else {
                return false
            }
            if side == .android && transfer.serial != serial { return false }
            let path =
                transfer.from == side
                ? transfer.source.path
                : transfer.destination
                    ?? childPath(transfer.destinationFolder, transfer.source.name)
            return overlaps(path)
        }
        guard !busy else {
            throw BridgeError(
                message:
                    "\(entry.name) is part of an active transfer. Finish or cancel it before deleting."
            )
        }
    }
    func confirmDeletion(_ prompt: DeletePrompt) {
        guard deletePrompt?.id == prompt.id, !deleting else { return }
        deletePrompt = nil
        deleting = true
        let service = adb
        Task {
            var removed = 0
            do {
                for entry in prompt.entries {
                    try validateDeletion(entry, folder: prompt.folder)
                    try ensureNotTransferring(entry, side: prompt.side, serial: prompt.serial)
                    if prompt.side == .mac {
                        try await Task.detached {
                            try FileManager.default.trashItem(
                                at: URL(fileURLWithPath: entry.path), resultingItemURL: nil)
                        }.value
                    } else {
                        guard devices.contains(where: { $0.id == prompt.serial && $0.ready }) else {
                            throw BridgeError(
                                message: "The phone disconnected. Remaining files were kept.")
                        }
                        try await service.delete(
                            entry, folder: prompt.folder, serial: prompt.serial)
                    }
                    removed += 1
                }
            } catch {
                alert =
                    "\(removed) of \(prompt.entries.count) items removed. "
                    + error.localizedDescription
            }
            deleting = false
            if prompt.side == .mac { loadMac() } else { loadAndroid() }
        }
    }
}

struct DeleteConfirmation: View {
    let prompt: DeletePrompt
    @EnvironmentObject private var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(prompt.side == .mac ? "Move to Trash?" : "Delete permanently?").font(.headline)
            Text(
                prompt.entries.count == 1
                    ? "“\(prompt.entries[0].name)” on \(prompt.deviceName)"
                    : "\(prompt.entries.count) selected items on \(prompt.deviceName)")
            Text(
                prompt.side == .mac
                    ? "You can restore these items from the Mac’s Trash."
                    : "The selected files and folders will be removed from the phone. This cannot be undone."
            )
            .font(.callout).foregroundStyle(.secondary)
            Text(prompt.folder).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            HStack {
                Spacer()
                Button("Cancel") { model.deletePrompt = nil }.keyboardShortcut(.cancelAction)
                Button(
                    prompt.side == .mac ? "Move to Trash" : "Delete Permanently", role: .destructive
                ) {
                    model.confirmDeletion(prompt)
                }
            }
        }.padding(24).frame(width: 440)
    }
}
