# Task Desk

Open **Task Desk** in your Mac’s user Applications folder. Press **⌘N** to add a task. Use **Next actions** to assign steps to Luke, Dot, or another person. The sidebar groups open actions by assignee. The **Context** tab holds the working brief, source references, completion criteria, and Codex instructions.

Choose **Project** for internal work or **Customer** for customer work, then enter its name. The table shows the task, its project or customer, status, priority, next assignee, and due date. Click a title for the full task. Use **Filter** to combine criteria, and click a column header or use **Sort** to order the results. Choose **System**, **Light**, or **Dark** in the sidebar.

The agent field for this grouping is `group`, for example `{"kind":"Project","name":"Internal tools"}`. Older records with both names are grouped by customer, with the previous project name included in their context.

**Open in Codex** and **Open in Claude** open editable drafts for the selected task. The Claude button opens the Code tab in Claude Desktop. Review and send the prompt to begin. Both prompts point the agent to the installed helper, which reads and updates the same local SQLite database as the Mac app. To see agent changes, return to the app or press **⌘R**.

The database lives at `~/Library/Application Support/Task Desk/tasks.sqlite3`. The command-line helper supports `list`, `get ID`, `create`, and `update ID VERSION`. Create and update take a JSON object on standard input. An update preserves omitted fields. Supplied arrays replace the corresponding collection. Read the current version before updating a task.

```sh
"$HOME/Applications/Task Desk.app/Contents/Helpers/taskctl" list
```

The Swift package is in [MacApp](MacApp/Package.swift). Run `./MacApp/install.sh` to rebuild and install. The personal workspace starts empty. The two-hour [communication worker](worker/RUNBOOK.md) uses connected Codex apps and the installed helper. Check its per-source catch-up windows and errors with `taskctl sync-status`. Agent execution handoffs are manual.

To run the regression tests with the Command Line Tools installed on this Mac:

```sh
cd MacApp
swift test -Xswiftc -plugin-path -Xswiftc "$(xcode-select -p)/usr/lib/swift/host/plugins/testing"
```

## Legacy browser tracker

The launcher and database described below belong to the earlier browser app.

Double-click **Open Tasks.command** in Finder. Keep its Terminal window open while using the viewer. To stop it, press Control-C in that window. Reopening the launcher reuses an already running tracker.

The viewer runs at http://127.0.0.1:8765 and is accessible only on this Mac. Requires Python 3; no additional packages.

Tasks are saved in `tasks.sqlite3` beside the app, not in browser storage. Project names are initially drawn from the surrounding folders. Existing Markdown trackers have not been imported or synchronized. New project names can be entered directly in the editor.

Use **New task** to create a task and **Edit** to update it. Mark completed work Done; the default view shows active tasks. Search covers title, project, owner, notes, and next action. Export JSON downloads all tasks, including completed tasks.

For a full database backup while the app is running:

```sh
cd /Users/lukegordilho/Documents/dev/movedot/task-tracker
python3 -c "import sqlite3; source=sqlite3.connect('tasks.sqlite3'); target=sqlite3.connect('tasks-backup.sqlite3'); source.backup(target); target.close(); source.close()"
```

Agents can read/update the SQLite `tasks` table directly. Preserve IDs, use parameterized SQL, and update `updated_at` on changes. Status values: To do, In progress, Blocked, Done. Priority values: High, Medium, Low. Dates: YYYY-MM-DD. The viewer reloads when its window regains focus. This database is independent of existing project Markdown trackers.

To use a different port: `python3 app.py --port 8766 --open`.
