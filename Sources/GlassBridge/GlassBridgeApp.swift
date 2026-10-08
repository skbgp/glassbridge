import AppKit
import SwiftUI

@main struct GlassBridgeApp: App {
    @StateObject private var model = AppModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene {
        WindowGroup("GlassBridge") {
            ContentView().environmentObject(model)
                .frame(minWidth: 940, minHeight: 620)
                .task {
                    delegate.model = model
                    model.start()
                }
        }
        .defaultSize(width: 1160, height: 780)
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Mac Folder…") { model.chooseMacFolder() }.keyboardShortcut("o")
            }
            CommandMenu("Transfer") {
                Button("Send Selection to Android") { model.enqueueSelection(.mac) }
                    .keyboardShortcut(
                        "r", modifiers: [.command, .shift]
                    ).disabled(!model.connected || model.macSelection.isEmpty)
                Button("Save Selection to Mac") { model.enqueueSelection(.android) }
                    .keyboardShortcut(
                        "l", modifiers: [.command, .shift]
                    ).disabled(!model.connected || model.androidSelection.isEmpty)
                Divider()
                Button("Refresh Files") {
                    model.loadMac()
                    model.loadAndroid()
                }.keyboardShortcut("r")
                Toggle("Show Hidden Files", isOn: $model.showHidden).keyboardShortcut(
                    ".", modifiers: [.command, .shift])
                Toggle("Show Transfers", isOn: $model.showTransfers).keyboardShortcut("j")
            }
        }
        Settings { SettingsView().environmentObject(model) }
    }
}
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    weak var model: AppModel?
    private var quitting = false
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if model?.deleting == true {
            let alert = NSAlert()
            alert.messageText = "Files are still being removed"
            alert.informativeText = "Keep GlassBridge open until this finishes."
            alert.addButton(withTitle: "Keep Open")
            alert.runModal()
            return .terminateCancel
        }
        guard !quitting, let model, model.activeCount > 0 else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Transfers are still running"
        alert.informativeText =
            "Keep GlassBridge open to finish copying, or cancel the transfers and quit."
        alert.addButton(withTitle: "Keep Transferring")
        alert.addButton(withTitle: "Cancel Transfers and Quit")
        if alert.runModal() == .alertFirstButtonReturn {
            sender.windows.first?.makeKeyAndOrderFront(nil)
            return .terminateCancel
        }
        quitting = true
        Task {
            await model.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
