import SwiftUI
import TaskCore

private typealias ChatState<T> = SwiftUI.State<T>

struct CodexProjectSettings: View {
    static let folderKey = "codexDefaultProjectFolder"
    static let idKey = "codexDefaultProjectID"
    @AppStorage(Self.folderKey) private var folder = ""
    @AppStorage(Self.idKey) private var projectID = ""

    var body: some View {
        Form {
            Section("Default project for new Codex task chats") {
                LabeledContent("Project folder") {
                    Text(folder.isEmpty ? "Use task workspace" : folder)
                        .lineLimit(2).truncationMode(.middle).help(folder)
                    Button("Choose…") {
                        let panel = NSOpenPanel()
                        panel.canChooseFiles = false
                        panel.canChooseDirectories = true
                        panel.allowsMultipleSelection = false
                        if panel.runModal() == .OK, let url = panel.url, url.path != folder {
                            folder = url.path
                            projectID = ""
                        }
                    }
                }
                if !folder.isEmpty {
                    TextField("Codex project ID", text: $projectID, prompt: Text("Optional"))
                    Text("Use the project ID when multiple Codex projects share this folder.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Use task workspace instead") { folder = ""; projectID = "" }
                }
            }
        }.formStyle(.grouped).frame(width: 510).fixedSize(horizontal: false, vertical: true)
    }
}

struct ChatSetupView: View {
    let task: WorkItem
    @EnvironmentObject var desk: Desk
    @Environment(\.dismiss) private var dismiss
    @ChatState private var input = ""
    @ChatState private var pending = false
    @ChatState private var message = ""
    private func run(_ body: () throws -> Void) {
        do { try body() } catch { message = error.localizedDescription }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Codex chat for " + task.label).font(.title2.bold())
            Text(task.title)
            TextField("Existing thread ID or codex://threads/ link", text: $input).textFieldStyle(.roundedBorder)
            if pending {
                Text("A setup composer is open. Send its prefilled message to finish linking, or paste the existing chat link above.")
                Button("Cancel unfinished setup") { run { try desk.reviewStore().cancelSetup(task.id); pending = false } }
            }
            if !message.isEmpty { Text(message).foregroundStyle(Ink.danger) }
            HStack {
                Button("Close") { dismiss() }
                Spacer()
                if !pending {
                    Button("New Codex chat") { run { try desk.startSetup(task); dismiss() } }
                }
                Button("Link existing chat") {
                    run {
                        try desk.reviewStore().bindChat(task.id, address: ChatAddress(input))
                        dismiss()
                        desk.open(task)
                    }
                }.disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(22).frame(width: 490)
        .onAppear { run { pending = try desk.reviewStore().setupPending(task.id) } }
    }
}

struct BrainUpdatesView: View {
    @EnvironmentObject var desk: Desk
    var body: some View {
        VStack(alignment: .leading) {
            Text("Brain Updates").font(.title.bold()).padding()
            if desk.results.isEmpty {
                ContentUnavailableView("No task results yet", systemImage: "bell")
            } else {
                List(desk.results) { r in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            if r.unread { Image(systemName: "circle.fill").font(.caption2).foregroundStyle(Ink.info).accessibilityLabel("Unread") }
                            Text(r.title).font(.headline)
                            Spacer()
                            Button("Open in Codex") { desk.openResult(r) }
                        }
                        Text(r.note.work)
                        Text(r.note.result).fontWeight(.medium)
                        Text("Next · " + r.note.next).foregroundStyle(.secondary)
                    }.padding(.vertical, 6)
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
