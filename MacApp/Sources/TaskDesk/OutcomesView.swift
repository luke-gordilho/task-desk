import SwiftUI
import TaskCore

private typealias OutcomeState<T> = SwiftUI.State<T>

extension Outcome {
    fileprivate var groupName: String { group.name }
    fileprivate var priorityRank: Int { Priority.allCases.firstIndex(of: priority) ?? 0 }
}

struct OutcomesView: View {
    @EnvironmentObject var desk: Desk
    @OutcomeState private var sort = [KeyPathComparator(\Outcome.dueDate)]
    @OutcomeState private var selectedID: Int?
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Outcomes").font(.system(size: 26, weight: .semibold))
                Spacer()
                Button("Unassigned tasks (\(desk.tasks.filter { $0.outcomeID == nil }.count))") { desk.showOutcome(.unassigned) }
                Button { desk.editOutcome = Outcome() } label: { Label("New outcome", systemImage: "plus") }
                    .buttonStyle(PrimaryButton())
            }.padding(20)
            Divider()
            Table(desk.outcomes.sorted(using: sort), selection: $selectedID, sortOrder: $sort) {
                TableColumn("Outcome", value: \.name) { outcome in
                    Button(outcome.name) { desk.showOutcome(.outcome(outcome.id)) }.buttonStyle(.plain)
                }.width(min: 130, ideal: 235)
                TableColumn("Project / Customer", value: \.groupName)
                TableColumn("Due date", value: \.dueDate)
                TableColumn("Priority", value: \.priorityRank) { Text($0.priority.rawValue) }
                TableColumn("Tasks done") { outcome in
                    let members = desk.tasks.filter { $0.outcomeID == outcome.id }
                    Text("\(members.filter { $0.status == .done }.count) of \(members.count)").monospacedDigit()
                }
            }
            .contextMenu(forSelectionType: Int.self) { ids in
                if let value = desk.outcomes.first(where: { ids.contains($0.id) }) {
                    Button("Open outcome") { desk.showOutcome(.outcome(value.id)) }
                    Button("Edit outcome") { desk.editOutcome = value }
                }
            } primaryAction: { ids in if let id = ids.first { desk.showOutcome(.outcome(id)) } }
            .overlay {
                if desk.outcomes.isEmpty { ContentUnavailableView("No outcomes yet", systemImage: "target") }
            }
        }
    }
}

struct OutcomeEditor: View {
    @EnvironmentObject var desk: Desk
    @Environment(\.dismiss) private var dismiss
    @OutcomeState private var draft: Outcome
    @OutcomeState private var selected: Set<Int>
    @OutcomeState private var search = ""
    @OutcomeState private var error = ""
    private let initial: Set<Int>
    private let tasks: [WorkItem]

    init(outcome: Outcome, tasks: [WorkItem]) {
        self.tasks = tasks.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        initial = Set(tasks.filter { $0.outcomeID == outcome.id }.map(\.id))
        _selected = State(initialValue: initial)
        _draft = State(initialValue: outcome)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(draft.id == 0 ? "New outcome" : "Edit outcome").font(.title2.weight(.semibold))
            TextField("Outcome name", text: $draft.name).font(.title3).textFieldStyle(.roundedBorder)
            Grid(alignment: .leading, verticalSpacing: 9) {
                GridRow {
                    Picker("Type", selection: $draft.group.kind) {
                        ForEach(GroupKind.allCases, id: \.self) { Text($0.rawValue) }
                    }.labelsHidden().accessibilityLabel("Project or customer")
                    HStack {
                        TextField(draft.group.kind.rawValue + " name", text: $draft.group.name)
                        Menu {
                            let groups = tasks.map(\.group) + desk.outcomes.map(\.group)
                            ForEach(Set(groups.filter { $0.kind == draft.group.kind && !$0.name.isEmpty }.map(\.name)).sorted(), id: \.self) { name in
                                Button(name) { draft.group.name = name }
                            }
                        } label: { Image(systemName: "chevron.down.circle") }.fixedSize().help("Choose a saved project or customer")
                    }
                }
                GridRow {
                    Text("Priority")
                    Picker("Priority", selection: $draft.priority) {
                        ForEach(Priority.allCases, id: \.self) { Text($0.rawValue) }
                    }.labelsHidden().pickerStyle(.segmented)
                }
            }
            OptionalDate(label: "Due date", value: $draft.dueDate)
            Divider()
            Text("Tasks (\(selected.count))").font(.headline)
            TextField("Find a task", text: $search).textFieldStyle(.roundedBorder)
            List(tasks.filter { search.isEmpty || ($0.label + " " + $0.title).localizedCaseInsensitiveContains(search) }) { item in
                Toggle(isOn: Binding(get: { selected.contains(item.id) }, set: {
                    if $0 { selected.insert(item.id) } else { selected.remove(item.id) }
                })) {
                    VStack(alignment: .leading) {
                        Text(item.title)
                        if let parent = desk.outcomes.first(where: { $0.id == item.outcomeID && $0.id != draft.id }) {
                            Text("From " + parent.displayName).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }.toggleStyle(.checkbox)
            }
            HStack {
                Text(error).font(.caption).foregroundStyle(Ink.danger)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(draft.id == 0 ? "Create outcome" : "Save outcome") {
                    do {
                        let added = selected.subtracting(initial)
                        let removed = initial.subtracting(selected)
                        let saved = try desk.reviewStore().saveOutcome(draft,
                            adding: tasks.filter { added.contains($0.id) },
                            removing: tasks.filter { removed.contains($0.id) })
                        desk.refresh()
                        desk.showOutcome(.outcome(saved.id))
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                }.buttonStyle(PrimaryButton()).keyboardShortcut(.defaultAction)
                    .disabled([draft.name,draft.group.name,draft.dueDate].contains { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            }
        }.padding(20).frame(width: 540, height: 555).background(Ink.surface)
    }
}
