import SwiftUI
import AppKit
import TaskCore

enum Queue: String, CaseIterable, Identifiable {
    case active = "Tasks", inbox = "Inbox", results = "Brain Updates", outcomes = "Outcomes", backlog = "Backlog", done = "Completed"
    var id: Self { self }
    var icon: String {
        switch self {
        case .active: return "checklist"
        case .inbox: return "tray.full"
        case .results: return "bell.badge"
        case .outcomes: return "target"
        case .backlog: return "tray.2"
        case .done: return "checkmark.circle"
        }
    }
    static func taskQueue(for status: Status) -> Self {
        switch status {
        case .backlog: return .backlog
        case .done: return .done
        case .todo, .active, .blocked: return .active
        }
    }
    func includes(_ status: Status) -> Bool {
        self == .outcomes || self == Self.taskQueue(for: status)
    }
}
extension WorkItem {
    var groupName: String { group.name }
    var priorityRank: Int { Priority.allCases.firstIndex(of: priority) ?? 0 }
    var statusRank: Int { Status.allCases.firstIndex(of: status) ?? 0 }
    var dueSort: String { dueDate.isEmpty ? "9999-99-99" : dueDate }
    var nextPeople: [String] {
        var seen = Set<String>()
        return openActions.map { $0.assignee.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }
    var nextPerson: String { nextPeople.joined(separator: ", ") }
}
enum DeskSort: String, CaseIterable {
    case priority = "Priority", due = "Due date", title = "Task", group = "Project / Customer"
    case status = "Status", person = "Next with", updated = "Last updated"
    var comparator: KeyPathComparator<WorkItem> {
        switch self {
        case .priority: return KeyPathComparator(\.priorityRank)
        case .due: return KeyPathComparator(\.dueSort)
        case .title: return KeyPathComparator(\.title)
        case .group: return KeyPathComparator(\.groupName)
        case .status: return KeyPathComparator(\.statusRank)
        case .person: return KeyPathComparator(\.nextPerson)
        case .updated: return KeyPathComparator(\.updatedAt, order: .reverse)
        }
    }
}
struct TaskFilters: Equatable, Codable {
    var statuses: Set<Status> = []
    var priorities: Set<Priority> = []
    var kinds: Set<GroupKind> = []
    var groups: Set<TaskGroup> = []
    var people: Set<String> = []
    var outcomeIDs: Set<Int?> = [] // A selected nil includes tasks without an outcome.

    init() {}

    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        statuses = try fields.decode(Set<Status>.self, forKey: .statuses)
        priorities = try fields.decode(Set<Priority>.self, forKey: .priorities)
        kinds = try fields.decode(Set<GroupKind>.self, forKey: .kinds)
        groups = try fields.decode(Set<TaskGroup>.self, forKey: .groups)
        people = try fields.decode(Set<String>.self, forKey: .people)
        outcomeIDs = try fields.decodeIfPresent(Set<Int?>.self, forKey: .outcomeIDs) ?? []
    }

    var count: Int { statuses.count + priorities.count + kinds.count + groups.count + people.count + outcomeIDs.count }

    func includes(_ item: WorkItem) -> Bool {
        (statuses.isEmpty || statuses.contains(item.status))
        && (priorities.isEmpty || priorities.contains(item.priority))
        && (kinds.isEmpty || kinds.contains(item.group.kind))
        && (outcomeIDs.isEmpty || outcomeIDs.contains(item.outcomeID))
        && (groups.isEmpty || groups.contains(item.group))
        && (people.isEmpty || item.nextPeople.contains { people.contains($0.lowercased()) })
    }
}

struct SavedFilter: Codable, Identifiable {
    var id = UUID()
    let name: String
    let filters: TaskFilters
    let search: String
}
enum OutcomeScope: Equatable {
    case overview, unassigned, outcome(Int)
    var id: Int? {
        if case .outcome(let id) = self { return id }
        return nil
    }
}

@MainActor final class Desk: ObservableObject {
    @Published var outcomes: [Outcome] = []
    @Published var outcomeScope: OutcomeScope = .overview
    @Published var editOutcome: Outcome?
    @Published var pendingOutcomeDelete: Outcome?
    @Published var setupTask: WorkItem?
    @Published var results: [BrainResult] = []
    @Published var proposals: [Proposal] = []
    @Published var tasks: [WorkItem] = []
    @Published var error: String?
    @Published var edit: WorkItem?
    @Published var pendingDelete: WorkItem?
    @Published var selection: Int?
    @Published var queue: Queue = .active
    @Published var search = ""
    @Published var filters = TaskFilters()
    @Published var sortOrder = [DeskSort.priority.comparator]
    @Published var detailID: Int?
    var sortField: DeskSort {
        DeskSort.allCases.first { $0.comparator.keyPath == sortOrder.first?.keyPath } ?? .priority
    }
    private var store: TaskStore?
    @Published private(set) var savedFilters: [SavedFilter] = []
    private let presetsKey = "savedTaskFilters.v1"

    init() {
        if let data = UserDefaults.standard.data(forKey: presetsKey) {
            do { savedFilters = try JSONDecoder().decode([SavedFilter].self, from: data) }
            catch { self.error = "Could not read saved filters: " + error.localizedDescription }
        }
        refresh()
    }

    func saveFilter(named name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw DeskError("Enter a name for this filter.") }
        guard !savedFilters.contains(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) else {
            throw DeskError("A filter with this name already exists. Choose another name.")
        }
        let preset = SavedFilter(name: trimmed, filters: filters, search: search)
        try writeFilters((savedFilters + [preset]).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
    }

    func removeFilter(_ preset: SavedFilter) throws {
        try writeFilters(savedFilters.filter { $0.id != preset.id })
    }

    private func writeFilters(_ presets: [SavedFilter]) throws {
        UserDefaults.standard.set(try JSONEncoder().encode(presets), forKey: presetsKey)
        savedFilters = presets
    }

    func refresh() {
        do {
            if store == nil { store = try TaskStore() }
            outcomes = try store?.outcomes() ?? []
            tasks = try store?.all() ?? []
            proposals = try store?.inbox() ?? []
            results = try store?.brainResults() ?? []
        } catch { self.error = error.localizedDescription }
    }
    func reviewStore() throws -> TaskStore {
        guard let store else { throw DeskError("Unable to open the task database.") }
        return store
    }
    func changeInbox(_ action: (TaskStore) throws -> Void) {
        do { try action(reviewStore()) } catch { self.error = error.localizedDescription }
        refresh()
    }
    var visible: [WorkItem] {
        tasks.filter { item in
            guard queue.includes(item.status), filters.includes(item) else { return false }
            if queue == .outcomes && (outcomeScope == .overview || item.outcomeID != outcomeScope.id) { return false }
            let words = [item.label, item.title, item.group.name, item.group.kind.rawValue, item.owner, item.context, item.latestUpdate] +
                item.collaborators + item.actions.flatMap { [$0.title,$0.assignee] }
            return search.isEmpty || words.contains { $0.localizedCaseInsensitiveContains(search) }
        }.sorted { left, right in
            // An unknown deadline stays below dated tasks in either direction.
            if sortField == .due, left.dueDate.isEmpty != right.dueDate.isEmpty { return !left.dueDate.isEmpty }
            for comparator in sortOrder {
                let order = comparator.compare(left, right)
                if order != .orderedSame { return order == .orderedAscending }
            }
            let l = left.dueDate.isEmpty ? "9999" : left.dueDate
            let r = right.dueDate.isEmpty ? "9999" : right.dueDate
            if l != r { return l < r }
            return (left.updatedAt,left.id) > (right.updatedAt,right.id)
        }
    }
    var knownPeople: [String] {
        outcomes.flatMap(\.responsiblePeople) + tasks.flatMap { [$0.owner] + $0.collaborators + $0.actions.map(\.assignee) }
    }
    func deleteOutcome(_ outcome: Outcome) {
        do {
            try reviewStore().deleteOutcome(outcome)
            showOutcome(.overview)
        } catch { self.error = error.localizedDescription }
        refresh()
    }

    var selectedOutcome: Outcome? { outcomes.first { $0.id == outcomeScope.id } }
    func showOutcome(_ scope: OutcomeScope) {
        queue = .outcomes
        outcomeScope = scope
        detailID = nil
        selection = nil
        filters = TaskFilters()
        search = ""
    }
    func newTask() {
        var task = WorkItem()
        if queue == .backlog { task.status = .backlog }
        if queue == .outcomes, let outcome = selectedOutcome {
            task.outcomeID = outcome.id
            task.group = outcome.group
        }
        edit = task
    }
    func history(_ id: Int) -> [Change] { (try? store?.history(id)) ?? [] }
    func save(_ draft: WorkItem) throws {
        guard let store else { throw DeskError("Unable to open the task database.") }
        let item = try store.save(draft, actor: "Luke")
        refresh()
        if queue == .outcomes { showOutcome(item.outcomeID.map(OutcomeScope.outcome) ?? .unassigned) }
        if !queue.includes(item.status) { queue = Queue.taskQueue(for: item.status) }
        if !filters.includes(item) { filters = TaskFilters() }
        if !visible.contains(where: { $0.id == item.id }) { search = "" }
        selection = item.id
        if detailID != nil { detailID = item.id }
    }
    func setStatus(_ status: Status, for item: WorkItem) {
        var draft = item
        draft.status = status
        do { try save(draft) } catch { self.error = error.localizedDescription; refresh() }
    }
    func delete(_ item: WorkItem) {
        do {
            guard let store else { throw DeskError("Unable to open the task database.") }
            try store.delete(item)
            if selection == item.id { selection = nil }
            if detailID == item.id { detailID = nil }
        } catch { self.error = error.localizedDescription }
        refresh()
    }
    private var helper: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/taskctl") }
    private var customDatabase: URL? { ProcessInfo.processInfo.environment["TASKDESK_DB"].map { URL(fileURLWithPath: $0) } }

    private func launch(_ url: URL) throws {
        guard NSWorkspace.shared.open(url) else { throw DeskError("Codex could not open this link on the Mac.") }
    }

    func open(_ task: WorkItem) {
        do {
            if let linked = try reviewStore().chat(task.id) { try launch(linked.url) }
            else { setupTask = task }
        } catch { self.error = error.localizedDescription }
    }

    func startSetup(_ task: WorkItem) throws {
        let store = try reviewStore()
        let token = try store.reserveChat(task.id)
        do {
            let settings = UserDefaults.standard
            try launch(Handoff.newThread(task: task, token: token, helper: helper, database: customDatabase,
                                         projectFolder: settings.string(forKey: CodexProjectSettings.folderKey) ?? "",
                                         projectID: settings.string(forKey: CodexProjectSettings.idKey) ?? ""))
        }
        catch { try store.cancelSetup(task.id, token: token); throw error }
    }

    func openResult(_ result: BrainResult) {
        do {
            try launch(result.chat.url)
            try reviewStore().markResultRead(result.id)
            refresh()
        } catch { self.error = error.localizedDescription }
    }

    func createTaskWithAI() {
        do { try launch(Handoff.createTaskLink(helper: helper, database: customDatabase, outcome: queue == .outcomes ? selectedOutcome : nil, status: queue == .backlog ? .backlog : nil)) }
        catch { self.error = error.localizedDescription }
    }
}
@main struct TaskDeskApp: App {
    @NSApplicationDelegateAdaptor(InboxNotifications.self) var notifications
    @StateObject var desk = Desk()
    @AppStorage("appearance") var appearance: Appearance = .system
    var body: some Scene {
        Window("Task Desk", id: "desk") {
            WorkspaceView().environmentObject(desk)
                .preferredColorScheme(appearance.scheme)
                .frame(minWidth: 920, minHeight: 540)
                .onReceive(DistributedNotificationCenter.default().publisher(for: Notification.Name("com.movedot.taskdesk.inboxChanged"))) { _ in desk.refresh() }
                .onOpenURL { url in
                    guard url.scheme == "taskdesk" else { return }
                    if url.host == "result", let id = Int(url.lastPathComponent) {
                        desk.refresh()
                        desk.detailID = nil
                        desk.queue = .results
                        if let result = desk.results.first(where: { $0.id == id }) { desk.openResult(result) }
                        return
                    }
                    guard url.host == "inbox" else { return }
                    desk.detailID = nil
                    desk.queue = .inbox
                    desk.refresh()
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in desk.refresh() }
        }
        .defaultSize(width: 1130, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Task") { desk.newTask() }.keyboardShortcut("n")
                Button("Refresh Tasks") { desk.refresh() }.keyboardShortcut("r")
            }
        }
        Settings {
            CodexProjectSettings()
        }
    }
}
