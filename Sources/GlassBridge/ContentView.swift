import AppKit
import SwiftUI
import UniformTypeIdentifiers

private let accent = Color(red: 0.16, green: 0.44, blue: 0.86)

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showConnectionHelp = false
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                sidebar.frame(width: 185)
                Divider()
                HSplitView {
                    BrowserPane(side: .mac).frame(minWidth: 330, maxHeight: .infinity)
                    BrowserPane(side: .android).frame(minWidth: 330, maxHeight: .infinity)
                }
            }
            if model.showTransfers {
                Divider()
                transferShelf.frame(height: 188)
            }
            Divider()
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
        .background(WindowLayoutAnchor())
        .tint(accent)
        .alert(
            "GlassBridge",
            isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })
        ) {
            Button("OK") { model.alert = nil }
        } message: {
            Text(model.alert ?? "")
        }
        .sheet(item: $model.conflict) { prompt in
            ConflictSheet(prompt: prompt).environmentObject(model)
        }
        .sheet(isPresented: $showConnectionHelp) { ConnectionHelp().frame(width: 480).padding(32) }
        .toolbar {
            connectionToolbar
            ToolbarItem(placement: .automatic) {
                Button {
                    model.showTransfers.toggle()
                } label: {
                    Label("Transfers", systemImage: "arrow.up.arrow.down")
                }
                .help("Show or hide the transfer queue (⌘J)")
            }
            ToolbarItem(placement: .automatic) {
                Button {
                    model.loadMac()
                    model.loadAndroid()
                    Task { await model.refreshDevices() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Refresh files (⌘R)")
            }
            ToolbarItem(placement: .automatic) {
                Button {
                    showConnectionHelp = true
                } label: {
                    Label("Connection help", systemImage: "questionmark.circle")
                }
            }
        }
    }
    @ToolbarContentBuilder private var connectionToolbar: some ToolbarContent {
        if #available(macOS 26.0, *) {
            connectionItem.sharedBackgroundVisibility(.hidden)
        } else {
            connectionItem
        }
    }
    private var connectionItem: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            HStack(spacing: 7) {
                Circle().fill(model.connected ? Color.green : Color.secondary.opacity(0.5)).frame(
                    width: 6, height: 6)
                if !model.devices.isEmpty {
                    Menu {
                        ForEach(model.devices) { device in
                            Button {
                                model.selectDevice(device.id)
                            } label: {
                                Text(
                                    device.name + (device.ready ? "" : " · " + device.state)
                                        + (device.id == model.selectedDevice ? " ✓" : ""))
                            }
                        }
                    } label: {
                        Text(model.device?.name ?? "Choose device").font(
                            .system(size: 12, weight: .medium))
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                } else {
                    Text("No device connected").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }.fixedSize(horizontal: true, vertical: false).padding(.horizontal, 4)
        }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("ON YOUR MAC").font(.system(size: 10, weight: .semibold)).foregroundStyle(
                .secondary
            )
            .padding(.horizontal, 14).padding(.top, 21).padding(.bottom, 6)
            shortcut(
                "Home", "house", path: FileManager.default.homeDirectoryForCurrentUser.path,
                side: .mac)
            shortcut(
                "Desktop", "menubar.dock.rectangle", path: NSHomeDirectory() + "/Desktop",
                side: .mac)
            shortcut(
                "Downloads", "arrow.down.circle", path: NSHomeDirectory() + "/Downloads", side: .mac
            )
            shortcut("Documents", "doc", path: NSHomeDirectory() + "/Documents", side: .mac)
            Button {
                model.chooseMacFolder()
            } label: {
                Label("Choose folder…", systemImage: "folder.badge.plus").font(.system(size: 12))
                    .frame(
                        maxWidth: .infinity, alignment: .leading
                    ).padding(.vertical, 8).padding(.horizontal, 14)
            }.buttonStyle(.plain)
            Text("ON ANDROID").font(.system(size: 10, weight: .semibold)).foregroundStyle(
                .secondary
            )
            .padding(.horizontal, 14).padding(.top, 23).padding(.bottom, 6)
            shortcut("Internal storage", "internaldrive", path: "/sdcard", side: .android)
            shortcut("Downloads", "arrow.down.circle", path: "/sdcard/Download", side: .android)
            shortcut("Camera", "camera", path: "/sdcard/DCIM", side: .android)
            shortcut("Pictures", "photo", path: "/sdcard/Pictures", side: .android)
            shortcut("Documents", "doc", path: "/sdcard/Documents", side: .android)
            Spacer()
            VStack(alignment: .leading, spacing: 6) {
                Label("You choose", systemImage: "doc.on.doc").font(
                    .system(size: 11, weight: .medium))
                Text("If a name is already used, choose Replace, Keep Both, or Skip.").font(
                    .system(size: 11)
                ).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(14).background(
                .quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10)
            )
            .padding(10)
        }.background(.thinMaterial)
    }
    private func shortcut(_ title: String, _ icon: String, path: String, side: Side) -> some View {
        let selected = (side == .mac ? model.macPath : model.androidPath) == path
        return Button {
            if side == .mac { model.loadMac(path) } else { model.loadAndroid(path) }
        } label: {
            Label(title, systemImage: icon).font(
                .system(size: 12, weight: selected ? .medium : .regular)
            )
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(
                .vertical, 8
            )
            .background(
                selected ? accent.opacity(0.11) : .clear, in: RoundedRectangle(cornerRadius: 7)
            )
            .contentShape(Rectangle())
        }.buttonStyle(.plain).padding(.horizontal, 5).disabled(side == .android && !model.connected)
    }
    private var transferShelf: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Transfers").font(.system(size: 12, weight: .semibold))
                if model.activeCount > 0 {
                    Text("\(model.activeCount) active").font(.system(size: 11)).foregroundStyle(
                        .secondary)
                }
                Spacer()
                Button("Clear finished") {
                    model.transfers.removeAll {
                        [.done, .cancelled, .failed, .skipped].contains($0.state)
                    }
                }.font(.system(size: 11)).buttonStyle(.plain).foregroundStyle(.secondary)
                    .disabled(
                        !model.transfers.contains {
                            [.done, .cancelled, .failed, .skipped].contains($0.state)
                        })
            }.padding(.horizontal, 20).padding(.vertical, 12)
            Divider()
            if model.transfers.isEmpty {
                HStack(spacing: 14) {
                    Image(systemName: "arrow.left.arrow.right").font(
                        .system(size: 23, weight: .light)
                    )
                    .foregroundStyle(.tertiary)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Ready when you are").font(.system(size: 12, weight: .medium))
                        Text(
                            "Drag files between panes, or select items and use the transfer button."
                        ).font(
                            .system(size: 12)
                        ).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.transfers) { item in
                            TransferRow(item: item)
                            Divider().padding(.leading, 60)
                        }
                    }
                }
            }
        }.background(Color(nsColor: .controlBackgroundColor))
    }
    private var footer: some View {
        HStack(spacing: 7) {
            Image(systemName: "cable.connector").font(.system(size: 11))
            Text(
                model.connected
                    ? "Connected through ADB" : "Connect with USB · Enable USB debugging on Android"
            )
            Spacer()
            Text("Files and folders · Both directions")
        }.font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 18).padding(
            .vertical, 9)
    }
}

struct BrowserPane: View {
    let side: Side
    @EnvironmentObject private var model: AppModel
    @State private var query = ""
    @State private var targeted = false
    @State private var editPath = false
    @State private var enteredPath = ""
    private var files: [FileEntry] { side == .mac ? model.macFiles : model.androidFiles }
    private var path: String { side == .mac ? model.macPath : model.androidPath }
    private var busy: Bool { side == .mac ? model.macBusy : model.androidBusy }
    private var error: String? { side == .mac ? model.macError : model.androidError }
    private var selection: Binding<Set<String>> {
        side == .mac ? $model.macSelection : $model.androidSelection
    }
    private var visible: [FileEntry] {
        files.filter {
            (model.showHidden || !$0.name.hasPrefix("."))
                && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query))
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            header
            HStack(spacing: 7) {
                Button {
                    model.goUp(side)
                    query = ""
                } label: {
                    Image(systemName: "chevron.up").font(.system(size: 11, weight: .semibold))
                }.buttonStyle(.plain).help("Parent folder").disabled(path == "/")
                Button {
                    enteredPath = path
                    editPath = true
                } label: {
                    Text(path).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        .truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain).help("Go to a folder")
                if busy { ProgressView().controlSize(.mini).frame(width: 14) }
            }.padding(.horizontal, 16).padding(.vertical, 10)
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
                TextField("Search this folder", text: $query).textFieldStyle(.plain).font(
                    .system(size: 12))
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }.buttonStyle(.plain)
                }
            }.padding(8).background(
                .quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 7)
            )
            .padding(.horizontal, 14).padding(.bottom, 12)
            Divider()
            HStack {
                Text("Name")
                Spacer()
                Text("Size").frame(width: 68, alignment: .trailing)
            }.font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary).padding(
                .horizontal, 22
            ).padding(.vertical, 8)
            ZStack {
                if side == .android && !model.connected {
                    connectionState
                } else if let error {
                    stateView(
                        "Unable to open folder", subtitle: error, icon: "exclamationmark.folder",
                        retry: true)
                } else {
                    FileTable(
                        entries: visible, path: path, side: side, selection: selection,
                        targeted: $targeted,
                        model: model, open: open)
                    if visible.isEmpty && !busy {
                        stateView(
                            query.isEmpty ? "This folder is empty" : "No matching files",
                            subtitle: query.isEmpty
                                ? "Drop items here to copy them into this folder."
                                : "Try another name.",
                            icon: "folder", retry: false
                        ).allowsHitTesting(false)
                    }
                }
                if targeted && model.connected {
                    RoundedRectangle(cornerRadius: 10).fill(accent.opacity(0.07)).padding(6)
                        .allowsHitTesting(
                            false)
                    RoundedRectangle(cornerRadius: 10).strokeBorder(
                        accent.opacity(0.8), style: StrokeStyle(lineWidth: 2, dash: [6, 4])
                    ).padding(6).allowsHitTesting(false)
                    Text(side == .android ? "Copy to Android" : "Copy to Mac").font(
                        .system(size: 13, weight: .semibold)
                    ).padding(.horizontal, 18).padding(.vertical, 11).background(
                        .regularMaterial, in: Capsule()
                    ).allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onDrop(
                of: side == .android
                    ? [UTType.macBridgeItems, .fileURL] : [UTType.androidBridgeItems],
                isTargeted: $targeted, perform: drop
            )
            .animation(.easeOut(duration: 0.14), value: targeted)
            Divider()
            HStack {
                Text(
                    "\(visible.count) items"
                        + (selection.wrappedValue.isEmpty
                            ? "" : " · \(selection.wrappedValue.count) selected"))
                Spacer()
                Toggle(isOn: $model.showHidden) {
                    Image(systemName: model.showHidden ? "eye" : "eye.slash")
                }.toggleStyle(.button).buttonStyle(.plain).help("Show hidden files")
            }.font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 16).padding(
                .vertical, 10)
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.55))
        .popover(isPresented: $editPath) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Go to folder").font(.headline)
                TextField("Folder path", text: $enteredPath).textFieldStyle(.roundedBorder).frame(
                    width: 360
                ).onSubmit { navigate() }
                HStack {
                    Spacer()
                    Button("Cancel") { editPath = false }
                    Button("Open") { navigate() }.keyboardShortcut(.defaultAction)
                }
            }.padding(18)
        }
        .onChange(of: path) { _, _ in query = "" }
    }
    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: side == .mac ? "laptopcomputer" : "smartphone").font(
                .system(size: 19, weight: .regular)
            ).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(side == .mac ? "Your Mac" : model.device?.name ?? "Android").font(
                    .system(size: 14, weight: .semibold)
                ).lineLimit(1)
                Text(
                    side == .mac
                        ? (path as NSString).lastPathComponent
                        : (path == "/sdcard"
                            ? "Internal storage" : (path as NSString).lastPathComponent)
                ).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            Button {
                model.enqueueSelection(side)
            } label: {
                Image(systemName: side == .mac ? "arrow.right" : "arrow.left").font(
                    .system(size: 12, weight: .semibold)
                ).frame(width: 25, height: 24)
            }.buttonStyle(.bordered).help(
                side == .mac
                    ? "Send selected items to the Android folder"
                    : "Save selected items to the Mac folder"
            )
            .disabled(!model.connected || selection.wrappedValue.isEmpty)
        }.padding(.horizontal, 16).padding(.vertical, 18)
    }
    private var connectionState: some View {
        VStack(spacing: 14) {
            Image(systemName: "cable.connector").font(.system(size: 40, weight: .ultraLight))
                .foregroundStyle(.tertiary)
            Text(
                model.device?.state == "unauthorized"
                    ? "Allow this Mac on your phone"
                    : model.device?.state == "offline"
                        ? "Your phone is offline" : "Connect your Android"
            ).font(.system(size: 16, weight: .medium))
            Text(
                model.connectionError
                    ?? (model.device?.state == "unauthorized"
                        ? "Unlock your phone and accept the USB debugging prompt."
                        : "Connect a USB cable, enable USB debugging,\nand allow this computer on your phone.")
            ).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Button("Check connection") { Task { await model.refreshDevices() } }.buttonStyle(
                .bordered)
        }.padding(30).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private func stateView(_ title: String, subtitle: String, icon: String, retry: Bool)
        -> some View
    {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 32, weight: .ultraLight)).foregroundStyle(
                .tertiary)
            Text(title).font(.system(size: 14, weight: .medium))
            Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
                .multilineTextAlignment(
                    .center
                ).textSelection(.enabled)
            if retry {
                Button("Retry") { if side == .mac { model.loadMac() } else { model.loadAndroid() } }
            }
        }.padding(25).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private func open(_ entry: FileEntry) {
        if entry.directory {
            if side == .mac { model.loadMac(entry.path) } else { model.loadAndroid(entry.path) }
        } else if side == .mac {
            NSWorkspace.shared.open(URL(fileURLWithPath: entry.path))
        }
    }
    private func navigate() {
        guard enteredPath.hasPrefix("/") else {
            model.alert = "Enter an absolute folder path, starting with /."
            return
        }
        if side == .mac { model.loadMac(enteredPath) } else { model.loadAndroid(enteredPath) }
        editPath = false
    }
    private func drop(_ providers: [NSItemProvider]) -> Bool {
        guard model.connected else { return false }
        let targetFolder = path
        let serial = model.selectedDevice
        let internalType = side == .mac ? UTType.androidBridgeItems : UTType.macBridgeItems
        if let internalItem = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(internalType.identifier)
        }) {
            internalItem.loadDataRepresentation(forTypeIdentifier: internalType.identifier) {
                data, _ in
                guard let data,
                    let payload = try? JSONDecoder().decode(DragPayload.self, from: data)
                else {
                    return
                }
                Task { @MainActor in
                    model.receive(payload, on: side, folder: targetFolder, serial: serial)
                }
            }
            return true
        }
        guard side == .android else { return false }
        Task {
            var urls: [URL] = []
            for provider in providers
            where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                let url: URL? = await withCheckedContinuation { continuation in
                    provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) {
                        value, _ in
                        if let url = value as? URL {
                            continuation.resume(returning: url)
                        } else if let data = value as? Data {
                            continuation.resume(
                                returning: URL(dataRepresentation: data, relativeTo: nil))
                        } else {
                            continuation.resume(returning: nil)
                        }
                    }
                }
                if let url, url.isFileURL { urls.append(url) }
            }
            model.receiveLocalURLs(urls, folder: targetFolder, serial: serial)
        }
        return true
    }
}
struct TransferRow: View {
    let item: Transfer
    @EnvironmentObject private var model: AppModel
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.source.icon).font(.system(size: 20)).foregroundStyle(.secondary)
                .frame(
                    width: 28)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(item.source.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Text(
                        item.from == .mac ? "Mac → \(item.deviceName)" : "\(item.deviceName) → Mac"
                    ).font(
                        .system(size: 10)
                    ).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Text(item.state.rawValue).font(.system(size: 10, weight: .medium))
                        .foregroundStyle(
                            item.state == .failed
                                ? Color.red : item.state == .done ? Color.green : Color.secondary)
                }
                if item.state == .running || item.state == .verifying {
                    if let progress = item.progress {
                        ProgressView(value: progress).controlSize(.small)
                    } else {
                        ProgressView().progressViewStyle(.linear).controlSize(.small)
                    }
                }
                if item.state == .running && item.totalBytes > 0 {
                    HStack(spacing: 10) {
                        Text(
                            "\(readableSize(item.transferredBytes)) of \(readableSize(item.totalBytes))"
                        )
                        Text("\(Int((item.progress ?? 0) * 100))%").fontWeight(.medium)
                        Spacer()
                        if item.bytesPerSecond > 0 {
                            Text(readableSize(Int64(item.bytesPerSecond)) + "/s")
                        }
                        if let remaining = item.secondsRemaining { Text(remainingTime(remaining)) }
                    }.font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                } else {
                    Text(item.detail).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(
                        1
                    ).help(
                        item.detail)
                }
            }
            if [.waiting, .running, .verifying, .deciding].contains(item.state) {
                Button {
                    model.cancel(item.id)
                } label: {
                    Image(systemName: "xmark.circle").font(.system(size: 16))
                }.buttonStyle(.plain).help("Cancel transfer")
            } else if [.failed, .cancelled].contains(item.state) {
                Button {
                    model.retry(item.id)
                } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 14))
                }.buttonStyle(.plain).help("Retry transfer")
            } else if item.from == .android, let path = item.destination {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                } label: {
                    Image(systemName: "magnifyingglass").font(.system(size: 14))
                }.buttonStyle(.plain).help("Show in Finder")
            } else {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(
                    .system(size: 16))
            }
        }.padding(.horizontal, 20).padding(.vertical, 12)
    }
}
struct ConnectionHelp: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Image(systemName: "smartphone").font(.system(size: 32, weight: .light)).foregroundStyle(
                accent)
            Text("Connect your phone").font(.title2.weight(.semibold))
            step(
                "1", "Enable Developer options",
                "On Android, open Settings → About phone and tap Build number seven times. The exact location varies by phone."
            )
            step("2", "Turn on USB debugging", "Open Developer options and enable USB debugging.")
            step(
                "3", "Connect and allow",
                "Use a USB data cable. Unlock the phone and accept the “Allow USB debugging?” prompt for this Mac."
            )
            Text(
                "GlassBridge can browse shared storage and other folders your phone permits ADB to access. Protected app data may be unavailable."
            ).font(.system(size: 12)).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Got it") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
    }
    private func step(_ number: String, _ title: String, _ body: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number).font(.system(size: 12, weight: .semibold)).frame(width: 26, height: 26)
                .background(.quaternary, in: Circle())
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(body).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(
                    horizontal: false, vertical: true)
            }
        }
    }
}
struct ConflictSheet: View {
    let prompt: ConflictPrompt
    @EnvironmentObject private var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: "doc.on.doc").font(.system(size: 28, weight: .light)).foregroundStyle(
                accent)
            Text("“\(prompt.name)” already exists").font(.system(size: 18, weight: .semibold))
                .fixedSize(
                    horizontal: false, vertical: true)
            Text(
                "An item with this name is already on \(prompt.destinationName). Choose what to do with this copy."
            ).font(.system(size: 13)).foregroundStyle(.secondary)
            Text(
                prompt.directory
                    ? "Replace exchanges the entire existing folder, including its contents, after the new copy has been verified. Keep Both gives the new folder a numbered name."
                    : "Replace preserves the existing item until the new copy has been verified. Keep Both gives the copy a numbered name."
            ).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(
                horizontal: false, vertical: true)
            Text(prompt.destination).font(.system(size: 10, design: .monospaced)).foregroundStyle(
                .secondary
            ).textSelection(.enabled).lineLimit(2)
            HStack {
                Button("Cancel Transfer") { model.resolveConflict(.cancel) }.keyboardShortcut(
                    .cancelAction)
                Spacer()
                Button("Skip") { model.resolveConflict(.skip) }
                Button("Keep Both") { model.resolveConflict(.keepBoth) }.keyboardShortcut(
                    .defaultAction)
                Button("Replace", role: .destructive) { model.resolveConflict(.replace) }
            }
        }.padding(28).frame(width: 530)
    }
}
struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        Form {
            Section("Android Debug Bridge") {
                Text(model.adbPath.isEmpty ? "ADB was not found." : model.adbPath).font(
                    .system(size: 11, design: .monospaced)
                ).textSelection(.enabled)
                Button("Choose another ADB executable…") { model.chooseADB() }
            }
            Section("Browsing") { Toggle("Show hidden files", isOn: $model.showHidden) }
            Section("Transfers") {
                Text(
                    "When a name is already used, choose Replace, Keep Both, or Skip. Live progress measures bytes in the temporary copy. Copies are checked before their final names appear."
                ).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped).frame(width: 520, height: 330)
    }
}

/// Keep the content below the native title bar, including on newer macOS releases.
private struct WindowLayoutAnchor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { AnchorView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
    private final class AnchorView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.styleMask.remove(.fullSizeContentView)
            window.titlebarAppearsTransparent = false
        }
    }
}
