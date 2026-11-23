import Foundation

public enum Status: String, Codable, CaseIterable {
    case todo = "To do", active = "In progress", blocked = "Blocked", done = "Done"
}
public enum Priority: String, Codable, CaseIterable {
    case high = "High", medium = "Medium", low = "Low"
}
public struct ActionItem: Codable, Identifiable, Equatable {
    public var id = UUID()
    public var title = ""
    public var assignee = ""
    public var completed = false
    public init(title: String = "", assignee: String = "") {
        self.title = title
        self.assignee = assignee
    }
}
public enum GroupKind: String, Codable, CaseIterable {
    case project = "Project", customer = "Customer"
}
public struct TaskGroup: Codable, Equatable, Hashable {
    public var kind: GroupKind
    public var name: String
    public init(kind: GroupKind = .project, name: String = "") {
        self.kind = kind
        self.name = name
    }
}
// Keep the first spelling and order when a name is entered more than once.
public func uniqueNames(_ values: [String]) -> [String] {
    var seen = Set<String>()
    return values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
}

public struct Outcome: Codable, Identifiable, Equatable {
    public var id = 0
    public var version = 0
    public var name = ""
    public var group = TaskGroup()
    public var responsiblePeople: [String] = []
    public var dueDate = ""
    public var priority = Priority.medium
    public init() {}
    public var displayName: String { name + " · " + group.name }
}

public struct WorkItem: Codable, Identifiable, Equatable {
    public var id = 0
    public var version = 0
    public var title = ""
    public var group = TaskGroup()
    public var outcomeID: Int?
    public var owner = "Luke"
    public var collaborators: [String] = []
    public var status = Status.todo
    public var priority = Priority.medium
    public var dueDate = ""
    public var followUpDate = ""
    public var createdAt = ""
    public var updatedAt = ""
    public var actions: [ActionItem] = []
    public var context = ""
    public var doneWhen = ""
    public var latestUpdate = ""
    public var references = ""
    public var agentInstructions = ""
    public var workspace = ""
    public init() {}
    public var label: String { "T-" + String(format: "%03d", id) }
    public var openActions: [ActionItem] { actions.filter { !$0.completed } }
}
public struct Change: Identifiable {
    public let id: Int
    public let date: String
    public let actor: String
    public let summary: String
}
public struct DeskError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
public enum DeskPaths {
    public static var database: URL {
        if let custom = ProcessInfo.processInfo.environment["TASKDESK_DB"] {
            return URL(fileURLWithPath: custom)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Task Desk/tasks.sqlite3")
    }
}
