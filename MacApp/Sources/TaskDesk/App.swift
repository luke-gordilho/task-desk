import SwiftUI
import AppKit
import TaskCore

enum Queue: String, CaseIterable, Identifiable {
    case inbox = "Inbox", results = "Brain updates", active = "Active tasks", mine = "My turn", waiting = "Waiting on others", dot = "Dot’s queue", done = "Completed"
    var id: Self { self }
    var icon: String {
        switch self {
        case .inbox: return "tray.full"
        case .results: return "bell.badge"
        case .active: return "tray.2"
        case .mine: return "person.crop.circle"
        case .waiting: return "hourglass"
        case .dot: return "sparkles"
        case .done: return "checkmark.circle"
        }
    }
    func includes(_ item: WorkItem) -> Bool {
        if self == .done { return item.status == .done }
        guard item.status != .done else { return false }
        let actors = item.openActions.map { $0.assignee.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        let agents = ["dot", "codex", "claude", "claude code"]
        switch self {
        case .active: return true
        case .mine: return actors.contains("luke")
        case .waiting: return actors.contains { !$0.isEmpty && $0 != "luke" && !agents.contains($0) }
        case .dot: return actors.contains(where: agents.contains)
        case .done, .inbox, .results: return false
        }
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
struct TaskFilters: Equatable {
    var status: Status?
    var priority: Priority?
    var kind: GroupKind?
    var group: TaskGroup?
    var person: String?
    var count: Int { [status != nil, priority != nil, kind != nil, group != nil, person != nil].filter { $0 }.count }
    func includes(_ item: WorkItem) -> Bool {
        (status == nil || status == item.status) && (priority == nil || priority == item.priority)
        && (kind == nil || kind == item.group.kind) && (group == nil || group == item.group)
        && (person == nil || item.nextPeople.contains { $0.caseInsensitiveCompare(person!) == .orderedSame })
    }
}
@MainActor final class Desk: ObservableObject {
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
    init() { refresh() }
    func refresh() {
        do {
            if store == nil { store = try TaskStore() }
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
            guard queue.includes(item), filters.includes(item) else { return false }
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
    func history(_ id: Int) -> [Change] { (try? store?.history(id)) ?? [] }
    func save(_ draft: WorkItem) throws {
        guard let store else { throw DeskError("Unable to open the task database.") }
        let item = try store.save(draft, actor: "Luke")
        refresh()
        if !queue.includes(item) { queue = item.status == .done ? .done : .active }
        if !filters.includes(item) { filters = TaskFilters() }
        if !visible.contains(where: { $0.id == item.id }) { search = "" }
        selection = item.id
        if detailID != nil { detailID = item.id }
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
        do { try launch(Handoff.newThread(task: task, token: token, helper: helper, database: customDatabase)) }
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
        do { try launch(Handoff.createTaskLink(helper: helper, database: customDatabase)) }
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
                Button("New Task") { desk.edit = WorkItem() }.keyboardShortcut("n")
                Button("Refresh Tasks") { desk.refresh() }.keyboardShortcut("r")
            }
        }
    }
}
