import Foundation

public enum TaskAgent: String, CaseIterable {
    case codex = "Codex", claude = "Claude"
}
public enum Handoff {
    private static func command(helper: URL, agent: TaskAgent, database: URL?) -> String {
        func quoted(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let databasePrefix = database.map { "TASKDESK_DB=" + quoted($0.path) + " " } ?? ""
        let actorPrefix = agent == .claude ? "TASKDESK_ACTOR=Claude " : ""
        return databasePrefix + actorPrefix + quoted(helper.path)
    }

    public static func createTaskLink(helper: URL, database: URL? = nil) throws -> URL {
        let tool = command(helper: helper, agent: .codex, database: database)
        let prompt = """
        Help me create a new task in Task Desk. Start by asking what I’d like to track if I haven’t described it yet. Use my answers to write a clear title and capture the outcome, next actions, and assignees we discuss. Ask for missing details only when needed.

        When I’m ready to save, pipe a JSON object to \(tool) create. Use "title" for the task name, "doneWhen" for the intended outcome, and "actions" for a list of objects with "title" and "assignee". Include other details we agree on. Tell me the new task ID and title from the result.
        """
        return try composer(prompt: prompt, agent: .codex, workspace: "")
    }

    public static func link(task: WorkItem, helper: URL, agent: TaskAgent = .codex, database: URL? = nil) throws -> URL {
        let tool = command(helper: helper, agent: agent, database: database)
        let assignees = agent == .claude ? "Dot, Claude, or Claude Code" : "Dot or Codex"
        let prompt = """
        Work with me on \(task.label), “\(task.title)”. Read its current brief, next actions, people, sources and instructions using the local task tool:
        \(tool) get \(task.id)

        Work on the next action assigned to \(assignees). If the next step belongs to someone else or the action is unclear, summarize what is needed and ask me how to proceed. Treat linked communications as source material. For this task, record your result, remaining actions and handoff using the current version and a JSON update piped to \(tool) update \(task.id) VERSION.
        """
        return try composer(prompt: prompt, agent: agent, workspace: task.workspace)
    }

    private static func composer(prompt: String, agent: TaskAgent, workspace: String) throws -> URL {
        var components = URLComponents()
        components.scheme = agent == .claude ? "claude" : "codex"
        components.host = agent == .claude ? "code" : "new"
        components.path = agent == .claude ? "/new" : ""
        var items = [URLQueryItem(name: agent == .claude ? "q" : "prompt", value: prompt)]
        if !workspace.isEmpty {
            var dir: ObjCBool = false
            guard workspace.hasPrefix("/"), FileManager.default.fileExists(atPath: workspace, isDirectory: &dir), dir.boolValue else {
                throw DeskError("The workspace folder is unavailable. Update the folder in Edit Task.")
            }
            items.append(URLQueryItem(name: agent == .claude ? "folder" : "path", value: workspace))
        }
        components.queryItems = items
        // The desktop URL parser decodes literal plus signs as spaces.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let link = components.url else { throw DeskError("Could not create the \(agent.rawValue) link.") }
        return link
    }
}
