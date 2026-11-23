import Foundation
import Testing
import SQLite3
@testable import TaskCore

struct OutcomeTests {
    @Test func membershipsAndProposalsSurviveReopen() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("tasks.sqlite3")
        let store = try TaskStore(url: url)
        var draft = WorkItem()
        draft.title = "A legacy task"
        let a = try store.save(draft, actor: "Luke")
        draft.title = "Second task"
        let b = try store.save(draft, actor: "Luke")
        #expect(a.outcomeID == nil)
        #expect(try !JSONEncoder().encode(a).contains(Data("outcomeID".utf8)))
        var target = Outcome()
        target.name = "Release signoff"
        target.group = TaskGroup(name: "Release")
        target.dueDate = "2026-02-30"
        #expect(throws: DeskError.self) { try store.saveOutcome(target, adding: [a,b]) }
        target.dueDate = "2026-12-04"
        target.priority = .high
        let saved = try store.saveOutcome(target, adding: [a,b])
        let second = try TaskStore(url: url)
        #expect(try second.outcomes() == [saved])
        #expect(try second.all().allSatisfy { $0.outcomeID == saved.id })
        let member = try second.get(a.id)
        #expect(member.priority == .medium && member.dueDate.isEmpty)
        var other = saved
        other.name = "Name change"
        let renamed = try store.saveOutcome(other)
        #expect(throws: DeskError.self) { try second.saveOutcome(saved) }
        #expect(try store.get(a.id).outcomeID == renamed.id)
        #expect(throws: DeskError.self) { try second.saveOutcome(target, adding: [member,b]) }
        #expect(try store.get(a.id) == member && store.outcomes().count == 1)
        let moved = try second.saveOutcome(target, adding: [member])
        let current = try second.get(a.id)
        #expect(current.outcomeID == moved.id)
        #expect(try second.get(b.id).outcomeID == saved.id)
        _ = try second.proposeAgent(key: "clear-parent", citation: "Fixture", id: a.id, version: current.version) {
            var result = $0
            result.outcomeID = nil
            return result
        }
        let proposal = try #require(second.inbox().first)
        var edit = current
        edit.context = "Manual update"
        edit = try store.save(edit, actor: "Luke")
        let rebased = try proposal.editableDraft(on: edit)
        #expect(rebased.context == edit.context && rebased.outcomeID == nil)
        try second.editProposal(proposal, draft: rebased)
        try second.review(second.inbox()[0], approve: true)
        #expect(try store.get(a.id).outcomeID == moved.id)
        try second.applyApproved(second.inbox())
        #expect(try store.get(a.id).outcomeID == nil)
        var bad = try store.get(a.id)
        bad.outcomeID = -1
        #expect(throws: DeskError.self) { try store.save(bad, actor: "Luke") }
    }

    @Test func legacyOutcomeSupportsResponsiblePeople() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let file = url.appendingPathComponent("tasks.sqlite3")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var legacy: OpaquePointer?
        try #require(sqlite3_open(file.path, &legacy) == SQLITE_OK)
        let schema = """
            CREATE TABLE outcomes(id INTEGER PRIMARY KEY, version INTEGER NOT NULL, name TEXT NOT NULL,
                group_kind TEXT NOT NULL, group_name TEXT NOT NULL, due_date TEXT NOT NULL, priority TEXT NOT NULL);
            INSERT INTO outcomes VALUES(7,4,'Launch','Project','Fixture','2026-12-09','High');
            """
        let status = sqlite3_exec(legacy, schema, nil, nil, nil)
        sqlite3_close(legacy)
        try #require(status == SQLITE_OK)

        let store = try TaskStore(url: file)
        var outcome = try store.outcome(7)
        #expect(outcome.version == 4 && outcome.responsiblePeople.isEmpty)
        outcome.responsiblePeople = ["  Ana ", "LUKE", "ana", "", " Luke "]
        let saved = try store.saveOutcome(outcome)
        #expect(saved.name == "Launch" && saved.responsiblePeople == ["Ana", "LUKE"])
        let second = try TaskStore(url: file)
        var edited = try second.outcome(7)
        #expect(edited == saved)
        edited.responsiblePeople = []
        #expect(try second.saveOutcome(edited).responsiblePeople.isEmpty)
        #expect(throws: DeskError.self) { try store.saveOutcome(saved) }
    }

    @Test func deletingOutcomePreservesTasksAndRetiresItsID() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try TaskStore(url: url.appendingPathComponent("tasks.sqlite3"))
        var draft = Outcome()
        draft.name = "Release"
        draft.group.name = "Fixture"
        draft.dueDate = "2026-12-09"
        let other = try store.saveOutcome(draft)
        var target = try store.saveOutcome(draft)
        var task = WorkItem()
        task.title = "Fixture task"
        task.context = "Original context"
        task.outcomeID = other.id
        let unrelated = try store.save(task, actor: "Luke")
        task.outcomeID = target.id
        let member = try store.save(task, actor: "Luke")
        task.status = .done
        let completed = try store.save(task, actor: "Luke")
        target.responsiblePeople = ["Ana"]
        _ = try store.saveOutcome(target)
        #expect(throws: DeskError.self) { try store.deleteOutcome(target) }
        #expect(try store.get(member.id) == member)
        target = try store.outcome(target.id)
        _ = try store.proposeAgent(key: "draft", citation: "Fixture", id: 0, version: 0) { input in
            var draft = input
            draft.title = "Proposed member"
            draft.outcomeID = target.id
            return draft
        }
        try store.review(store.inbox()[0], approve: true)
        try store.deleteOutcome(target)
        #expect(try store.outcomes() == [other])
        #expect(try store.get(unrelated.id) == unrelated)
        for original in [member, completed] {
            let current = try store.get(original.id)
            #expect(current.outcomeID == nil && current.version == original.version + 1)
            #expect(current.title == original.title && current.context == original.context && current.status == original.status)
            #expect(try store.history(original.id).map(\.summary) == ["Updated outcome", "Created the task"])
        }
        let replacement = try store.saveOutcome(draft)
        #expect(replacement.id > target.id)
        #expect(throws: DeskError.self) { try store.applyApproved(store.inbox()) }
        #expect(try store.all().count == 3 && store.inbox()[0].state == .approved)
        try store.deleteOutcome(replacement)
    }
}
