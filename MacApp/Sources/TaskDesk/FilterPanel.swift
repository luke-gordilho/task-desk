import SwiftUI
import TaskCore

private typealias FilterState<Value> = SwiftUI.State<Value>

struct FilterPanel: View {
    @EnvironmentObject var desk: Desk
    @FilterState private var name = ""
    @FilterState private var message = ""
    @FilterState private var error = ""
    @FilterState private var expanded: Set<String> = ["Project / Customer"]

    private var groups: [TaskGroup] {
        Set(desk.tasks.map(\.group)).union(desk.filters.groups)
            .filter { !$0.name.isEmpty && (desk.filters.kinds.isEmpty || desk.filters.kinds.contains($0.kind)) }
            .sorted { ($0.name, $0.kind.rawValue) < ($1.name, $1.kind.rawValue) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Filters").font(.headline)
                Spacer()
                Button("Clear filters") {
                    desk.filters = TaskFilters()
                    desk.search = ""
                    message = ""
                }.disabled(desk.filters.count == 0 && desk.search.isEmpty)
            }
            if !desk.savedFilters.isEmpty {
                HStack {
                    Menu("Saved filters") {
                        ForEach(desk.savedFilters) { preset in
                            Button(preset.name) {
                                desk.filters = preset.filters
                                desk.search = preset.search
                                message = "Applied “\(preset.name)”."
                                error = ""
                            }
                        }
                    }
                    Menu {
                        ForEach(desk.savedFilters) { preset in
                            Button("Delete “\(preset.name)”", role: .destructive) {
                                do {
                                    try desk.removeFilter(preset)
                                    message = "Deleted “\(preset.name)”."
                                    error = ""
                                } catch { self.error = error.localizedDescription }
                            }
                        }
                    } label: { Image(systemName: "trash") }
                        .fixedSize().accessibilityLabel("Delete saved filter").help("Delete saved filter")
                }
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    choices("Status", Status.allCases.filter { desk.queue.includes($0) || desk.filters.statuses.contains($0) },
                            $desk.filters.statuses) { $0.rawValue }
                    choices("Priority", Priority.allCases, $desk.filters.priorities) { $0.rawValue }
                    choices("Work type", GroupKind.allCases, $desk.filters.kinds) { $0.rawValue }
                    choices("Project / Customer", groups, $desk.filters.groups) { $0.name + " · " + $0.kind.rawValue }
                    let names = uniqueNames(desk.tasks.flatMap(\.nextPeople) + desk.filters.people.sorted())
                    let labels = Dictionary(uniqueKeysWithValues: names.map { ($0.lowercased(), $0) })
                    choices("Next with", labels.keys.sorted(), $desk.filters.people) { labels[$0] ?? $0 }
                }.padding(.trailing, 8).frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: 265)
            Divider()
            HStack {
                TextField("Filter name", text: $name).textFieldStyle(.roundedBorder)
                Button("Save filter") {
                    do {
                        try desk.saveFilter(named: name)
                        message = "Saved “\(name.trimmingCharacters(in: .whitespacesAndNewlines))”."
                        error = ""
                        name = ""
                    } catch { self.error = error.localizedDescription }
                }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (desk.filters.count == 0 && desk.search.isEmpty))
            }
            if !error.isEmpty { Text(error).font(.caption).foregroundStyle(Ink.danger) }
            else if !message.isEmpty { Text(message).font(.caption).foregroundStyle(Ink.muted) }
        }.padding(16).frame(width: 350).background(Ink.surface)
        .onChange(of: desk.filters.kinds) { _, kinds in
            if !kinds.isEmpty { desk.filters.groups = desk.filters.groups.filter { kinds.contains($0.kind) } }
        }
    }

    private func choices<Value: Hashable>(_ title: String, _ options: [Value], _ selected: Binding<Set<Value>>,
                                          label: @escaping (Value) -> String) -> some View {
        DisclosureGroup(isExpanded: membership(title, in: $expanded)) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(options, id: \.self) { value in
                    Toggle(label(value), isOn: membership(value, in: selected)).toggleStyle(.checkbox)
                }
                if options.isEmpty { Text("No options").foregroundStyle(Ink.muted) }
            }.padding(.vertical, 4).frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            HStack {
                Text(title).fontWeight(.medium)
                Spacer()
                Text(selected.wrappedValue.isEmpty ? "Any" : "\(selected.wrappedValue.count) selected")
                    .font(.caption).foregroundStyle(Ink.muted)
            }
        }
    }

    private func membership<Value: Hashable>(_ value: Value, in values: Binding<Set<Value>>) -> Binding<Bool> {
        Binding(get: { values.wrappedValue.contains(value) }, set: { enabled in
            if enabled { values.wrappedValue.insert(value) } else { values.wrappedValue.remove(value) }
        })
    }
}
