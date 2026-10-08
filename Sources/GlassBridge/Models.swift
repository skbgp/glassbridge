import Foundation
import UniformTypeIdentifiers

struct Device: Identifiable, Equatable, Sendable {
    let id: String
    let state: String
    let name: String
    var ready: Bool { state == "device" }
}
struct FileEntry: Identifiable, Hashable, Codable, Sendable {
    let path: String
    let name: String
    let directory: Bool
    let symbolicLink: Bool
    let size: Int64
    let modified: Date
    var id: String { path }
    var icon: String {
        if directory { return "folder.fill" }
        switch URL(fileURLWithPath: name).pathExtension.lowercased() {
        case "jpg", "jpeg", "png", "heic", "webp", "gif": return "photo"
        case "mp4", "mov", "mkv", "webm": return "film"
        case "mp3", "wav", "flac", "m4a": return "music.note"
        case "zip", "tar", "gz", "7z": return "doc.zipper"
        case "pdf": return "doc.richtext"
        default: return "doc"
        }
    }
}
enum Side: String, Codable, Sendable { case mac, android }
struct DragPayload: Codable, Sendable {
    let side: Side
    let entries: [FileEntry]
    let serial: String?
}
extension UTType {
    static let macBridgeItems = UTType(exportedAs: "com.glassbridge.mac-items")
    static let androidBridgeItems = UTType(exportedAs: "com.glassbridge.android-items")
}
enum TransferState: String, Sendable {
    case waiting = "Queued"
    case running = "Copying"
    case verifying = "Checking"
    case done = "Complete"
    case failed = "Failed"
    case cancelled = "Cancelled"
    case skipped = "Skipped"
    case deciding = "Awaiting choice"
}
struct Transfer: Identifiable, Sendable {
    let id: UUID
    let source: FileEntry
    let from: Side
    let serial: String
    let destinationFolder: String
    let deviceName: String
    var state: TransferState = .waiting
    var progress: Double?
    var totalBytes: Int64 = 0
    var transferredBytes: Int64 = 0
    var bytesPerSecond: Double = 0
    var secondsRemaining: Double?
    var detail = "Waiting to transfer"
    var destination: String?
    var started: Date?
}
enum ConflictResolution: Sendable { case replace, keepBoth, skip, cancel }
struct ConflictPrompt: Identifiable, Sendable {
    let id: UUID
    let name: String
    let destination: String
    let directory: Bool
    let destinationName: String
}
func remainingTime(_ seconds: Double) -> String {
    let value = max(1, Int(seconds.rounded(.up)))
    if value < 60 { return "\(value)s remaining" }
    if value < 3600 { return "\(value / 60)m \(value % 60)s remaining" }
    return "\(value / 3600)h \((value % 3600) / 60)m remaining"
}
struct BridgeError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
func childPath(_ parent: String, _ name: String) -> String {
    parent.hasSuffix("/") ? parent + name : parent + "/" + name
}
func readableSize(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}
func sortedEntries(_ entries: [FileEntry]) -> [FileEntry] {
    entries.sorted { a, b in
        a.directory != b.directory
            ? a.directory : a.name.localizedStandardCompare(b.name) == .orderedAscending
    }
}
func parseDevices(_ text: String) -> [Device] {
    text.split(separator: "\n").compactMap { line in
        let fields = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard fields.count >= 2, !line.hasPrefix("List "), !line.hasPrefix("*"),
            ["device", "offline", "unauthorized", "recovery", "sideload", "no"].contains(fields[1])
        else { return nil }
        let model = fields.first(where: { $0.hasPrefix("model:") })?.dropFirst(6)
        return Device(
            id: fields[0], state: fields[1],
            name: model.map { String($0).replacingOccurrences(of: "_", with: " ") } ?? fields[0])
    }
}
func parseRemoteListing(_ data: Data, parent: String) throws -> [FileEntry] {
    if data.isEmpty { return [] }
    var fields = data.split(separator: 0, omittingEmptySubsequences: false).map {
        String(decoding: $0, as: UTF8.self)
    }
    if fields.last == "" { fields.removeLast() }
    guard fields.count % 4 == 0 else {
        throw BridgeError(
            message: "The phone returned an incomplete folder listing. Refresh to try again.")
    }
    var result: [FileEntry] = []
    for i in stride(from: 0, to: fields.count, by: 4) {
        let name = fields[i]
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"),
            let size = Int64(fields[i + 2]), let stamp = Double(fields[i + 3])
        else { throw BridgeError(message: "The phone returned an invalid file entry.") }
        result.append(
            FileEntry(
                path: childPath(parent, name), name: name, directory: fields[i + 1] == "d",
                symbolicLink: fields[i + 1] != "f" && fields[i + 1] != "d", size: size,
                modified: Date(timeIntervalSince1970: stamp)))
    }
    return sortedEntries(result)
}
