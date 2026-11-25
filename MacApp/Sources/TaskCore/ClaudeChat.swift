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

    public var url: URL {
        let path = sessionID.hasPrefix("local_") ? "continue?session=" + sessionID : sessionID
        return URL(string: "claude://code/" + path)!
    }
}
