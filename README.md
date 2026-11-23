# Task Desk

Open **Task Desk** in your Mac’s user Applications folder. Press **⌘N** to add a task. Use **Next actions** to assign steps to Luke, Dot, or another person. The sidebar groups open actions by assignee. The **Context** tab holds the working brief, source references, completion criteria, and Codex instructions.

Choose **Create task with AI** beside **New task** to open an editable prompt in Codex. Send the prompt, describe the task, and tell Codex when to save it. Review the draft in the Inbox. Approve it and choose Apply to tasks to create the live task.

Open **Outcomes** in the sidebar to organize tasks around a shared result. Choose **New outcome**, enter a name, choose or enter its project or customer, pick a due date on the calendar, and set its priority. Select any existing tasks that contribute to it. Opening an outcome shows all its tasks, including completed work. Use **New task** there to preselect the outcome and project, or use **Edit outcome** to move several tasks in one save. A task can belong to one outcome at a time. The **Unassigned tasks** view includes tasks created before outcomes were added.

Agents can list outcome IDs with `taskctl outcomes` and propose a task assignment through the Inbox using `outcomeID`. A JSON null removes the assignment. Each task retains its own priority and dates.

Choose **Project** for internal work or **Customer** for customer work, then enter its name. The table shows the task, its project or customer, status, priority, next assignee, and due date. Click a title for the full task. Use **Filter** to combine criteria, and click a column header or use **Sort** to order the results. Choose **System**, **Light**, or **Dark** in the sidebar.

The agent field for this grouping is `group`, for example `{"kind":"Project","name":"Internal tools"}`. Older records with both names are grouped by customer, with the previous project name included in their context.

**Open in Codex** links one chat to a task. On first use, paste an existing Codex thread UUID or link, or choose **New Codex chat** and send the setup message. The message binds that chat on the Task Desk Mac. Later clicks reopen its stored ID. If setup was interrupted, finish the open composer, paste its link, or explicitly cancel unfinished setup. Task renames preserve the link.

The database lives at `~/Library/Application Support/Task Desk/tasks.sqlite3`. The command-line helper supports `list`, `get ID` and `agent-propose KEY ID VERSION`. Use ID and version zero for a new draft. The older `create` and `update ID VERSION` commands also stage proposals. Each takes a JSON object on standard input. An update preserves omitted fields. Supplied arrays replace the corresponding collection. Read the current version before updating a task.

```sh
"$HOME/Applications/Task Desk.app/Contents/Helpers/taskctl" list
```

The Swift package is in [MacApp](MacApp/Package.swift). Run `./MacApp/install.sh` to rebuild and install. The personal workspace starts empty. The [communication worker](worker/RUNBOOK.md) uses connected Codex apps and the installed helper. Check its per-source catch-up windows and errors with `taskctl sync-status`. Agent execution handoffs are manual.

To run the regression tests with the Command Line Tools installed on this Mac:

```sh
cd MacApp
swift test -Xswiftc -plugin-path -Xswiftc "$(xcode-select -p)/usr/lib/swift/host/plugins/testing"
```

## Review inbox

The communication worker checks all five sources every two hours on weekdays, from 09:15 through 19:15 São Paulo time. It stages new tasks and updates in **Inbox**. Select a proposal to see the changed fields, next actions and source links. **Edit** saves a draft, **Reject** dismisses it, and **Approve** moves it to the Approved tab. Use **Apply to tasks** for one proposal or **Apply all approved** for the group. If a live task changes, review the current values in the editor and approve again. Old evidence keeps its review decision across retries.

The installed helper accepts `sync-propose SOURCE KEY ID VERSION` with `citation` and `patch` on standard input. Read review states with `inbox-list`. The legacy `sync-apply` spelling also stages a proposal. Task Desk asks macOS for notification permission on the first new arrival. Granted permission enables grouped alerts even when the window is closed. Selecting an alert opens the Inbox.

## Brain work in a task chat

On the Task Desk Mac, pass Luke’s authorized scope on standard input to `taskctl brain-dispatch TASK_ID EVENT_UUID`. Reuse one UUID per assignment. The helper queues a message to the linked local UUID with the Codex CLI and requests a resume. A queued receipt confirms submission only. An unconfirmed dispatch requires checking that same chat before another attempt.

For Brain callers with Codex desktop tools, `taskctl brain-handoff TASK_ID EVENT_UUID` accepts the same input and returns the `threadId`, optional `hostId` and prompt for `send_message_to_thread`. Resolve the linked chat with `read_thread` on that host before sending. Choose one dispatch path per assignment. If the Mac or chat is unavailable, report the blocker and keep its link. Brain needs access to this helper or a bridge on the Mac. The communication sync only collects evidence for the Inbox.

The linked chat posts a short account of the work, result and next step. It uses `taskctl brain-result TASK_ID EVENT_UUID` to register the same material result in **Brain updates**, with JSON strings `work`, `result` and `next` on stdin. The helper checks the current Codex thread ID. Replays and identical notes keep a single unread entry. A no-op scan skips this command or returns `{"outcome":"no_change"}`. Clicking an update opens the task chat. With notification permission, the Mac also submits a task-titled alert linked to that result. Task state changes still require Inbox approval and application. Customer and teammate outreach requires Luke’s consent.

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
