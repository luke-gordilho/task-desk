import Foundation

public enum Status: String, Codable, CaseIterable {
    case active = "In progress", todo = "To do", blocked = "Blocked", backlog = "Backlog", done = "Done"
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
    public var focus = false
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
    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        id = try fields.decode(Int.self, forKey: .id)
        version = try fields.decode(Int.self, forKey: .version)
        title = try fields.decode(String.self, forKey: .title)
        group = try fields.decode(TaskGroup.self, forKey: .group)
        outcomeID = try fields.decodeIfPresent(Int.self, forKey: .outcomeID)
        owner = try fields.decode(String.self, forKey: .owner)
        collaborators = try fields.decode([String].self, forKey: .collaborators)
        status = try fields.decode(Status.self, forKey: .status)
        priority = try fields.decode(Priority.self, forKey: .priority)
        focus = try fields.decodeIfPresent(Bool.self, forKey: .focus) ?? false
        dueDate = try fields.decode(String.self, forKey: .dueDate)
        followUpDate = try fields.decode(String.self, forKey: .followUpDate)
        createdAt = try fields.decode(String.self, forKey: .createdAt)
        updatedAt = try fields.decode(String.self, forKey: .updatedAt)
        actions = try fields.decode([ActionItem].self, forKey: .actions)
        context = try fields.decode(String.self, forKey: .context)
        doneWhen = try fields.decode(String.self, forKey: .doneWhen)
        latestUpdate = try fields.decode(String.self, forKey: .latestUpdate)
        references = try fields.decode(String.self, forKey: .references)
        agentInstructions = try fields.decode(String.self, forKey: .agentInstructions)
        workspace = try fields.decode(String.self, forKey: .workspace)
    }
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
