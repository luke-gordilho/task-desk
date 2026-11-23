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
    @Test func testComposerEscapingAndWorkspace() throws {
        var item = WorkItem()
        item.id = 3
        item.title = "A&B? #3 + 5%"
        item.workspace = FileManager.default.temporaryDirectory.path
        let link = try Handoff.link(task: item, helper: URL(fileURLWithPath: "/tmp/Luke's App/tool"))
        let params = URLComponents(url: link, resolvingAgainstBaseURL: false)!.queryItems!
        #expect(link.scheme == "codex")
        #expect(link.host == "new")
        #expect(params.first(where: { $0.name == "path" })?.value == item.workspace)
        #expect(params[0].value!.contains(item.title))
        #expect(params[0].value!.contains("get 3"))
        let claudeLink = try Handoff.link(task: item, helper: URL(fileURLWithPath: "/tmp/Luke's App/tool"), agent: .claude)
        let claude = try #require(URLComponents(url: claudeLink, resolvingAgainstBaseURL: false))
        #expect(claude.scheme == "claude" && claude.host == "code" && claude.path == "/new")
        #expect(claude.queryItems?.first(where: { $0.name == "folder" })?.value == item.workspace)
        let prompt = try #require(claude.queryItems?.first(where: { $0.name == "q" })?.value)
        #expect(prompt.contains(item.title) && prompt.contains("TASKDESK_ACTOR=Claude"))
        #expect(prompt.contains("get 3") && prompt.contains("update 3 VERSION"))
        item.workspace = "/missing/" + UUID().uuidString
        #expect(throws: DeskError.self) { try Handoff.link(task: item, helper: URL(fileURLWithPath: "/tool")) }
    }
}
