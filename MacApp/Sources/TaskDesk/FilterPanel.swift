import SwiftUI
import TaskCore

private typealias FilterState<Value> = SwiftUI.State<Value>

struct FilterPanel: View {
    @EnvironmentObject var desk: Desk
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
                }.disabled(desk.filters.count == 0 && desk.search.isEmpty)
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Focus", selection: $desk.filters.focus) {
                        Text("Any").tag(nil as Bool?)
                        Text("In focus").tag(Optional(true))
                        Text("Off focus").tag(Optional(false))
                    }
                    outcomeChoices
                    choices("Status", Status.allCases.filter { desk.queue.includes($0) || desk.filters.statuses.contains($0) },
                            $desk.filters.statuses) { $0.rawValue }
                    choices("Priority", Priority.allCases, $desk.filters.priorities) { $0.rawValue }
                    choices("Work type", GroupKind.allCases, $desk.filters.kinds) { $0.rawValue }
                    choices("Project / Customer", groups, $desk.filters.groups) { $0.name + " · " + $0.kind.rawValue }
                    let names = uniqueNames(desk.tasks.map(\.nextStepOwner) + desk.filters.people.sorted())
                    let labels = Dictionary(uniqueKeysWithValues: names.map { ($0.lowercased(), $0) })
                    choices("Next step owner", labels.keys.sorted(), $desk.filters.people) { labels[$0] ?? $0 }
                }.padding(.trailing, 8).frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: 265)
        }.padding(16).frame(width: 350).background(Ink.surface)
        .onChange(of: desk.filters.kinds) { _, kinds in
            if !kinds.isEmpty { desk.filters.groups = desk.filters.groups.filter { kinds.contains($0.kind) } }
        }
    }

    private var outcomeChoices: some View {
        let outcomes = desk.outcomes.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        let labels = Dictionary(uniqueKeysWithValues: outcomes.map { ($0.id, $0.displayName) })
        let duplicates = Dictionary(grouping: outcomes, by: \.displayName).filter { $0.value.count > 1 }
        let missing = desk.filters.outcomeIDs.compactMap { $0 }.filter { labels[$0] == nil }.sorted()
        let options: [Int?] = [nil] + (outcomes.map(\.id) + missing).map(Optional.some)
        return choices("Outcome", options, $desk.filters.outcomeIDs) { id in
            guard let id else { return "Unassigned tasks" }
            guard let label = labels[id] else { return "Deleted outcome #\(id)" }
            return duplicates[label] == nil ? label : "\(label) (#\(id))"
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

struct SavedFilterControls: View {
    @EnvironmentObject var desk: Desk
    @FilterState private var saving = false
    @FilterState private var name = ""
    @FilterState private var error = ""

    var body: some View {
        if !desk.savedFilters.isEmpty {
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(desk.savedFilters) { preset in
                        let active = desk.filters == preset.filters && desk.search == preset.search
                        Button {
                            desk.filters = preset.filters
                            desk.search = preset.search
                        } label: {
                            HStack(spacing: 4) {
                                if active { Image(systemName: "checkmark") }
                                Text(preset.name).lineLimit(1)
                            }
                        }
                        .accessibilityLabel(preset.name)
                        .accessibilityAddTraits(active ? .isSelected : [])
                        .help("Apply “\(preset.name)”")
                        .contextMenu {
                            Button("Delete “\(preset.name)”", role: .destructive) {
                                do { try desk.removeFilter(preset) }
                                catch { desk.error = error.localizedDescription }
                            }
                        }
                    }
                }.padding(.vertical, 3)
            }.fixedSize(horizontal: false, vertical: true)
        }

        Button {
            name = ""
            error = ""
            saving = true
        } label: {
            Image(systemName: "bookmark.badge.plus")
        }
        .accessibilityLabel("Save current filter")
        .help("Save current filter")
        .disabled(desk.filters.count == 0 && desk.search.isEmpty)
        .popover(isPresented: $saving) {
            VStack(alignment: .leading, spacing: 10) {
                TextField("Filter name", text: $name).textFieldStyle(.roundedBorder)
                if !error.isEmpty { Text(error).font(.caption).foregroundStyle(Ink.danger) }
                HStack {
                    Spacer()
                    Button("Cancel") { saving = false }.keyboardShortcut(.cancelAction)
                    Button("Save filter") {
                        do {
                            try desk.saveFilter(named: name)
                            saving = false
                        } catch { self.error = error.localizedDescription }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.defaultAction)
                }
            }.padding(14).frame(width: 270)
        }
    }
}
