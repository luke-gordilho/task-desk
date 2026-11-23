import Foundation
import Testing
@testable import TaskCore

struct StoreTests {
    @Test func testSharedStoreAndStaleEditor() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("tasks.sqlite3")
        let app = try TaskStore(url: url)
        let agent = try TaskStore(url: url)
        #expect(try app.all().isEmpty)
        var draft = WorkItem()
        draft.title = "Review draft"
        draft.context = "Use the approved brief."
        draft.actions = [ActionItem(title: "Write draft", assignee: "Dot")]
        let first = try app.save(draft, actor: "Luke")
        var read = try agent.get(first.id)
        #expect(first == read)
        read.actions[0].completed = true
        read.latestUpdate = "Draft ready."
        let next = try agent.save(read, actor: "Dot")
        #expect(next.version == 2)
        #expect(try app.get(first.id) == next)
        #expect(throws: DeskError.self) { try app.save(first, actor: "Luke") }
        #expect(try app.history(first.id).map(\.actor) == ["Dot", "Luke"])
        #expect(try app.save(next, actor: "Luke").version == 2)
        #expect(try app.history(first.id).count == 2)
        read = next
        read.dueDate = "2026-02-30"
        #expect(throws: DeskError.self) { try app.save(read, actor: "Luke") }
        #expect(try agent.get(first.id) == next)
    }
    @Test func testDeleteRejectsStaleEditsAndRetiresID() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("tasks.sqlite3")
        let app = try TaskStore(url: url)
        let agent = try TaskStore(url: url)
        var draft = WorkItem()
        draft.title = "Keep"
        let kept = try app.save(draft, actor: "Luke")
        draft.title = "Delete"
        let original = try app.save(draft, actor: "Luke")
        var updated = original
        updated.latestUpdate = "Agent edit"
        let latest = try agent.save(updated, actor: "Claude")
        #expect(throws: DeskError.self) { try app.delete(original) }
        #expect(try app.history(original.id).count == 2)
        try app.delete(latest)
        #expect(try agent.all() == [kept])
        #expect(try agent.history(original.id).isEmpty)
        #expect(try agent.history(kept.id).count == 1)
        let reopened = try TaskStore(url: url)
        let replacement = try reopened.save(draft, actor: "Luke")
        #expect(replacement.id > original.id)
        #expect(throws: DeskError.self) { try agent.get(original.id) }
        #expect(throws: DeskError.self) { try agent.save(latest, actor: "Claude") }
        #expect(throws: DeskError.self) { try app.delete(latest) }
    }
    @Test func testWorkerReplayAndIndependentCheckpoints() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try TaskStore(url: dir.appendingPathComponent("tasks.sqlite3"))
        let start = Int(Date().timeIntervalSince1970) - 7200
        try store.initializeSync(from: start)
        try store.initializeSync(from: start + 1)
        let window = try store.window(.slack)
        #expect(window.from == start && window.collectionStart == start)
        let receipt = try store.propose(source: .slack, key: "m1", citation: "Slack · thread A", id: 0, version: 0) {
            var item = $0; item.title = "Prepare a draft"; return item
        }
        #expect(receipt.inserted)
        let pending = try #require(store.inbox().first)
        #expect(try store.notificationIDs() == [pending.id])
        #expect(throws: DeskError.self) { try store.applyApproved([pending]) }
        try store.review(pending, approve: true)
        #expect(try store.all().isEmpty)
        try store.applyApproved(store.inbox())
        let item = try #require(store.all().first)
        #expect(item.references.contains("thread A"))
        #expect(throws: DeskError.self) { try store.applyApproved(store.inbox()) }
        _ = try store.propose(source: .outlook, key: "mail", citation: "Outlook · thread B", id: item.id, version: item.version) {
            var edited = $0; edited.latestUpdate = "Input received"; return edited
        }
        let update = try #require(store.inbox().first)
        try store.review(update, approve: true)
        var other = item
        other.priority = .high
        let live = try store.save(other, actor: "Luke")
        let approved = try #require(store.inbox().first)
        #expect(throws: DeskError.self) { try store.applyApproved([approved]) }
        var edited = try approved.editableDraft(on: live)
        #expect(edited.priority == .high && edited.latestUpdate == "Input received")
        edited.latestUpdate = "Edited by Luke"
        try store.editProposal(approved, draft: edited)
        let revised = try #require(store.inbox().first)
        #expect(revised.state == .pending)
        try store.review(revised, approve: false)
        let replay = try store.propose(source: .outlook, key: "mail", citation: "mail", id: item.id, version: item.version) { $0 }
        #expect(!replay.inserted && replay.inboxID == update.id)
        #expect(try store.get(item.id) == live)
        try store.delete(live)
        #expect(try store.all().isEmpty)
        try store.finish(.slack, from: start, through: window.through)
        try store.fail(.teams, from: start, reason: "Needs connection")
        #expect(try store.window(.teams).from == start)
        #expect(try store.window(.teams).lastError == "Needs connection")
        #expect(try store.window(.slack).from == window.through)
        #expect(throws: DeskError.self) { try store.finish(.slack, from: start, through: window.through) }
    }
    @Test func createTaskComposerTargetsTheConfiguredDatabase() throws {
        let helper = URL(fileURLWithPath: "/tmp/Task Desk.app/Contents/Helpers/taskctl")
        let database = URL(fileURLWithPath: "/tmp/Work+Home/tasks.sqlite3")
        let url = try Handoff.createTaskLink(helper: helper, database: database)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.scheme == "codex" && components.host == "new")
        #expect(components.queryItems?.map(\.name) == ["prompt"])
        let prompt = try #require(components.queryItems?.first?.value)
        #expect(prompt.contains("TASKDESK_DB='/tmp/Work+Home/tasks.sqlite3' '/tmp/Task Desk.app/Contents/Helpers/taskctl' agent-propose"))
        #expect(url.absoluteString.contains("Work%2BHome"))
    }

    @Test func testComposerEscapingAndWorkspace() throws {
        var item = WorkItem()
        item.id = 3
        item.title = "A&B? #3 + 5%"
        item.workspace = FileManager.default.temporaryDirectory.path
        let link = try Handoff.newThread(task: item, token: UUID(), helper: URL(fileURLWithPath: "/tmp/Luke's App/tool"))
        let params = URLComponents(url: link, resolvingAgainstBaseURL: false)!.queryItems!
        #expect(link.scheme == "codex")
        #expect(link.host == "new")
        #expect(params.first(where: { $0.name == "path" })?.value == item.workspace)
        #expect(params[0].value!.contains(item.title))
        #expect(params[0].value!.contains("get 3"))
        #expect(params[0].value!.contains("thread-bind 3"))
        #expect(params[0].value!.contains("agent-propose"))
        item.workspace = "/missing/" + UUID().uuidString
        #expect(throws: DeskError.self) { try Handoff.newThread(task: item, token: UUID(), helper: URL(fileURLWithPath: "/tool")) }
    }
}
