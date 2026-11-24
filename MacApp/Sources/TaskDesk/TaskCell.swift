import SwiftUI
import TaskCore

private typealias CellState<Value> = SwiftUI.State<Value>

enum TaskCellField: String {
    case title = "Task title", group = "Project / Customer", actions = "Next actions", date = "Due date"
}

struct TaskCell: View {
    let item: WorkItem
    let field: TaskCellField
    @CellState private var editing: WorkItem?

    private var value: String {
        switch field {
        case .title: return item.title
        case .group: return item.group.name
        case .actions: return item.nextStep != nil && item.nextStepOwner.isEmpty ? "Unassigned" : item.nextStepOwner
        case .date: return item.dueDate
        }
    }

    var body: some View {
        Button { editing = item } label: {
            Text(value.isEmpty ? "—" : value)
                .lineLimit(1).fontWeight(field == .title ? .medium : .regular)
                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain).help("Edit " + field.rawValue.lowercased())
        .accessibilityLabel(field.rawValue + ", " + (value.isEmpty ? "Unassigned" : value))
        .popover(item: $editing) { original in
            TaskCellEditor(item: original, field: field)
        }
    }
}

private struct TaskCellEditor: View {
    @EnvironmentObject var desk: Desk
    @Environment(\.dismiss) private var dismiss
    @CellState private var draft: WorkItem
    @CellState private var date: Date
    @CellState private var error = ""
    let field: TaskCellField

    init(item: WorkItem, field: TaskCellField) {
        self.field = field
        _draft = State(initialValue: item)
        _date = State(initialValue: OptionalDate.format.date(from: item.dueDate) ?? Date())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(field.rawValue).font(.headline)
            switch field {
            case .title:
                TextField("Task title", text: $draft.title).textFieldStyle(.roundedBorder)
            case .group:
                GroupFields(draft: $draft)
            case .actions:
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ActionFields(draft: $draft, suggestions: desk.knownPeople)
                    }
                }.frame(height: min(310, CGFloat(draft.actions.count) * 75 + 40))
            case .date:
                DatePicker("Due date", selection: $date, displayedComponents: .date)
                    .datePickerStyle(.graphical).labelsHidden()
            }
            if !error.isEmpty { Text(error).foregroundStyle(Ink.danger).font(.caption) }
            HStack {
                if field == .date && !draft.dueDate.isEmpty {
                    Button("Clear date") { draft.dueDate = ""; save() }
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    if field == .date { draft.dueDate = OptionalDate.format.string(from: date) }
                    save()
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(14).frame(width: field == .actions ? 360 : 300)
    }

    private func save() {
        do { try desk.saveTableEdit(draft); dismiss() }
        catch { self.error = error.localizedDescription }
    }
}
