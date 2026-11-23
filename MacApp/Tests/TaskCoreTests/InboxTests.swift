import Foundation
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
