import Foundation
import TaskCore

let help = """
taskctl list                       List all tasks as JSON
taskctl get ID                     Read the full current task
taskctl create                     Read a JSON object from stdin
taskctl update ID VERSION          Apply fields from stdin to that version
Example patch: {"latestUpdate":"Draft ready","status":"In progress"}
Project or customer: {"group":{"kind":"Customer","name":"Example Co"}}
Set TASKDESK_DB to use a separate database. TASKDESK_ACTOR defaults to Codex.
"""
func output<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    print(String(decoding: try encoder.encode(value), as: UTF8.self))
}
func applyInput(to task: WorkItem) throws -> WorkItem {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    guard var patch = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(task)) as? [String: Any] else {
        throw DeskError("Expected a JSON object.")
    }
    // Accept older clients that send one of the original name fields.
    if patch["customer"] != nil || patch["project"] != nil {
        guard patch["group"] == nil else { throw DeskError("Use a single project or customer.") }
        let customer = patch.removeValue(forKey: "customer")
        let project = patch.removeValue(forKey: "project")
        for field in [customer, project].compactMap({ $0 }) where !(field is String) {
            throw DeskError("Project and customer must be text.")
        }
        let c = customer as? String ?? "", p = project as? String ?? ""
        guard c.isEmpty || p.isEmpty else { throw DeskError("Choose one project or customer.") }
        if !c.isEmpty || !p.isEmpty {
            patch["group"] = ["kind": c.isEmpty ? "Project" : "Customer", "name": c.isEmpty ? p : c]
        } else if (customer != nil && task.group.kind == .customer) || (project != nil && task.group.kind == .project) {
            patch["group"] = ["kind": task.group.kind.rawValue, "name": ""]
        }
    }
    let readOnly = Set(["id", "version", "createdAt", "updatedAt"])
    for key in patch.keys where object[key] == nil || readOnly.contains(key) {
        throw DeskError("Unknown or read-only field: " + key)
    }
    if let actions = patch["actions"] as? [[String: Any]] {
        patch["actions"] = actions.map { action in
            var value = action
            if value["id"] == nil { value["id"] = UUID().uuidString }
            if value["completed"] == nil { value["completed"] = false }
            if value["assignee"] == nil { value["assignee"] = "" }
            return value
        }
    }
    object.merge(patch) { _, new in new }
    return try JSONDecoder().decode(WorkItem.self, from: JSONSerialization.data(withJSONObject: object))
}
do {
    let args = Array(CommandLine.arguments.dropFirst())
    if args.isEmpty || ["-h","--help","help"].contains(args[0]) { print(help); exit(0) }
    let store = try TaskStore()
    let actor = ProcessInfo.processInfo.environment["TASKDESK_ACTOR"] ?? "Codex"
    switch (args[0], args.count) {
    case ("list", 1): try output(store.all())
    case ("get", 2):
        guard let id = Int(args[1]) else { throw DeskError("Expected a numeric ID.") }
        try output(store.get(id))
    case ("create", 1): try output(store.save(applyInput(to: WorkItem()), actor: actor))
    case ("update", 3):
        guard let id = Int(args[1]), let version = Int(args[2]) else { throw DeskError("Expected numeric ID and version.") }
        var item = try store.get(id)
        guard item.version == version else { throw DeskError("Version conflict. Read the task again.") }
        item = try applyInput(to: item)
        try output(store.save(item, actor: actor))
    default: throw DeskError(help)
    }
} catch {
    FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
    exit(1)
}
