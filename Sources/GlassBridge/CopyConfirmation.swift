import SwiftUI

struct CopyConfirmation: View {
    let prompt: CopyPrompt
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(
                prompt.entries.count == 1
                    ? "Copy “\(prompt.entries[0].name)”?"
                    : "Copy \(prompt.entries.count) items?"
            )
            .font(.headline)
            Text("Destination: \(prompt.destinationName)")
            Text(prompt.folder).font(.callout).foregroundStyle(.secondary)
                .textSelection(.enabled).lineLimit(4)
            HStack {
                Spacer()
                Button("Cancel") { model.copyPrompt = nil }.keyboardShortcut(.cancelAction)
                Button("Copy") { model.confirmCopy(prompt) }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 420)
    }
}
