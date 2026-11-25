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
    @Test func independentClaudeAndCodexSessions() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = dir.appendingPathComponent("fixture.sqlite3")
        let store = try TaskStore(url: db), otherClient = try TaskStore(url: db)
        var draft = WorkItem()
        draft.title = "Review A+B & follow up"
        draft.workspace = "/missing-fixture-folder"
        var task = try store.save(draft, actor: "Luke")
        let otherTask = try store.save(draft, actor: "Luke")
        let codex = try ChatAddress(UUID().uuidString)
        let codexToken = try store.reserveChat(task.id)
        let token = try store.reserveChat(task.id, provider: .claude)
        #expect(throws: DeskError.self) { try otherClient.reserveChat(task.id, provider: .claude) }
        try store.cancelSetup(task.id, provider: .claude, token: token)
        #expect(try store.setupPending(task.id))
        let retry = try otherClient.reserveChat(task.id, provider: .claude)
        let helper = dir.appendingPathComponent("Task Desk.app/Contents/Helpers/taskctl")
        let link = try Handoff.newClaudeChat(task: task, token: retry, helper: helper, database: db, projectFolder: dir.path)
        let components = try #require(URLComponents(url: link, resolvingAgainstBaseURL: false))
        #expect(components.scheme == "claude" && components.host == "code" && components.path == "/new")
        #expect(components.queryItems?.first { $0.name == "folder" }?.value == dir.path)
        let prompt = try #require(components.queryItems?.first { $0.name == "q" }?.value)
        #expect(prompt.hasPrefix(task.title) && prompt.contains("claude-bind \(task.id) \(retry)"))
        #expect(prompt.contains("agent-propose") && prompt.contains("TASKDESK_DB="))
        #expect(throws: DeskError.self) { try Handoff.newClaudeChat(task: task, token: retry, helper: helper) }
        let chat = try ClaudeChat("local_" + UUID().uuidString)
        #expect(try ClaudeChat(chat.url.absoluteString) == chat)
        #expect(throws: DeskError.self) { try store.bindClaudeChat(task.id, address: chat, token: token) }
        try store.bindClaudeChat(task.id, address: chat, token: retry)
        try otherClient.bindClaudeChat(task.id, address: chat, token: retry)
        try store.bindChat(task.id, address: codex, token: codexToken)
        #expect(throws: DeskError.self) { try store.bindClaudeChat(otherTask.id, address: chat) }
        let cloud = try ClaudeChat("https://claude.ai/code/session_TestFixture")
        #expect(try ClaudeChat("cse_TestFixture") == cloud)
        #expect(try ClaudeChat(cloud.url.absoluteString) == cloud)
        #expect(throws: DeskError.self) { try store.bindClaudeChat(task.id, address: cloud) }
        for bad in ["claude://code/new", "claude://code/continue?session=last", codex.url.absoluteString,
                    "https://unrelated.example/code/session_TestFixture"] {
            #expect(throws: DeskError.self) { try ClaudeChat(bad) }
        }
        task.title = "Changed title"
        task = try store.save(task, actor: "Luke")
        #expect(try otherClient.chatURL(task.id, provider: .claude) == chat.url)
        #expect(try otherClient.chat(task.id) == codex)
        try store.delete(task)
        #expect(try otherClient.chatURL(task.id, provider: .claude) == nil)
        #expect(try otherClient.inbox().isEmpty)
    }

    @Test func pastedClaudeUUIDResolvesToPersistentDesktopLink() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temp) }
        let root = temp.appendingPathComponent("claude-code-sessions")
        let profile = root.appendingPathComponent("account/org")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        let cliID = UUID(), desktopID = UUID()
        func writeSession(_ desktop: UUID) throws -> ClaudeChat {
            let chat = try ClaudeChat("local_" + desktop.uuidString)
            let metadata = ["cliSessionId": cliID.uuidString.lowercased(), "sessionId": chat.sessionID]
            try JSONEncoder().encode(metadata).write(to: profile.appendingPathComponent(chat.sessionID + ".json"))
            return chat
        }
        let expected = try writeSession(desktopID)
        let address = try ClaudeChat.existing(" " + cliID.uuidString + "\n", sessionDirectory: root)
        #expect(address == expected)
        #expect(try ClaudeChat.existing(desktopID.uuidString, sessionDirectory: root) == expected)
        #expect(throws: DeskError.self) { try ClaudeChat.existing(UUID().uuidString, sessionDirectory: root) }
        let store = try TaskStore(url: temp.appendingPathComponent("test.sqlite3"))
        var item = WorkItem()
        item.title = "Fixture"
        let task = try store.save(item, actor: "Luke")
        try store.bindClaudeChat(task.id, address: address)
        #expect(try store.chatURL(task.id, provider: .claude) == expected.url)
        _ = try writeSession(UUID())
        #expect(throws: DeskError.self) { try ClaudeChat.existing(cliID.uuidString, sessionDirectory: root) }
        #expect(try ClaudeChat.existing(expected.url.absoluteString, sessionDirectory: root) == expected)
    }

}
