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
        CREATE TABLE IF NOT EXISTS retired_task_ids(id INTEGER PRIMARY KEY);
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
    public func save(_ draft: WorkItem, actor: String) throws -> WorkItem {
        var item = draft
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
        try exec("BEGIN IMMEDIATE")
        do {
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
                if current == item { try exec("COMMIT"); return current }
                item.version += 1
                summary = Self.changeSummary(from: current, to: item)
            }
            item.updatedAt = stamp
            let body = String(decoding: try encoder.encode(item), as: UTF8.self)
            try write("UPDATE tasks SET version=?,body=? WHERE id=?", [String(item.version), body, String(item.id)])
            try write("INSERT INTO changes(task_id,stamp,actor,summary) VALUES(?,?,?,?)", [String(item.id), stamp, actor, summary])
            try exec("COMMIT")
            return item
        } catch {
            try? exec("ROLLBACK")
            throw error
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
