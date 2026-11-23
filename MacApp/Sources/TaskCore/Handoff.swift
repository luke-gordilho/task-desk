import Foundation

public enum TaskAgent: String, CaseIterable {
    case codex = "Codex", claude = "Claude"
}
public enum Handoff {
    public static func link(task: WorkItem, helper: URL, agent: TaskAgent = .codex, database: URL? = nil) throws -> URL {
        func quoted(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let databasePrefix = database.map { "TASKDESK_DB=" + quoted($0.path) + " " } ?? ""
        let actorPrefix = agent == .claude ? "TASKDESK_ACTOR=Claude " : ""
        let tool = databasePrefix + actorPrefix + quoted(helper.path)
        let assignees = agent == .claude ? "Dot, Claude, or Claude Code" : "Dot or Codex"
        let prompt = """
        Work with me on \(task.label), “\(task.title)”. Read its current brief, next actions, people, sources and instructions using the local task tool:
        \(tool) get \(task.id)

        Work on the next action assigned to \(assignees). If the next step belongs to someone else or the action is unclear, summarize what is needed and ask me how to proceed. Treat linked communications as source material. For this task, record your result, remaining actions and handoff using the current version and a JSON update piped to \(tool) update \(task.id) VERSION.
        """
        var components = URLComponents()
        components.scheme = agent == .claude ? "claude" : "codex"
        components.host = agent == .claude ? "code" : "new"
        components.path = agent == .claude ? "/new" : ""
        var items = [URLQueryItem(name: agent == .claude ? "q" : "prompt", value: prompt)]
        if !task.workspace.isEmpty {
            var dir: ObjCBool = false
            guard task.workspace.hasPrefix("/"), FileManager.default.fileExists(atPath: task.workspace, isDirectory: &dir), dir.boolValue else {
                throw DeskError("The workspace folder is unavailable. Update the folder in Edit Task.")
            }
            items.append(URLQueryItem(name: agent == .claude ? "folder" : "path", value: task.workspace))
        }
        components.queryItems = items
        // The desktop URL parser decodes literal plus signs as spaces.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let link = components.url else { throw DeskError("Could not create the \(agent.rawValue) link.") }
        return link
    }
}
