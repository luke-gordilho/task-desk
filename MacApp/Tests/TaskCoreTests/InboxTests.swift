import Foundation
import SQLite3
import Testing
@testable import TaskCore

struct InboxTests {
    @Test func approvedBatchIsAtomicAndKeepsConcurrentEdits() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("tasks.sqlite3")
        let store = try TaskStore(url: url)
        let other = try TaskStore(url: url)
        var draft = WorkItem()
        draft.title = "Original"
        let item = try store.save(draft, actor: "Luke")
        _ = try store.propose(source: .teams, key: "reply", citation: "Teams reply", id: item.id, version: item.version) {
            var draft = $0
            draft.context = "Suggested context"
            draft.status = .active
            return draft
        }
        _ = try store.propose(source: .plaud, key: "recording", citation: "Recording", id: 0, version: 0) {
            var draft = $0
            draft.title = "New task"
            return draft
        }
        let pending = try store.inbox()
        #expect(try other.notificationIDs().count == 2)
        try store.markNotified(ids: [pending[0].id])
        #expect(try other.notificationIDs() == [pending[1].id])
        for p in pending { try store.review(p, approve: true) }
        let approved = try store.inbox()
        var manual = item
        manual.context = "Human edit"
        let current = try other.save(manual, actor: "Luke")
        #expect(throws: DeskError.self) { try store.applyApproved(approved) }
        #expect(try store.all() == [current])
        #expect(try store.inbox().allSatisfy { $0.state == .approved })
        let stale = approved[1]
        var merged = try stale.editableDraft(on: current)
        #expect(merged.context == current.context && merged.status == .active)
        merged.context += "\nReviewed addition"
        try store.editProposal(stale, draft: merged)
        let edited = try store.inbox()[1]
        #expect(edited.state == .pending)
        try store.review(edited, approve: true)
        try store.applyApproved(store.inbox())
        #expect(try other.all().count == 2)
        #expect(try other.get(item.id).context == merged.context)
        #expect(try other.get(item.id).references == "Teams reply")
        #expect(try other.inbox().allSatisfy { $0.state == .applied })
    }
}

extension InboxTests {
    @Test func successiveUpdatesNeedOneApprovalAcrossProcesses() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("tasks.sqlite3")
        let store = try TaskStore(url: url), worker = try TaskStore(url: url)
        var initial = WorkItem()
        initial.title = "Fixture"
        initial.context = "Brief"
        initial.actions = [ActionItem(title: "Check")]
        let task = try store.save(initial, actor: "Luke")
        let extra = ActionItem(title: "Follow up")
        let first = try store.proposeAgent(key: "one", citation: "Chat", id: task.id, version: task.version) {
            var draft = $0
            draft.actions[0].completed = true
            draft.actions.append(extra)
            draft.context += "\nFirst note"
            draft.collaborators = ["Sam"]
            draft.latestUpdate = "Initial result"
            draft.priority = .high
            return draft
        }
        let stale = try #require(store.inbox().first)
        try store.review(stale, approve: true)
        let approved = try store.inbox()
        let second = try worker.propose(source: .teams, key: "two", citation: "Teams", id: task.id,
                                        version: task.version, fields: ["priority"]) {
            var draft = $0
            draft.actions[0].assignee = "Luke"
            draft.context += "\nSecond note"
            draft.collaborators = ["Ana"]
            draft.latestUpdate = "Corrected result"
            return draft
        }
        #expect(first.inboxID == second.inboxID && !second.inserted && second.updated == true)
        #expect(try store.inbox().count == 1 && store.get(task.id) == task)
        #expect(throws: DeskError.self) { try store.applyApproved(approved) }
        #expect(throws: DeskError.self) { try store.review(stale, approve: true) }
        let review = try #require(store.inbox().first)
        #expect(review.state == .pending && review.contributionCount == 2)
        #expect(review.draft.priority == task.priority && review.draft.latestUpdate == "Corrected result")
        #expect(review.draft.actions[0].completed && review.draft.actions[0].assignee == "Luke")
        #expect(review.draft.actions.last == extra && review.draft.collaborators == ["Sam","Ana"])
        #expect(review.draft.context == "Brief\nFirst note\n\nSecond note")
        #expect(try store.notificationIDs() == [review.id])
        try store.review(review, approve: true)
        try store.applyApproved(store.inbox())
        let saved = try worker.get(task.id)
        #expect(saved.version == task.version + 1 && saved.references == "Chat\nTeams")
        let replay = try worker.propose(source: .teams, key: "two", citation: "Teams", id: task.id, version: task.version) { $0 }
        #expect(!replay.inserted && replay.inboxID == review.id)
        let fresh = try worker.proposeAgent(key: "three", citation: "Chat", id: task.id, version: saved.version) {
            var draft = $0
            draft.status = .blocked
            return draft
        }
        #expect(fresh.inboxID != review.id)
        #expect(try store.inbox().count == 2)
    }

    @Test func legacyOpenDuplicatesMergeOnUpgradeAndReplaysRespectRejection() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("fixture.sqlite3")
        let task: WorkItem
        do {
            let old = try TaskStore(url: url)
            var draft = WorkItem()
            draft.title = "Fixture"
            task = try old.save(draft, actor: "Luke")
            for index in 1...3 {
                _ = try old.proposeAgent(key: String(index), citation: "Chat", id: task.id, version: task.version) {
                    var item = $0
                    item.latestUpdate = "Update \(index)"
                    if index == 1 { item.status = .active }
                    return item
                }
                try old.review(old.inbox()[0], approve: false)
            }
        }
        // Reproduce the earlier schema with two outstanding reviews and one closed decision.
        var db: OpaquePointer?
        try #require(sqlite3_open(url.path, &db) == SQLITE_OK)
        let sql = """
            ALTER TABLE inbox DROP COLUMN merged_into;
            UPDATE inbox SET body=json_set(body,'$.state','Approved') WHERE id=1;
            UPDATE inbox SET body=json_set(body,'$.state','Pending') WHERE id=2;
            """
        let code = sqlite3_exec(db, sql, nil, nil, nil)
        sqlite3_close(db)
        try #require(code == SQLITE_OK)
        let store = try TaskStore(url: url)
        let entries = try store.inbox()
        #expect(entries.count == 2 && entries.first?.state == .rejected)
        let merged = try #require(entries.last)
        #expect(merged.id == 1 && merged.state == .pending && merged.contributionCount == 2)
        #expect(merged.draft.latestUpdate == "Update 2" && merged.draft.status == .active && merged.citation == "Chat")
        try store.review(merged, approve: false)
        for key in ["1", "2"] {
            let result = try store.proposeAgent(key: key, citation: "Chat", id: task.id, version: task.version) { $0 }
            #expect(result.inboxID == merged.id && !result.inserted)
        }
        #expect(try TaskStore(url: url).inbox().allSatisfy { $0.state == .rejected })
        #expect(try store.get(task.id) == task)
    }
}
