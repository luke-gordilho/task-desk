import Foundation

public enum ChatProvider: String, CaseIterable {
    case codex = "Codex", claude = "Claude Code"

    var table: String {
        switch self {
        case .codex: return "task_chats"
        case .claude: return "claude_chats"
        }
    }
}

public struct ClaudeChat: Equatable {
    public let sessionID: String

    public init(_ input: String) throws {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let invalid = DeskError("Paste a Claude Code session ID or a link to a specific Claude Code session.")
        var id = value
        if let link = URLComponents(string: value), let scheme = link.scheme {
            guard link.user == nil, link.password == nil, link.port == nil, link.fragment == nil else { throw invalid }
            let parts = link.path.split(separator: "/")
            if scheme == "claude", link.host == "code", link.path == "/continue",
               let items = link.queryItems, items.count == 1, items[0].name == "session", let session = items[0].value {
                id = session
            } else if scheme == "claude", link.host == "code", parts.count == 1, link.query == nil {
                id = String(parts[0])
            } else if scheme == "https", link.host == "claude.ai", parts.count == 2, parts[0] == "code", link.query == nil {
                id = String(parts[1])
            } else { throw invalid }
        }
        if id.hasPrefix("local_"), let uuid = UUID(uuidString: String(id.dropFirst(6))) {
            sessionID = "local_" + uuid.uuidString.lowercased()
        } else if id.range(of: #"^(session|cse)_[A-Za-z0-9_-]{1,64}$"#, options: .regularExpression) != nil {
            sessionID = id.hasPrefix("cse_") ? "session_" + id.dropFirst(4) : id
        } else { throw invalid }
    }

    // Claude Desktop gives the same conversation a local routing ID and a different CLI UUID.
    // Resolve pasted UUIDs once so the stored URL always points to the original desktop chat.
    public static func existing(_ input: String, sessionDirectory: URL? = nil) throws -> ClaudeChat {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let uuid = UUID(uuidString: value) else { return try ClaudeChat(value) }

        struct SessionIDs: Decodable {
            let sessionId: String
            let cliSessionId: UUID?
        }
        let files = FileManager.default
        let root = sessionDirectory ?? files.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Claude/claude-code-sessions", isDirectory: true)
        let missing = DeskError("Open this session in Claude Code Desktop and try again, or paste its desktop session link.")
        guard let entries = files.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            throw missing
        }
        let localID = "local_" + uuid.uuidString.lowercased()
        var matches = Set<String>()
        for case let file as URL in entries where entries.level == 3 {
            entries.skipDescendants()
            guard file.lastPathComponent.hasPrefix("local_"), file.pathExtension == "json",
                  let data = try? Data(contentsOf: file, options: .mappedIfSafe),
                  let ids = try? JSONDecoder().decode(SessionIDs.self, from: data),
                  ids.sessionId == file.deletingPathExtension().lastPathComponent,
                  let chat = try? ClaudeChat(ids.sessionId),
                  ids.cliSessionId == uuid || chat.sessionID == localID else { continue }
            matches.insert(chat.sessionID)
        }
        guard let match = matches.first else { throw missing }
        guard matches.count == 1 else { throw DeskError("Several Claude chats match this UUID. Paste the desktop link for the one you want.") }
        return try ClaudeChat(match)
    }

    public var url: URL {
        let path = sessionID.hasPrefix("local_") ? "continue?session=" + sessionID : sessionID
        return URL(string: "claude://code/" + path)!
    }
}
