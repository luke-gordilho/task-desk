import SwiftUI
import AppKit
import TaskCore

// Select the property wrapper explicitly on SDKs that also expose a State macro.
private typealias EditorState<Value> = SwiftUI.State<Value>

struct TaskEditor: View {
    @EnvironmentObject var desk: Desk
    @Environment(\.dismiss) private var dismiss
    @EditorState private var draft: WorkItem
    @EditorState private var tab = "Task"
    @EditorState private var people: String
    @EditorState private var error = ""
    @FocusState private var focusTitle: Bool

    let proposalSave: ((WorkItem) throws -> Void)?
    init(draft: WorkItem, proposalSave: ((WorkItem) throws -> Void)? = nil) {
        self.proposalSave = proposalSave
        _draft = State(initialValue: draft)
        _people = State(initialValue: draft.collaborators.joined(separator: ", "))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                Text(proposalSave != nil ? "Edit inbox proposal" : draft.id == 0 ? "New task" : "Edit " + draft.label).font(.title2.weight(.semibold))
                TextField("Task title", text: $draft.title).font(.title3.weight(.medium)).textFieldStyle(.roundedBorder).focused($focusTitle)
                Picker("Section", selection: $tab) {
                    ForEach(["Task", "Next actions", "Context"], id: \.self) { Text($0) }
                }.labelsHidden().pickerStyle(.segmented)
            }.padding(20)
            Divider()
            Form {
                switch tab {
                case "Next actions":
                    Section("Next actions") {
                        ActionFields(draft: $draft, suggestions: desk.knownPeople + people.components(separatedBy: ","))
                    }
                case "Context":
                    Section("Task brief") {
                        longField("Context", $draft.context)
                        longField("Done when", $draft.doneWhen)
                        longField("Latest update", $draft.latestUpdate)
                    }
                    Section("Agent handoff") {
                        longField("Sources and files", $draft.references)
                        longField("Agent instructions", $draft.agentInstructions)
                        HStack {
                            TextField("Workspace folder", text: $draft.workspace, prompt: Text("Optional local folder"))
                            Button("Choose…") {
                                let panel = NSOpenPanel()
                                panel.canChooseDirectories = true
                                panel.canChooseFiles = false
                                if panel.runModal() == .OK, let url = panel.url { draft.workspace = url.path }
                            }
                        }
                    }
                default:
                    Section {
                        Picker("Outcome", selection: $draft.outcomeID) {
                            Text("Unassigned").tag(nil as Int?)
                            if let id = draft.outcomeID, !desk.outcomes.contains(where: { $0.id == id }) {
                                Text("Deleted outcome").tag(Optional(id))
                            }
                            ForEach(desk.outcomes) { Text($0.displayName).tag(Optional($0.id)) }
                        }
                        Picker("Status", selection: $draft.status) { ForEach(Status.allCases, id: \.self) { Text($0.rawValue) } }
                        Toggle("Focus", isOn: $draft.focus)
                        Picker("Priority", selection: $draft.priority) { ForEach(Priority.allCases, id: \.self) { Text($0.rawValue) } }
                    }
                    Section("People and work") {
                        TextField("Owner", text: $draft.owner)
                        PeopleField(label: "Collaborators", text: $people, suggestions: desk.knownPeople)
                        GroupFields(draft: $draft)
                    }
                    Section("Dates") {
                        OptionalDate(label: "Due date", value: $draft.dueDate)
                        OptionalDate(label: "Follow up", value: $draft.followUpDate)
                    }
                }
            }.formStyle(.grouped).scrollContentBackground(.hidden).background(Ink.background)
            Divider()
            HStack {
                if !error.isEmpty { Text(error).font(.caption).foregroundStyle(Ink.danger).fixedSize(horizontal: false, vertical: true) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(proposalSave != nil ? "Save proposal" : draft.id == 0 ? "Create task" : "Save changes") {
                    do {
                        draft.collaborators = uniqueNames(people.components(separatedBy: ","))
                        if let proposalSave { try proposalSave(draft) } else { try desk.save(draft) }
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                }.keyboardShortcut(.defaultAction).buttonStyle(PrimaryButton()).disabled(draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.padding(16)
        }
        .background(Ink.surface).foregroundStyle(Ink.text).tint(Ink.control)
        .frame(width: 570, height: 550)
        .onAppear { if draft.id == 0 { focusTitle = true } }
    }
    private func longField(_ label: String, _ value: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.subheadline.weight(.medium))
            TextEditor(text: value).font(.body).frame(minHeight: 55).scrollContentBackground(.hidden)
                .padding(4).background(Ink.surface, in: RoundedRectangle(cornerRadius: 5)).accessibilityLabel(label)
        }
    }
}
struct ActionFields: View {
    @Binding var draft: WorkItem
    let suggestions: [String]
    var body: some View {
        ForEach($draft.actions) { $action in
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Toggle("Completed", isOn: $action.completed).toggleStyle(.checkbox).labelsHidden().accessibilityLabel("Completed")
                    TextField("What needs to happen?", text: $action.title).textFieldStyle(.roundedBorder)
                    Button { draft.actions.removeAll { $0.id == action.id } } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless).help("Remove action")
                }
                HStack {
                    Text("Whose turn?").foregroundStyle(.secondary)
                    TextField("Name, Luke, or Dot", text: $action.assignee).textFieldStyle(.roundedBorder)
                    Menu {
                        ForEach(uniqueNames(["Luke", "Dot", "Claude", draft.owner] + suggestions).sorted(), id: \.self) { name in
                            Button(name) { action.assignee = name }
                        }
                    } label: { Image(systemName: "person.crop.circle") }.fixedSize().help("Choose a person")
                }
            }.padding(.vertical, 4)
        }
        Button { draft.actions.append(ActionItem()) } label: { Label("Add action", systemImage: "plus") }
    }
}

struct GroupFields: View {
    @EnvironmentObject var desk: Desk
    @Binding var draft: WorkItem
    private var groupChoices: [String] {
        uniqueNames(desk.tasks.filter { $0.group.kind == draft.group.kind }.map(\.group.name))
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
    private func selectionMenu<Choices: View>(_ label: String, isEmpty: Bool, @ViewBuilder choices: () -> Choices) -> some View {
        Menu {
            choices()
        } label: {
            Image(systemName: "chevron.down.circle")
        }.menuIndicator(.hidden).fixedSize().disabled(isEmpty).accessibilityLabel(label).help(label)
    }
    var body: some View {
        Picker("Task for", selection: $draft.group.kind) {
            ForEach(GroupKind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }.pickerStyle(.segmented)
        HStack {
            TextField(draft.group.kind.rawValue + " name", text: $draft.group.name)
            selectionMenu("Choose a saved " + draft.group.kind.rawValue.lowercased(), isEmpty: groupChoices.isEmpty) {
                ForEach(groupChoices, id: \.self) { name in
                    Button(name) { draft.group.name = name }
                }
            }
        }
    }
}

struct PeopleField: View {
    let label: String
    @Binding var text: String
    let suggestions: [String]

    var body: some View {
        let selected = uniqueNames(text.components(separatedBy: ","))
        let choices = uniqueNames(selected + suggestions).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        HStack {
            TextField(label, text: $text, prompt: Text("Names separated by commas"))
            Menu {
                ForEach(choices, id: \.self) { name in
                    Toggle(name, isOn: Binding(get: { selected.contains(name) }, set: { include in
                        var names = selected.filter { $0 != name }
                        if include { names.append(name) }
                        text = names.joined(separator: ", ")
                    }))
                }
            } label: { Image(systemName: "chevron.down.circle") }
                .menuIndicator(.hidden).fixedSize().disabled(choices.isEmpty)
                .accessibilityLabel("Choose " + label.lowercased()).help("Choose " + label.lowercased())
        }
    }
}

struct OptionalDate: View {
    let label: String
    @Binding var value: String
    @EditorState private var showingCalendar = false
    @EditorState private var selection = Date()
    static let format: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    var body: some View {
        HStack {
            Text(label)
            Spacer()
            let savedDate = Self.format.date(from: value)
            Button {
                selection = savedDate ?? Date()
                showingCalendar = true
            } label: {
                Label(savedDate?.formatted(date: .abbreviated, time: .omitted) ?? "Choose date", systemImage: "calendar")
            }
            .accessibilityLabel("Choose \(label.lowercased())")
            .accessibilityValue(value)
            .popover(isPresented: $showingCalendar) {
                VStack(alignment: .trailing, spacing: 8) {
                    DatePicker(label, selection: $selection, displayedComponents: .date)
                        .datePickerStyle(.graphical)
                        .labelsHidden()
                    Button("Use date") {
                        value = Self.format.string(from: selection)
                        showingCalendar = false
                    }.buttonStyle(PrimaryButton())
                }.padding(12).fixedSize()
            }
            if !value.isEmpty {
                Button { value = "" } label: { Image(systemName: "xmark.circle") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Clear \(label.lowercased())")
                    .help("Clear date")
            }
        }
    }
}
