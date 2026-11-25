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
                if desk.queue == .inbox {
                    InboxView()
                } else if desk.queue == .results {
                    BrainUpdatesView()
                } else if desk.queue == .outcomes && desk.outcomeScope == .overview {
                    OutcomesView()
                } else if let detail {
                    Button {
                        desk.detailID = nil
                    } label: { Label(desk.queue == .outcomes ? (desk.selectedOutcome?.name ?? "Unassigned tasks") : desk.queue.rawValue, systemImage: "chevron.left") }
                        .buttonStyle(.plain).padding(18)
                    Divider()
                    TaskDetail(item: detail).id(detail.id)
                } else {
                    if desk.queue == .outcomes {
                        HStack {
                            Button { desk.showOutcome(.overview) } label: { Label("Outcomes", systemImage: "chevron.left") }
                            Spacer()
                            if let outcome = desk.selectedOutcome {
                                Button("Edit outcome") { desk.editOutcome = outcome }
                                Button("Delete outcome…", role: .destructive) { desk.pendingOutcomeDelete = outcome }
                            }
                        }.buttonStyle(.plain).padding(.horizontal, 22).padding(.top, 16)
                    }
                    HStack {
                        Text(desk.queue == .outcomes ? (desk.selectedOutcome?.name ?? "Unassigned tasks") : desk.queue.rawValue).font(.system(size: 26, weight: .semibold))
                        Spacer()
                        Button(action: desk.createTaskWithAI) {
                            Label("Create task with AI", systemImage: "sparkles")
                        }.help("Describe a new task in Codex")
                        Button { desk.newTask() } label: { Label("New task", systemImage: "plus") }
                            .buttonStyle(PrimaryButton())
                    }.padding(.horizontal, 22).padding(.top, 20)
                    if desk.queue == .outcomes, let outcome = desk.selectedOutcome {
                        OutcomeFields(outcome: outcome).padding(.horizontal, 22).padding(.top, 6)
                    }
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
        .sheet(item: $desk.editOutcome) { outcome in
            OutcomeEditor(outcome: outcome, tasks: desk.tasks).environmentObject(desk).preferredColorScheme(appearance.scheme)
        }
        .sheet(item: $desk.setupTask) { item in ChatSetupView(provider: item.provider, task: item.task).environmentObject(desk) }
        .sheet(item: $desk.edit, onDismiss: { desk.refresh() }) { TaskEditor(draft: $0).environmentObject(desk).preferredColorScheme(appearance.scheme) }
        .alert("Delete outcome?", isPresented: Binding(get: { desk.pendingOutcomeDelete != nil }, set: { if !$0 { desk.pendingOutcomeDelete = nil } }), presenting: desk.pendingOutcomeDelete) { outcome in
            Button("Cancel", role: .cancel) {}
            Button("Delete outcome", role: .destructive) { desk.deleteOutcome(outcome) }
        } message: { outcome in
            Text("Delete “\(outcome.name)”? Its tasks will move to Unassigned tasks and keep their history.")
        }
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
    private func count(for queue: Queue) -> Int {
        switch queue {
        case .outcomes: return desk.outcomes.count
        case .inbox: return desk.proposals.filter { $0.state == .pending || $0.state == .approved }.count
        case .results: return desk.results.filter(\.unread).count
        default: return desk.tasks.filter { queue.includes($0.status) }.count
        }
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
                    if queue == .outcomes { desk.showOutcome(.overview) }
                    if desk.queue != queue {
                        desk.queue = queue
                        desk.filters.statuses.removeAll()
                        desk.selection = nil
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: queue.icon).frame(width: 16)
                        Text(queue.rawValue)
                        Spacer()
                        Text("\(count(for: queue))").font(.caption.monospacedDigit()).foregroundStyle(Ink.muted)
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
            }.padding(.horizontal, 9).frame(height: 29).frame(maxWidth: desk.visualizations.isEmpty ? 320 : 185)
            .background(Ink.surface, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(searching ? Ink.focusRing : Ink.inputBorder))
            if desk.visualizations.isEmpty { Spacer() }
            VisualizationControls()
            Button {
                showFilters.toggle()
            } label: {
                Label(desk.filters.count == 0 ? "Filter" : "Filter (\(desk.filters.count))", systemImage: "line.3.horizontal.decrease.circle")
            }.popover(isPresented: $showFilters) { FilterPanel().environmentObject(desk) }
            Menu {
                if desk.queue != .outcomes {
                    Toggle("Group by outcome", isOn: $desk.groupByOutcome)
                    Divider()
                }
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
        let tasks = desk.visible
        return Table(of: WorkItem.self, selection: $desk.selection, sortOrder: $desk.sortOrder) {
            TableColumn("Task", value: \.title) { item in
                HStack(spacing: 4) {
                    TaskCell(item: item, field: .title)
                    Button { desk.selection = item.id; desk.detailID = item.id } label: {
                        Image(systemName: "arrow.up.right.square").foregroundStyle(Ink.muted)
                    }.buttonStyle(.plain).accessibilityLabel("Open " + item.title).help("Open task details")
                }
            }.width(min: 135, ideal: 157)
            TableColumn("Focus", value: \.focusRank) { item in
                Toggle("Focus", isOn: Binding(get: { item.focus }, set: { desk.updateCell(item, \.focus, to: $0) }))
                    .toggleStyle(.checkbox).labelsHidden().accessibilityLabel("Focus on " + item.title)
            }.width(48)
            TableColumn("Project / Customer", value: \.groupName) { TaskCell(item: $0, field: .group) }
                .width(min: 100, ideal: 110)
            TableColumn("Status", value: \.statusRank) { item in
                Menu {
                    ForEach(Status.allCases, id: \.self) { status in
                        Button(status.rawValue) { desk.updateCell(item, \.status, to: status) }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Circle().fill(statusColor(item.status)).frame(width: 6, height: 6)
                        Text(item.status.rawValue).lineLimit(1)
                    }
                }.menuStyle(.borderlessButton).help("Change status")
            }.width(min: 88, ideal: 94)
            TableColumn("Priority", value: \.priorityRank) { item in
                Menu {
                    ForEach(Priority.allCases, id: \.self) { priority in
                        Button(priority.rawValue) { desk.updateCell(item, \.priority, to: priority) }
                    }
                } label: { Text(item.priority.rawValue) }
                    .menuStyle(.borderlessButton).help("Change priority")
            }.width(min: 67, ideal: 75)
            TableColumn("Next step owner", value: \.nextStepOwner) { TaskCell(item: $0, field: .actions) }
                .width(min: 108, ideal: 110)
            TableColumn("Due date", value: \.dueSort) { TaskCell(item: $0, field: .date) }
                .width(min: 85, ideal: 95)
            TableColumn("Open in") { item in
                TaskChatButtons(task: item)
            }.width(74)
        } rows: {
            if desk.groupByOutcome && desk.queue != .outcomes {
                ForEach(OutcomeTaskSection.group(tasks, by: desk.outcomes)) { section in
                    Section {
                        ForEach(section.tasks) { TableRow($0) }
                    } header: {
                        OutcomeSectionHeader(outcome: section.outcome)
                    }
                }
            } else {
                ForEach(tasks) { TableRow($0) }
            }
        }
        .contextMenu(forSelectionType: Int.self) { ids in
            if let id = ids.first, let item = desk.tasks.first(where: { $0.id == id }) {
                Button("Open task") { desk.detailID = id }
                Button("Edit task") { desk.edit = item }
                if item.status == .backlog {
                    Button("Move to To do") { desk.setStatus(.todo, for: item) }
                } else if item.status != .done {
                    Button("Move to Backlog") { desk.setStatus(.backlog, for: item) }
                }
                Button("Open in Claude Code") { desk.open(item, provider: .claude) }
                Button("Open in Codex") { desk.open(item) }
                Divider()
                Button("Delete task…", role: .destructive) { desk.pendingDelete = item }
            }
        } primaryAction: { ids in desk.detailID = ids.first }
        .alternatingRowBackgrounds(.disabled)
        .scrollContentBackground(.hidden).background(Ink.surface)
        .overlay {
            if tasks.isEmpty {
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
        switch status { case .done: return Ink.success; case .blocked: return Ink.warning; case .active: return Ink.info; case .todo, .backlog: return Ink.muted }
    }
}
private struct OutcomeTaskSection: Identifiable {
    let outcome: Outcome?
    var id: Int? { outcome?.id }
    let tasks: [WorkItem]

    static func group(_ tasks: [WorkItem], by outcomes: [Outcome]) -> [Self] {
        let knownIDs = Set(outcomes.map(\.id))
        let members = Dictionary(grouping: tasks) { task in
            task.outcomeID.flatMap { knownIDs.contains($0) ? $0 : nil }
        }
        var sections = outcomes.compactMap { outcome -> Self? in
            guard let tasks = members[outcome.id] else { return nil }
            return Self(outcome: outcome, tasks: tasks)
        }
        if let tasks = members[nil] {
            sections.append(Self(outcome: nil, tasks: tasks))
        }
        return sections
    }
}

private struct OutcomeSectionHeader: View {
    let outcome: Outcome?
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(outcome?.name ?? "Unassigned tasks", systemImage: outcome == nil ? "tray" : "target")
                .font(.system(size: 15, weight: .bold)).foregroundStyle(outcome == nil ? Ink.muted : Ink.primary)
            if let outcome { OutcomeFields(outcome: outcome) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Ink.mutedSurface)
        .overlay(alignment: .leading) { Rectangle().fill(outcome == nil ? Ink.border : Ink.primary).frame(width: 3) }
        .accessibilityElement(children: .combine)
    }
}

private struct OutcomeFields: View {
    let outcome: Outcome
    var body: some View {
        HStack(spacing: 14) {
            Text(outcome.group.kind.rawValue + " · " + outcome.group.name)
            Text("Responsible · " + (outcome.responsibleNames.isEmpty ? "Unassigned" : outcome.responsibleNames))
            Text("Due · " + outcome.dueDate).monospacedDigit().fixedSize()
            Text(outcome.priority.rawValue + " priority").fontWeight(.semibold).fixedSize()
        }.font(.callout).foregroundStyle(Ink.text).lineLimit(1)
            .help([outcome.group.name, outcome.responsibleNames, outcome.dueDate, outcome.priority.rawValue + " priority"].joined(separator: " · "))
    }
}
