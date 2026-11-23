import Foundation
import Testing
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
}
