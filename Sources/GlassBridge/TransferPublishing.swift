import Foundation

func localPathExists(_ path: String) -> Bool {
    (try? FileManager.default.attributesOfItem(atPath: path)) != nil
}
func localTransferBytes(_ path: String, directory: Bool) -> Int64 {
    let fm = FileManager.default
    if !directory {
        return (try? fm.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0
    }
    guard
        let walker = fm.enumerator(
            at: URL(fileURLWithPath: path),
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey])
    else { return 0 }
    var total: Int64 = 0
    for case let url as URL in walker {
        if let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
            values.isRegularFile == true
        {
            total += Int64(values.fileSize ?? 0)
        }
    }
    return total
}
/// The old item survives until verification finishes. Failed publication restores it.
func publishLocal(staging: String, destination: String, replacing: Bool) throws -> String? {
    let fm = FileManager.default
    guard replacing && localPathExists(destination) else {
        try fm.moveItem(atPath: staging, toPath: destination)
        return nil
    }
    let backup = childPath(
        (destination as NSString).deletingLastPathComponent,
        ".glassbridge-backup-" + UUID().uuidString)
    try fm.moveItem(atPath: destination, toPath: backup)
    do { try fm.moveItem(atPath: staging, toPath: destination) } catch {
        do { try fm.moveItem(atPath: backup, toPath: destination) } catch {
            throw BridgeError(
                message:
                    "Could not publish the copy or restore the original. The original is preserved at \(backup)."
            )
        }
        throw error
    }
    do {
        try fm.removeItem(atPath: backup)
        return nil
    } catch { return "Copy complete; the original backup remains at \(backup)" }
}
extension ADB {
    func transferredBytes(_ path: String, directory: Bool, serial: String) async throws -> Int64 {
        let quoted = shellQuote(path)
        let script =
            directory
            ? "if [ -d \(quoted) ]; then total=0; for size in $(find \(quoted) -type f -exec stat -c %s {} + 2>/dev/null); do total=$((total+size)); done; printf '%s' \"$total\"; else printf 0; fi"
            : "if [ -f \(quoted) ]; then stat -c %s \(quoted); else printf 0; fi"
        let data = try await shell(script, serial: serial, timeout: 4)
        guard
            let bytes = Int64(
                String(decoding: data, as: UTF8.self).trimmingCharacters(
                    in: .whitespacesAndNewlines)),
            bytes >= 0
        else { throw BridgeError(message: "Could not read transfer progress.") }
        return bytes
    }
    func publish(staging: String, destination: String, replacing: Bool, serial: String) async throws
        -> String?
    {
        let backup = childPath(
            (destination as NSString).deletingLastPathComponent,
            ".glassbridge-backup-" + UUID().uuidString)
        let script = """
            source=\(shellQuote(staging)); target=\(shellQuote(destination)); backup=\(shellQuote(backup)); had=0
            if [ -e "$target" ] || [ -L "$target" ]; then
              \(replacing ? ":" : "echo 'An item appeared at the destination. Retry to choose what to do.' >&2; exit 1")
              mv "$target" "$backup" || exit 1
              had=1
            fi
            if [ ! -e "$target" ] && [ ! -L "$target" ] && mv -n "$source" "$target" && [ ! -e "$source" ]; then
              if [ "$had" = 1 ]; then rm -rf "$backup" || printf 'Original backup remains at %s' "$backup"; fi
              exit 0
            fi
            if [ "$had" = 1 ]; then
              if [ ! -e "$target" ] && [ ! -L "$target" ]; then
                mv -n "$backup" "$target" || { echo "Original preserved at $backup" >&2; exit 1; }
              else echo "Original preserved at $backup" >&2
              fi
            fi
            echo 'Could not publish the verified copy.' >&2
            exit 1
            """
        let data = try await shell(script, serial: serial)
        let message = String(decoding: data, as: UTF8.self).trimmingCharacters(
            in: .whitespacesAndNewlines)
        return message.isEmpty ? nil : message
    }
}
