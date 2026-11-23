import Foundation
import Testing
@testable import TaskCore

struct ChatTests {
    @Test func firstUseAndResultLifecycle() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = dir.appendingPathComponent("fixture.sqlite3")
        let store = try TaskStore(url: db), second = try TaskStore(url: db)
        var draft = WorkItem()
        draft.title = "Fixture"
        var task = try store.save(draft, actor: "Luke")
        let other = try store.save(draft, actor: "Luke")
        let address = try ChatAddress(UUID().uuidString)
        #expect(try store.chat(task.id) == nil)
        let reservation = try store.reserveChat(task.id)
        #expect(throws: DeskError.self) { try second.reserveChat(task.id) }
        try store.cancelSetup(task.id, token: reservation)
        let retry = try second.reserveChat(task.id)
        #expect(throws: DeskError.self) { try store.bindChat(task.id, address: address, token: reservation) }
        try second.bindChat(task.id, address: address, token: retry)
        try second.bindChat(task.id, address: address, token: retry)
        #expect(throws: DeskError.self) { try second.bindChat(other.id, address: address) }
        #expect(throws: DeskError.self) { try second.bindChat(task.id, address: ChatAddress(UUID().uuidString)) }
        task.title = "Renamed"
        let live = try store.save(task, actor: "Luke")
        #expect(try TaskStore(url: db).chat(task.id)?.url == address.url)
        let remote = try ChatAddress(address.url.absoluteString + "?hostId=mac-1")
        #expect(remote.hostID == "mac-1")
        #expect(try ChatAddress(remote.url.absoluteString) == remote)
        #expect(throws: DeskError.self) { try ChatAddress("codex://new?prompt=wrong") }
        let run = UUID()
        #expect(try store.beginDispatch(task.id, event: run, scope: "Review fixture") == nil)
        #expect(try second.beginDispatch(task.id, event: run, scope: "Review fixture") == "unconfirmed")
        try store.markQueued(task.id, event: run)
        #expect(try second.beginDispatch(task.id, event: run, scope: "Review fixture") == "queued")
        let note = BrainNote(work: "Read fixture", result: "Found two issues", next: "Luke reviews")
        #expect(throws: DeskError.self) { try store.recordResult(taskID: task.id, threadID: UUID().uuidString, key: "a", note: note) }
        #expect(try store.recordResult(taskID: task.id, threadID: address.threadID, key: "a", note: note))
        #expect(try !second.recordResult(taskID: task.id, threadID: address.threadID, key: "a", note: note))
        #expect(try !second.recordResult(taskID: task.id, threadID: address.threadID, key: "b", note: note))
        let entry = try #require(store.brainResults().first)
        #expect(entry.title == "Renamed" && entry.chat == address && entry.unread)
        #expect(try store.claimResultNotification(entry.id))
        #expect(try !second.claimResultNotification(entry.id))
        try second.markResultRead(entry.id)
        #expect(try store.brainResults().allSatisfy { !$0.unread })
        #expect(try store.get(task.id) == live)
        #expect(try store.inbox().isEmpty)
        try store.delete(live)
        #expect(try second.chat(task.id) == nil && second.brainResults().isEmpty)
    }
}
