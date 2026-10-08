import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// AppKit's file table supplies native selection, scrolling, and drag sessions.
struct FileTable: NSViewRepresentable {
    let entries: [FileEntry]
    let path: String
    let side: Side
    @Binding var selection: Set<String>
    @Binding var targeted: Bool
    @ObservedObject var model: AppModel
    let open: (FileEntry) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        let table = DropTable()
        table.headerView = nil
        table.backgroundColor = .clear
        table.style = .inset
        table.rowHeight = 36
        table.intercellSpacing = NSSize(width: 10, height: 1)
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        // Drag vertically to select rows; drag horizontally to copy between panes.
        table.verticalMotionCanBeginDrag = false
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        let name = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        name.minWidth = 140
        name.resizingMask = .autoresizingMask
        table.addTableColumn(name)
        let size = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("size"))
        size.width = 82
        size.minWidth = 82
        size.maxWidth = 82
        size.resizingMask = []
        table.addTableColumn(size)
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.doubleClick(_:))
        table.setDraggingSourceOperationMask(.copy, forLocal: true)
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.exited = { context.coordinator.parent.targeted = false }
        let type = side == .mac ? UTType.androidBridgeItems : UTType.macBridgeItems
        table.registerForDraggedTypes(
            [NSPasteboard.PasteboardType(type.identifier)] + (side == .android ? [.fileURL] : []))
        table.menu = NSMenu()
        table.menu?.autoenablesItems = false
        table.menu?.delegate = context.coordinator
        scroll.documentView = table
        context.coordinator.table = table
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let table = coordinator.table else { return }
        coordinator.applying = true
        if coordinator.entries != entries {
            coordinator.entries = entries
            table.reloadData()
        }
        let indexes = IndexSet(
            entries.enumerated().compactMap { selection.contains($0.element.id) ? $0.offset : nil })
        if indexes != table.selectedRowIndexes {
            table.selectRowIndexes(indexes, byExtendingSelection: false)
        }
        if coordinator.path != path {
            coordinator.path = path
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        coordinator.applying = false
    }
    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        var parent: FileTable
        var entries: [FileEntry] = []
        var path = ""
        var applying = false
        weak var table: NSTableView?
        init(_ parent: FileTable) { self.parent = parent }
        func numberOfRows(in tableView: NSTableView) -> Int { entries.count }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int)
            -> NSView?
        {
            guard entries.indices.contains(row) else { return nil }
            let entry = entries[row]
            let identifier = tableColumn!.identifier
            if let existing = tableView.makeView(withIdentifier: identifier, owner: self)
                as? NSTableCellView
            {
                configure(existing, entry: entry, name: identifier.rawValue == "name")
                return existing
            }
            let cell = NSTableCellView()
            cell.identifier = identifier
            let text = NSTextField(labelWithString: "")
            text.translatesAutoresizingMaskIntoConstraints = false
            text.lineBreakMode = .byTruncatingMiddle
            text.font = .systemFont(ofSize: identifier.rawValue == "name" ? 12 : 10)
            cell.addSubview(text)
            cell.textField = text
            if identifier.rawValue == "name" {
                let icon = NSImageView()
                icon.translatesAutoresizingMaskIntoConstraints = false
                icon.imageScaling = .scaleProportionallyDown
                cell.addSubview(icon)
                cell.imageView = icon
                NSLayoutConstraint.activate([
                    icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 3),
                    icon.widthAnchor.constraint(equalToConstant: 24),
                    icon.heightAnchor.constraint(equalToConstant: 24),
                    icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 9),
                    text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                    text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                ])
            } else {
                text.alignment = .right
                text.textColor = .secondaryLabelColor
                NSLayoutConstraint.activate([
                    text.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
                    text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                    text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                ])
            }
            configure(cell, entry: entry, name: identifier.rawValue == "name")
            return cell
        }
        private func configure(_ cell: NSTableCellView, entry: FileEntry, name: Bool) {
            cell.textField?.stringValue =
                name ? entry.name : entry.directory ? "—" : readableSize(entry.size)
            cell.toolTip = entry.name
            if name {
                cell.imageView?.image = NSImage(
                    systemSymbolName: entry.icon,
                    accessibilityDescription: entry.directory ? "Folder" : "File")
                cell.imageView?.contentTintColor =
                    entry.directory ? NSColor.systemBlue : .secondaryLabelColor
            }
        }
        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !applying, let table else { return }
            parent.selection = Set(
                table.selectedRowIndexes.compactMap {
                    entries.indices.contains($0) ? entries[$0].id : nil
                })
        }
        @objc func doubleClick(_ sender: NSTableView) {
            guard entries.indices.contains(sender.clickedRow) else { return }
            parent.open(entries[sender.clickedRow])
        }
        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int)
            -> NSPasteboardWriting?
        {
            guard entries.indices.contains(row) else { return nil }
            let selected = tableView.selectedRowIndexes
            let items =
                selected.contains(row)
                ? selected.compactMap { entries.indices.contains($0) ? entries[$0] : nil }
                : [entries[row]]
            let payload = DragPayload(
                side: parent.side, entries: items,
                serial: parent.side == .android ? parent.model.selectedDevice : nil)
            let writer = NSPasteboardItem()
            guard let data = try? JSONEncoder().encode(payload) else { return nil }
            writer.setData(
                data,
                forType: NSPasteboard.PasteboardType(
                    (parent.side == .mac ? UTType.macBridgeItems : UTType.androidBridgeItems)
                        .identifier))
            if parent.side == .mac {
                writer.setString(
                    URL(fileURLWithPath: entries[row].path).absoluteString, forType: .fileURL)
            }
            return writer
        }
        func tableView(
            _ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
            proposedDropOperation operation: NSTableView.DropOperation
        ) -> NSDragOperation {
            guard parent.model.connected else { return [] }
            let type = NSPasteboard.PasteboardType(
                (parent.side == .mac ? UTType.androidBridgeItems : UTType.macBridgeItems).identifier
            )
            let hasInternal = info.draggingPasteboard.availableType(from: [type]) != nil
            let hasFinder =
                parent.side == .android
                && info.draggingPasteboard.availableType(from: [.fileURL]) != nil
            guard hasInternal || hasFinder else { return [] }
            let hoveredRow = tableView.row(
                at: tableView.convert(info.draggingLocation, from: nil))
            if entries.indices.contains(hoveredRow), entries[hoveredRow].directory {
                tableView.setDropRow(hoveredRow, dropOperation: .on)
            } else {
                tableView.setDropRow(-1, dropOperation: .above)
            }
            parent.targeted = true
            return .copy
        }
        func tableView(
            _ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
            dropOperation operation: NSTableView.DropOperation
        ) -> Bool {
            parent.targeted = false
            let folder =
                operation == .on && entries.indices.contains(row) && entries[row].directory
                ? entries[row].path : parent.path
            let type = NSPasteboard.PasteboardType(
                (parent.side == .mac ? UTType.androidBridgeItems : UTType.macBridgeItems).identifier
            )
            if let data = info.draggingPasteboard.data(forType: type),
                let payload = try? JSONDecoder().decode(DragPayload.self, from: data)
            {
                parent.model.receive(
                    payload, on: parent.side, folder: folder,
                    serial: parent.model.selectedDevice)
                return true
            }
            if parent.side == .android,
                let urls = info.draggingPasteboard.readObjects(
                    forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
                !urls.isEmpty
            {
                parent.model.receiveLocalURLs(
                    urls, folder: folder, serial: parent.model.selectedDevice)
                return true
            }
            return false
        }
        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let table, entries.indices.contains(table.clickedRow) else { return }
            let clicked = entries[table.clickedRow]
            if !table.selectedRowIndexes.contains(table.clickedRow) {
                table.selectRowIndexes(
                    IndexSet(integer: table.clickedRow), byExtendingSelection: false)
            }
            if clicked.directory {
                let item = NSMenuItem(
                    title: "Open Folder", action: #selector(openClicked), keyEquivalent: "")
                item.target = self
                menu.addItem(item)
            }
            let transfer = NSMenuItem(
                title: parent.side == .mac ? "Send to Android" : "Save to Mac",
                action: #selector(transferSelected), keyEquivalent: "")
            transfer.target = self
            transfer.isEnabled = parent.model.connected
            menu.addItem(transfer)
            let copy = NSMenuItem(
                title: "Copy Path", action: #selector(copyClickedPath), keyEquivalent: "")
            copy.target = self
            menu.addItem(copy)
            if parent.side == .mac {
                let reveal = NSMenuItem(
                    title: "Show in Finder", action: #selector(revealClicked), keyEquivalent: "")
                reveal.target = self
                menu.addItem(reveal)
            }
        }
        @objc private func transferSelected() { parent.model.enqueueSelection(parent.side) }
        @objc private func openClicked() {
            if let table, entries.indices.contains(table.clickedRow) {
                parent.open(entries[table.clickedRow])
            }
        }
        @objc private func copyClickedPath() {
            if let table, entries.indices.contains(table.clickedRow) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entries[table.clickedRow].path, forType: .string)
            }
        }
        @objc private func revealClicked() {
            if let table, entries.indices.contains(table.clickedRow) {
                NSWorkspace.shared.activateFileViewerSelecting([
                    URL(fileURLWithPath: entries[table.clickedRow].path)
                ])
            }
        }
    }
    private final class DropTable: NSTableView {
        var exited: (() -> Void)?
        override func draggingExited(_ sender: NSDraggingInfo?) {
            super.draggingExited(sender)
            exited?()
        }
        override func concludeDragOperation(_ sender: NSDraggingInfo?) {
            super.concludeDragOperation(sender)
            exited?()
        }
    }

}
