import AppKit
import Foundation
import CryptoKit
import TaskCore

let help = """
taskctl list                       List all tasks as JSON
taskctl get ID                     Read the full current task
taskctl create                     Queue an AI draft from stdin in the Inbox
taskctl update ID VERSION          Queue proposed task changes from stdin
taskctl agent-propose KEY ID VERSION  Queue a JSON patch (0 0 for a draft)
taskctl thread-get ID              Read the linked Codex address
taskctl thread-bind ID TOKEN       Bind the setup composer using CODEX_THREAD_ID
taskctl brain-handoff ID EVENT_UUID  Read an authorized instruction from stdin and prepare a dispatch to the linked chat
taskctl brain-dispatch ID EVENT_UUID  Queue the authorized instruction in the linked local chat\ntaskctl brain-result ID EVENT_UUID   From the linked chat, read {"work":"…","result":"…","next":"…"} from stdin
taskctl sync-init EPOCH             Set missing source checkpoints once
taskctl sync-status                  Show source windows and errors (Unix seconds)
taskctl sync-finish SOURCE FROM TO   Advance a successfully scanned window
taskctl sync-fail SOURCE FROM REASON Record a failure for retry
taskctl inbox-list                   List proposals and their review states
taskctl sync-propose SOURCE KEY ID VERSION   Read {"citation":"…","patch":{…}} from stdin; use 0 0 for a new task
Example patch: {"latestUpdate":"Draft ready","status":"In progress"}
Project or customer: {"group":{"kind":"Customer","name":"Example Co"}}
Set TASKDESK_DB to use a separate database.
"""
func output<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    print(String(decoding: try encoder.encode(value), as: UTF8.self))
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
func wakeDesk() throws {
    guard ProcessInfo.processInfo.environment["TASKDESK_DB"] == nil else { return }
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

func boundThreadID() throws -> String {
    guard let raw = ProcessInfo.processInfo.environment["CODEX_THREAD_ID"], let id = UUID(uuidString: raw) else {
        throw DeskError("Run this command in the linked Codex chat on the Task Desk Mac.")
    }
    return id.uuidString.lowercased()
}

do {
    let args = Array(CommandLine.arguments.dropFirst())
    if args.isEmpty || ["-h","--help","help"].contains(args[0]) { print(help); exit(0) }
    let store = try TaskStore()
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
        if receipt.inserted { try wakeDesk() }
    case ("list", 1): try output(store.all())
    case ("get", 2):
        guard let id = Int(args[1]) else { throw DeskError("Expected a numeric ID.") }
        try output(store.get(id))
    case ("thread-get", 2):
        guard let id = Int(args[1]), let chat = try store.chat(id) else { throw DeskError("Open the task in Task Desk and link its chat first.") }
        try output(chat)
    case ("thread-bind", 3):
        guard let id = Int(args[1]), let token = UUID(uuidString: args[2]) else { throw DeskError(help) }
        let address = try ChatAddress(boundThreadID())
        try store.bindChat(id, address: address, token: token)
        try output(address)
        try wakeDesk()
    case ("brain-handoff", 3), ("brain-dispatch", 3):
        guard let id = Int(args[1]), let event = UUID(uuidString: args[2]), let chat = try store.chat(id) else {
            throw DeskError("Supply a task with a linked chat and a stable UUID for this assignment.")
        }
        let instruction = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty else { throw DeskError("Supply Luke’s authorized task scope on stdin.") }
        let prompt = try Handoff.proactiveBrief(task: store.get(id), helper: URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL,
                                               database: ProcessInfo.processInfo.environment["TASKDESK_DB"].map { URL(fileURLWithPath: $0) }, instruction: instruction, key: event)
        var route = ["threadId":chat.threadID, "prompt":prompt]
        if let host = chat.hostID { route["hostId"] = host }
        if args[0] == "brain-handoff" {
            try output(route)
        } else {
            guard chat.hostID == nil else { throw DeskError("Use the host-specific brain-handoff with the Codex chat tool on the connected host.") }
            let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init) + ["/opt/homebrew/bin","/usr/local/bin"]
            guard let cli = paths.filter({ $0.hasPrefix("/") }).map({ URL(fileURLWithPath: $0).appendingPathComponent("codex") })
                .first(where: { FileManager.default.isExecutableFile(atPath: $0.path) })
            else { throw DeskError("The Codex CLI is unavailable on this Mac.") }
            if let previous = try store.beginDispatch(id, event: event, scope: instruction) {
                try output(["threadId":chat.threadID, "state":previous])
                break
            }
            let process = Process()
            process.executableURL = cli
            process.arguments = ["queue", "--thread", chat.threadID, "--message", prompt, "--resume"]
            process.standardOutput = FileHandle.standardError
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw DeskError("Codex could not confirm submission. Inspect the linked chat before retrying.")
            }
            try store.markQueued(id, event: event)
            try output(["threadId":chat.threadID, "state":"queued"])
        }
    case ("brain-result", 3):
        guard let id = Int(args[1]), let event = UUID(uuidString: args[2]) else { throw DeskError(help) }
        let data = FileHandle.standardInput.readDataToEndOfFile()
        if let entry = try JSONSerialization.jsonObject(with: data) as? [String: String], entry == ["outcome":"no_change"] {
            try output(["inserted":false])
            break
        }
        let raw = try JSONDecoder().decode(BrainNote.self, from: data)
        let inserted = try store.recordResult(taskID: id, threadID: boundThreadID(), key: event.uuidString,
                                              note: BrainNote(work: raw.work, result: raw.result, next: raw.next))
        try output(["inserted":inserted])
        if inserted { try wakeDesk() }
    case ("agent-propose", 4), ("create", 1), ("update", 3):
        let explicit = args[0] == "agent-propose"
        let tail = args[0] == "create" ? ["0","0"] : Array(args.suffix(2))
        guard let id = Int(tail[0]), let version = Int(tail[1]),
              let patch = try JSONSerialization.jsonObject(with: FileHandle.standardInput.readDataToEndOfFile()) as? [String: Any]
        else { throw DeskError(help) }
        let canonical = try JSONSerialization.data(withJSONObject: patch, options: [.sortedKeys])
        let digest = SHA256.hash(data: canonical).map { String(format: "%02x", $0) }.joined()
        let session = (try? boundThreadID()) ?? "agent"
        let key = "\(session)/\(id)/" + (explicit ? args[1] : "\(version)/\(digest)")
        let citation = (try? ChatAddress(session)).map { "Codex · " + $0.url.absoluteString } ?? "Agent proposal · " + key
        let receipt = try store.proposeAgent(key: key, citation: citation, id: id, version: version) { try applyPatch(patch, to: $0) }
        try output(receipt)
        if receipt.inserted { try wakeDesk() }
    default: throw DeskError(help)
    }
} catch {
    FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
    exit(1)
}
