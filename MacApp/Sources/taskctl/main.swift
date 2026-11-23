import AppKit
import Foundation
import TaskCore

let help = """
taskctl list                       List all tasks as JSON
taskctl get ID                     Read the full current task
taskctl create                     Read a JSON object from stdin
taskctl update ID VERSION          Apply fields from stdin to that version
taskctl sync-init EPOCH             Set missing source checkpoints once
taskctl sync-status                  Show source windows and errors (Unix seconds)
taskctl sync-finish SOURCE FROM TO   Advance a successfully scanned window
taskctl sync-fail SOURCE FROM REASON Record a failure for retry
taskctl inbox-list                   List proposals and their review states
taskctl sync-propose SOURCE KEY ID VERSION   Read {"citation":"…","patch":{…}} from stdin; use 0 0 for a new task
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
    guard let patch = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw DeskError("Expected a JSON object.")
    }
    return try applyPatch(patch, to: task)
}
func applyPatch(_ input: [String: Any], to task: WorkItem) throws -> WorkItem {
    var patch = input
    guard var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(task)) as? [String: Any] else {
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
    case ("sync-init", 2):
        guard let epoch = Int(args[1]) else { throw DeskError("Expected Unix seconds.") }
        try store.initializeSync(from: epoch)
    case ("sync-status", 1):
        try output(SyncSource.allCases.map { try store.window($0) })
    case ("sync-finish", 4), ("sync-fail", 4):
        guard let source = SyncSource(rawValue: args[1]), let start = Int(args[2]) else { throw DeskError(help) }
        if args[0] == "sync-fail" { try store.fail(source, from: start, reason: args[3]) }
        else {
            guard let end = Int(args[3]) else { throw DeskError(help) }
            try store.finish(source, from: start, through: end)
        }
    case ("inbox-list", 1): try output(store.inbox())
    case ("sync-propose", 5), ("sync-apply", 5):
        guard let source = SyncSource(rawValue: args[1]), let id = Int(args[3]), let version = Int(args[4]),
              let request = try JSONSerialization.jsonObject(with: FileHandle.standardInput.readDataToEndOfFile()) as? [String: Any],
              let citation = request["citation"] as? String, let patch = request["patch"] as? [String: Any]
        else { throw DeskError(help) }
        let protected = ["workspace", "agentInstructions", "references"]
        guard Set(patch.keys).isDisjoint(with: protected) else { throw DeskError("The worker cannot change handoff instructions, workspace or existing source links.") }
        let receipt = try store.propose(source: source, key: args[2], citation: citation, id: id, version: version) {
            try applyPatch(patch, to: $0)
        }
        try output(receipt)
        if receipt.inserted && ProcessInfo.processInfo.environment["TASKDESK_DB"] == nil {
            let name = Notification.Name("com.movedot.taskdesk.inboxChanged")
            DistributedNotificationCenter.default().postNotificationName(name, object: nil, userInfo: nil, deliverImmediately: true)
            let app = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            if Bundle(url: app)?.bundleIdentifier == "com.movedot.taskdesk",
               NSRunningApplication.runningApplications(withBundleIdentifier: "com.movedot.taskdesk").isEmpty {
                let launcher = Process()
                launcher.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                launcher.arguments = ["-g", "-j", app.path]
                try launcher.run()
                launcher.waitUntilExit()
            }
        }
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
