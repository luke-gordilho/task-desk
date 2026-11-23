import Foundation
import SQLite3

private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public final class TaskStore {
    private var db: OpaquePointer?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(url: URL = DeskPaths.database) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw failure()
        }
        sqlite3_busy_timeout(db, 5000)
        try exec("""
        PRAGMA journal_mode=WAL;
        PRAGMA foreign_keys=ON;
        CREATE TABLE IF NOT EXISTS tasks(id INTEGER PRIMARY KEY, version INTEGER NOT NULL, body TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS changes(id INTEGER PRIMARY KEY, task_id INTEGER NOT NULL REFERENCES tasks(id),
            stamp TEXT NOT NULL, actor TEXT NOT NULL, summary TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS sync_origin(id INTEGER PRIMARY KEY CHECK(id=1), started INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS sync_sources(source TEXT PRIMARY KEY, through INTEGER NOT NULL, last_error TEXT NOT NULL DEFAULT '');
        CREATE TABLE IF NOT EXISTS sync_receipts(source TEXT NOT NULL, evidence TEXT NOT NULL, task_id INTEGER NOT NULL,
            PRIMARY KEY(source, evidence));
        CREATE TABLE IF NOT EXISTS retired_task_ids(id INTEGER PRIMARY KEY);
        CREATE TABLE IF NOT EXISTS inbox(id INTEGER PRIMARY KEY, source TEXT NOT NULL, evidence TEXT NOT NULL,
            body TEXT NOT NULL, notified INTEGER NOT NULL DEFAULT 0, UNIQUE(source,evidence));
        CREATE INDEX IF NOT EXISTS changes_task ON changes(task_id,id);
        """)
    }
    deinit { sqlite3_close(db) }
    private func failure() -> DeskError { DeskError(String(cString: sqlite3_errmsg(db))) }
    private func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }
    private func statement<T>(_ sql: String, _ values: [String] = [], _ body: (OpaquePointer) throws -> T) throws -> T {
        var q: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &q, nil) == SQLITE_OK, let q else { throw failure() }
        defer { sqlite3_finalize(q) }
        for (i, value) in values.enumerated() {
            guard sqlite3_bind_text(q, Int32(i+1), value, -1, transient) == SQLITE_OK else { throw failure() }
        }
        return try body(q)
    }
    private func write(_ sql: String, _ values: [String]) throws {
        try statement(sql, values) { if sqlite3_step($0) != SQLITE_DONE { throw failure() } }
    }
    private func rows<T>(_ sql: String, _ values: [String] = [], _ map: (OpaquePointer) throws -> T) throws -> [T] {
        try statement(sql, values) { q in
            var result = [T]()
            while true {
                switch sqlite3_step(q) {
                case SQLITE_ROW: result.append(try map(q))
                case SQLITE_DONE: return result
                default: throw failure()
                }
            }
        }
    }
    private func field(_ q: OpaquePointer, _ index: Int32) -> String {
        String(cString: sqlite3_column_text(q, index))
    }
    private func decode(_ q: OpaquePointer) throws -> WorkItem {
        var data = Data(field(q, 2).utf8)
        // Earlier versions stored the two names independently. Adapt on read.
        if var body = try JSONSerialization.jsonObject(with: data) as? [String: Any], body["group"] == nil {
            let customer = body["customer"] as? String ?? ""
            let project = body["project"] as? String ?? ""
            body["group"] = ["kind": customer.isEmpty ? "Project" : "Customer", "name": customer.isEmpty ? project : customer]
            if !customer.isEmpty && !project.isEmpty {
                let context = body["context"] as? String ?? ""
                body["context"] = [context, "Project: " + project].filter { !$0.isEmpty }.joined(separator: "\n\n")
            }
            data = try JSONSerialization.data(withJSONObject: body)
        }
        var item = try decoder.decode(WorkItem.self, from: data)
        item.id = Int(sqlite3_column_int64(q, 0))
        item.version = Int(sqlite3_column_int64(q, 1))
        return item
    }
    public func all() throws -> [WorkItem] {
        try rows("SELECT id,version,body FROM tasks ORDER BY id DESC", [], decode)
    }
    public func get(_ id: Int) throws -> WorkItem {
        guard let item = try rows("SELECT id,version,body FROM tasks WHERE id=?", [String(id)], decode).first else {
            throw DeskError("Task \(id) does not exist.")
        }
        return item
    }
    public func history(_ id: Int) throws -> [Change] {
        try rows("SELECT id,stamp,actor,summary FROM changes WHERE task_id=? ORDER BY id DESC", [String(id)]) {
            Change(id: Int(sqlite3_column_int64($0, 0)), date: field($0, 1), actor: field($0, 2), summary: field($0, 3))
        }
    }
    public func delete(_ item: WorkItem) throws {
        try exec("BEGIN IMMEDIATE")
        do {
            let current = try get(item.id)
            guard current.version == item.version else {
                throw DeskError("This task changed. Review the latest version before deleting it.")
            }
            let key = [String(item.id)]
            try write("INSERT INTO retired_task_ids(id) VALUES(?)", key)
            try write("DELETE FROM changes WHERE task_id=?", key)
            try write("DELETE FROM tasks WHERE id=?", key)
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }
    private func transaction<T>(_ body: () throws -> T) throws -> T {
        try exec("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try exec("COMMIT")
            return result
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }
    public func save(_ draft: WorkItem, actor: String) throws -> WorkItem {
        try transaction { try persist(draft, actor: actor) }
    }
    private func persist(_ draft: WorkItem, actor: String) throws -> WorkItem {
        var item = draft
        try validate(&item)
        let stamp = ISO8601DateFormatter().string(from: Date())
        let summary: String
        if item.id == 0 {
            item.createdAt = stamp
            // Retire deleted IDs so an old agent handoff can never target a new task.
            try exec("""
            INSERT INTO tasks(id,version,body)
            SELECT MAX(COALESCE((SELECT MAX(id) FROM tasks),0),
                       COALESCE((SELECT MAX(id) FROM retired_task_ids),0)) + 1, 0, '{}'
            """)
            item.id = Int(sqlite3_last_insert_rowid(db))
            item.version = 1
            summary = "Created the task"
        } else {
            let current = try get(item.id)
            guard current.version == item.version else {
                throw DeskError("This task changed since you opened it. Copy your edits, close the editor, and reopen the latest version.")
            }
            item.createdAt = current.createdAt
            item.updatedAt = current.updatedAt
            if current == item { return current }
            item.version += 1
            summary = Self.changeSummary(from: current, to: item)
        }
        item.updatedAt = stamp
        let body = String(decoding: try encoder.encode(item), as: UTF8.self)
        try write("UPDATE tasks SET version=?,body=? WHERE id=?", [String(item.version), body, String(item.id)])
        try write("INSERT INTO changes(task_id,stamp,actor,summary) VALUES(?,?,?,?)", [String(item.id), stamp, actor, summary])
        return item
    }
    private func validate(_ item: inout WorkItem) throws {
        item.title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        item.group.name = item.group.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !item.title.isEmpty else { throw DeskError("Enter a title for the task.") }
        for action in item.actions where action.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw DeskError("Enter a description for each next action.")
        }
        guard Set(item.actions.map(\.id)).count == item.actions.count else { throw DeskError("Duplicate action ID.") }
        let dateFormat = DateFormatter()
        dateFormat.locale = Locale(identifier: "en_US_POSIX")
        dateFormat.dateFormat = "yyyy-MM-dd"
        for date in [item.dueDate, item.followUpDate] where !date.isEmpty {
            guard let value = dateFormat.date(from: date), dateFormat.string(from: value) == date else {
                throw DeskError("Use YYYY-MM-DD for dates.")
            }
        }
    }
    private static func changeSummary(from old: WorkItem, to new: WorkItem) -> String {
        let fields: [(String, Bool)] = [
            ("title", old.title != new.title), ("project or customer", old.group != new.group), ("owner", old.owner != new.owner),
            ("collaborators", old.collaborators != new.collaborators), ("status to " + new.status.rawValue, old.status != new.status),
            ("priority", old.priority != new.priority), ("due date", old.dueDate != new.dueDate),
            ("follow-up", old.followUpDate != new.followUpDate), ("next actions", old.actions != new.actions),
            ("context", old.context != new.context), ("completion criteria", old.doneWhen != new.doneWhen),
            ("latest update", old.latestUpdate != new.latestUpdate), ("sources", old.references != new.references),
            ("agent instructions", old.agentInstructions != new.agentInstructions), ("workspace", old.workspace != new.workspace)
        ]
        return "Updated " + fields.filter(\.1).map(\.0).joined(separator: ", ")
    }
}

public enum SyncSource: String, CaseIterable {
    case circleback, slack, teams, outlook, plaud
}
public struct SyncWindow: Encodable {
    public let source: String
    public let collectionStart: Int
    public let from: Int
    public let through: Int
    public let lastError: String
}
extension TaskStore {
    public func initializeSync(from: Int) throws {
        guard from > 0 && from <= Int(Date().timeIntervalSince1970) else { throw DeskError("Invalid starting timestamp.") }
        try transaction {
            try write("INSERT OR IGNORE INTO sync_origin(id,started) VALUES(1,?)", [String(from)])
            for source in SyncSource.allCases {
                try write("INSERT OR IGNORE INTO sync_sources(source,through) SELECT ?,started FROM sync_origin WHERE id=1", [source.rawValue])
            }
        }
    }
    public func window(_ source: SyncSource) throws -> SyncWindow {
        let result = try rows("SELECT through,last_error,started FROM sync_sources CROSS JOIN sync_origin WHERE source=? AND sync_origin.id=1", [source.rawValue]) { q in
            let from = Int(sqlite3_column_int64(q, 0))
            return SyncWindow(source: source.rawValue, collectionStart: Int(sqlite3_column_int64(q, 2)), from: from, through: min(from + 7200, Int(Date().timeIntervalSince1970)), lastError: field(q, 1))
        }
        guard let window = result.first else { throw DeskError("Initialize source checkpoints with sync-init first.") }
        return window
    }
    public func finish(_ source: SyncSource, from: Int, through: Int) throws {
        let range = try window(source)
        guard through > from && through <= range.through else { throw DeskError("Invalid sync window.") }
        try write("UPDATE sync_sources SET through=?,last_error='' WHERE source=? AND through=?", [String(through), source.rawValue, String(from)])
        guard sqlite3_changes(db) == 1 else { throw DeskError("Checkpoint changed. Reload the source window.") }
    }
    public func fail(_ source: SyncSource, from: Int, reason: String) throws {
        try write("UPDATE sync_sources SET last_error=? WHERE source=? AND through=?", [reason,source.rawValue,String(from)])
        guard sqlite3_changes(db) == 1 else { throw DeskError("Checkpoint changed. Reload the source window.") }
    }

}

extension TaskStore {
    private func proposalRow(_ q: OpaquePointer) throws -> Proposal {
        var item = try decoder.decode(Proposal.self, from: Data(field(q, 1).utf8))
        item.id = Int(sqlite3_column_int64(q, 0))
        return item
    }

    public func inbox() throws -> [Proposal] {
        try rows("SELECT id,body FROM inbox ORDER BY id DESC", [], proposalRow)
    }

    private func currentProposal(_ expected: Proposal) throws -> Proposal {
        guard let item = try rows("SELECT id,body FROM inbox WHERE id=?", [String(expected.id)], proposalRow).first,
              item.revision == expected.revision else { throw DeskError("This proposal changed. Reopen it to review the latest version.") }
        return item
    }

    private func writeProposal(_ proposal: Proposal) throws {
        var item = proposal
        item.revision += 1
        try write("UPDATE inbox SET body=? WHERE id=?", [String(decoding: try encoder.encode(item), as: UTF8.self), String(item.id)])
    }

    public func propose(source: SyncSource, key: String, citation: String, id: Int, version: Int,
                        edit: (WorkItem) throws -> WorkItem) throws -> ProposalReceipt {
        guard !key.isEmpty, !citation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DeskError("Source evidence ID and citation are required.")
        }
        return try transaction {
            let identity = [source.rawValue, key]
            if let prior = try rows("SELECT id FROM inbox WHERE source=? AND evidence=?", identity, { Int(sqlite3_column_int64($0, 0)) }).first {
                return ProposalReceipt(inboxID: prior, existingTaskID: nil, inserted: false)
            }
            if let old = try rows("SELECT task_id FROM sync_receipts WHERE source=? AND evidence=?", identity, { Int(sqlite3_column_int64($0, 0)) }).first {
                return ProposalReceipt(inboxID: nil, existingTaskID: old, inserted: false)
            }
            let base = id == 0 ? WorkItem() : try get(id)
            guard base.version == version else { throw DeskError("Task version changed. Review its latest fields.") }
            var draft = try edit(base)
            try validate(&draft)
            let item = Proposal(id: 0, revision: 1, state: .pending, source: source.rawValue, evidence: key,
                                citation: citation, receivedAt: ISO8601DateFormatter().string(from: Date()), base: base, draft: draft)
            try write("INSERT INTO inbox(source,evidence,body) VALUES(?,?,?)", identity + [String(decoding: try encoder.encode(item), as: UTF8.self)])
            return ProposalReceipt(inboxID: Int(sqlite3_last_insert_rowid(db)), existingTaskID: nil, inserted: true)
        }
    }

    public func editProposal(_ expected: Proposal, draft: WorkItem) throws {
        try transaction {
            var item = try currentProposal(expected)
            guard item.state == .pending || item.state == .approved else { throw DeskError("This proposal has already been reviewed.") }
            let base = item.isNew ? WorkItem() : try get(item.base.id)
            guard base.id == draft.id, base.version == draft.version else { throw DeskError("Task changed. Reopen the proposal editor.") }
            var edited = draft
            try validate(&edited)
            item.base = base
            item.draft = edited
            item.state = .pending
            try writeProposal(item)
        }
    }

    public func review(_ expected: Proposal, approve: Bool) throws {
        try transaction {
            var item = try currentProposal(expected)
            guard item.state == .pending || (!approve && item.state == .approved) else { throw DeskError("This item is no longer pending review.") }
            if approve && !item.isNew && (try? get(item.base.id).version) != item.base.version {
                throw DeskError("The target task changed or was deleted. Review the current task and edit or reject this proposal.")
            }
            item.state = approve ? .approved : .rejected
            try writeProposal(item)
        }
    }

    public func applyApproved(_ selected: [Proposal]) throws {
        try transaction {
            for expected in selected {
                var item = try currentProposal(expected)
                guard item.state == .approved else { throw DeskError("Approve the proposal before applying it.") }
                var task = item.draft
                if !item.isNew && (try? get(item.base.id).version) != item.base.version {
                    throw DeskError("The target for “\(task.title)” changed. Edit the proposal against the latest task and approve it again.")
                }
                task.references = [task.references, item.citation].filter { !$0.isEmpty }.joined(separator: "\n")
                let saved = try persist(task, actor: "Luke · Inbox")
                item.appliedTaskID = saved.id
                item.state = .applied
                try writeProposal(item)
                try write("INSERT INTO sync_receipts(source,evidence,task_id) VALUES(?,?,?)", [item.source,item.evidence,String(saved.id)])
            }
        }
    }

    public func notificationIDs() throws -> [Int] {
        try rows("SELECT id FROM inbox WHERE notified=0 AND json_extract(body,'$.state')='Pending' ORDER BY id") { Int(sqlite3_column_int64($0, 0)) }
    }
    public func markNotified(ids: [Int]) throws {
        try transaction { for id in ids { try write("UPDATE inbox SET notified=1 WHERE id=?", [String(id)]) } }
    }
}
