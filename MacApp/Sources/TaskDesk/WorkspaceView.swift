import SwiftUI
import TaskCore

private typealias ViewState<Value> = SwiftUI.State<Value>

struct WorkspaceView: View {
    @EnvironmentObject var desk: Desk
    @AppStorage("appearance") var appearance: Appearance = .system
    @ViewState private var showFilters = false
    @FocusState private var searching: Bool
    private static let logo = Bundle.main.url(forResource: "Wordmark", withExtension: "png").flatMap(NSImage.init(contentsOf:))
    private var detail: WorkItem? { desk.tasks.first { $0.id == desk.detailID } }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(Ink.border).frame(width: 1)
            VStack(alignment: .leading, spacing: 0) {
                if let detail {
                    Button {
                        desk.detailID = nil
                    } label: { Label(desk.queue.rawValue, systemImage: "chevron.left") }
                        .buttonStyle(.plain).padding(18)
                    Divider()
                    TaskDetail(item: detail).id(detail.id)
                } else {
                    HStack {
                        Text(desk.queue.rawValue).font(.system(size: 26, weight: .semibold))
                        Spacer()
                        Button { desk.edit = WorkItem() } label: { Label("New task", systemImage: "plus") }
                            .buttonStyle(PrimaryButton())
                    }.padding(.horizontal, 22).padding(.top, 20)
                    controls.padding(.horizontal, 22).padding(.vertical, 14)
                    Divider()
                    taskTable
                    Divider()
                    Text("\(desk.visible.count) " + (desk.visible.count == 1 ? "task" : "tasks"))
                        .font(.caption.monospacedDigit()).foregroundStyle(Ink.muted)
                        .padding(.horizontal, 18).padding(.vertical, 8)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).background(Ink.background)
        }
        .foregroundStyle(Ink.text).tint(Ink.control)
        .sheet(item: $desk.edit, onDismiss: { desk.refresh() }) { TaskEditor(draft: $0).environmentObject(desk).preferredColorScheme(appearance.scheme) }
        .alert("Delete task?", isPresented: Binding(get: { desk.pendingDelete != nil }, set: { if !$0 { desk.pendingDelete = nil } }), presenting: desk.pendingDelete) { item in
            Button("Cancel", role: .cancel) {}
            Button("Delete task", role: .destructive) { desk.delete(item) }
        } message: { item in
            Text("Permanently delete “\(item.title)” (\(item.label)) and its activity history?")
        }
        .alert("Task Desk", isPresented: Binding(get: { desk.error != nil }, set: { if !$0 { desk.error = nil } })) {
            Button("OK") { desk.error = nil }
        } message: { Text(desk.error ?? "") }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let logo = Self.logo {
                Image(nsImage: logo).renderingMode(.template).resizable().scaledToFit().frame(width: 102, height: 30)
                    .foregroundStyle(Ink.primary).accessibilityLabel("MOVEdot").padding(.horizontal, 8)
            }
            Text("Task Desk").font(.subheadline.weight(.medium)).foregroundStyle(Ink.muted)
                .padding(.horizontal, 11).padding(.bottom, 22)
            ForEach(Queue.allCases) { queue in
                Button {
                    desk.detailID = nil
                    if desk.queue != queue {
                        desk.queue = queue
                        desk.filters.status = nil
                        desk.selection = nil
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: queue.icon).frame(width: 16)
                        Text(queue.rawValue)
                        Spacer()
                        Text("\(desk.tasks.filter(queue.includes).count)").font(.caption.monospacedDigit()).foregroundStyle(Ink.muted)
                    }.frame(height: 30).padding(.horizontal, 8)
                    .background(desk.queue == queue ? Ink.accent : .clear, in: RoundedRectangle(cornerRadius: 6))
                    .foregroundStyle(desk.queue == queue ? Ink.onAccent : Ink.text)
                    .contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            Spacer()
            Divider()
            Picker("Appearance", selection: $appearance) {
                ForEach(Appearance.allCases, id: \.self) { Text($0.rawValue) }
            }.font(.caption).padding(.horizontal, 4).padding(.top, 8)
        }.padding(.horizontal, 12).padding(.vertical, 21).frame(width: 213)
            .frame(maxHeight: .infinity).background(Ink.surface)
    }
    private var controls: some View {
        HStack(spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(Ink.muted)
                TextField("Search tasks", text: $desk.search).textFieldStyle(.plain).focused($searching)
                if !desk.search.isEmpty {
                    Button { desk.search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).accessibilityLabel("Clear search")
                }
            }.padding(.horizontal, 9).frame(height: 29).frame(maxWidth: 320)
            .background(Ink.surface, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(searching ? Ink.focusRing : Ink.inputBorder))
            Spacer()
            Button {
                showFilters.toggle()
            } label: {
                Label(desk.filters.count == 0 ? "Filter" : "Filter (\(desk.filters.count))", systemImage: "line.3.horizontal.decrease.circle")
            }.popover(isPresented: $showFilters) { FilterPanel().environmentObject(desk) }
            Menu {
                Picker("Sort by", selection: Binding(get: { desk.sortField }, set: { desk.sortOrder = [$0.comparator] })) {
                    ForEach(DeskSort.allCases, id: \.self) { Text($0.rawValue) }
                }.pickerStyle(.inline)
                Divider()
                Picker("Direction", selection: Binding(get: { desk.sortOrder.first?.order ?? .forward }, set: { order in
                    var value = desk.sortField.comparator
                    value.order = order
                    desk.sortOrder = [value]
                })) { Text("Ascending").tag(SortOrder.forward); Text("Descending").tag(SortOrder.reverse) }.pickerStyle(.inline)
            } label: { Label("Sort", systemImage: "arrow.up.arrow.down") }.fixedSize()
        }
    }
    private var taskTable: some View {
        Table(desk.visible, selection: $desk.selection, sortOrder: $desk.sortOrder) {
            TableColumn("Task", value: \.title) { item in
                Button { desk.selection = item.id; desk.detailID = item.id } label: {
                    Text(item.title).fontWeight(.medium).lineLimit(1)
                }.buttonStyle(.plain).help("Open " + item.title)
            }.width(min: 145, ideal: 215)
            TableColumn("Project / Customer", value: \.groupName) { item in
                Text(item.group.name.isEmpty ? "—" : item.group.name).lineLimit(1)
                    .help(item.group.kind.rawValue + " · " + item.group.name)
            }.width(min: 105, ideal: 135)
            TableColumn("Status", value: \.statusRank) { item in
                HStack(spacing: 5) { Circle().fill(statusColor(item.status)).frame(width: 6, height: 6); Text(item.status.rawValue) }
            }.width(min: 85, ideal: 95)
            TableColumn("Priority", value: \.priorityRank) { item in
                Text(item.priority.rawValue)
            }.width(min: 58, ideal: 66)
            TableColumn("Next with", value: \.nextPerson) { item in
                Text(item.nextPerson.isEmpty ? "—" : item.nextPerson).lineLimit(1).help(item.nextPerson)
            }.width(min: 80, ideal: 110)
            TableColumn("Due date", value: \.dueSort) { item in
                Text(item.dueDate.isEmpty ? "—" : item.dueDate).monospacedDigit()
            }.width(min: 85, ideal: 95)
        }
        .contextMenu(forSelectionType: Int.self) { ids in
            if let id = ids.first, let item = desk.tasks.first(where: { $0.id == id }) {
                Button("Open task") { desk.detailID = id }
                Button("Edit task") { desk.edit = item }
                ForEach(TaskAgent.allCases, id: \.self) { agent in
                    Button("Open in " + agent.rawValue) { desk.open(item, in: agent) }
                }
                Divider()
                Button("Delete task…", role: .destructive) { desk.pendingDelete = item }
            }
        } primaryAction: { ids in desk.detailID = ids.first }
        .alternatingRowBackgrounds(.disabled)
        .scrollContentBackground(.hidden).background(Ink.surface)
        .overlay {
            if desk.visible.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: desk.tasks.isEmpty ? "tray" : "magnifyingglass").font(.largeTitle).foregroundStyle(Ink.muted)
                    Text(desk.tasks.isEmpty ? "Create your first task" : "No tasks in this view").font(.headline)
                    if desk.filters.count > 0 || !desk.search.isEmpty {
                        Button("Clear filters and search") { desk.filters = TaskFilters(); desk.search = "" }
                    }
                }
            }
        }
    }
    private func statusColor(_ status: Status) -> Color {
        switch status { case .done: return Ink.success; case .blocked: return Ink.warning; case .active: return Ink.info; case .todo: return Ink.muted }
    }
}
private struct FilterPanel: View {
    @EnvironmentObject var desk: Desk
    private var groups: [TaskGroup] {
        Set(desk.tasks.map(\.group)).filter { !$0.name.isEmpty && (desk.filters.kind == nil || $0.kind == desk.filters.kind) }
            .sorted { ($0.name,$0.kind.rawValue) < ($1.name,$1.kind.rawValue) }
    }
    var body: some View {
        Form {
            Picker("Status", selection: $desk.filters.status) {
                Text("Any").tag(nil as Status?)
                ForEach(Status.allCases.filter { desk.queue == .done ? $0 == .done : $0 != .done }, id: \.self) { Text($0.rawValue).tag(Optional($0)) }
            }
            Picker("Priority", selection: $desk.filters.priority) {
                Text("Any").tag(nil as Priority?)
                ForEach(Priority.allCases, id: \.self) { Text($0.rawValue).tag(Optional($0)) }
            }
            Picker("Work type", selection: $desk.filters.kind) {
                Text("Any").tag(nil as GroupKind?)
                ForEach(GroupKind.allCases, id: \.self) { Text($0.rawValue).tag(Optional($0)) }
            }.onChange(of: desk.filters.kind) { _, kind in
                if let kind, let group = desk.filters.group, group.kind != kind { desk.filters.group = nil }
            }
            Picker("Project / Customer", selection: $desk.filters.group) {
                Text("Any").tag(nil as TaskGroup?)
                ForEach(groups, id: \.self) { Text($0.name + " · " + $0.kind.rawValue).tag(Optional($0)) }
            }
            Picker("Next with", selection: $desk.filters.person) {
                Text("Anyone").tag(nil as String?)
                ForEach(Set(desk.tasks.flatMap(\.nextPeople)).sorted(), id: \.self) { Text($0).tag(Optional($0)) }
            }
            Button("Clear filters") { desk.filters = TaskFilters() }.disabled(desk.filters.count == 0)
        }.padding(16).frame(width: 300).background(Ink.surface)
    }
}
