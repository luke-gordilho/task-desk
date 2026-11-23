import SwiftUI
import UserNotifications
import TaskCore

private typealias InboxState<Value> = SwiftUI.State<Value>

private struct FieldChange: Identifiable {
    let id: String
    let before: String
    let after: String
}

private func changes(from base: WorkItem, to item: WorkItem, new: Bool = false) -> [FieldChange] {
    var fields: [FieldChange] = []
    func add(_ name: String, _ old: String, _ proposed: String) {
        if new ? !proposed.isEmpty : old != proposed {
            fields.append(FieldChange(id: name, before: new ? "" : old, after: proposed))
        }
    }
    func group(_ item: WorkItem) -> String { item.group.name.isEmpty ? "" : item.group.kind.rawValue + " · " + item.group.name }
    add("Title", base.title, item.title)
    add("Project / Customer", group(base), group(item))
    add("Status", base.status.rawValue, item.status.rawValue)
    add("Priority", base.priority.rawValue, item.priority.rawValue)
    add("Owner", base.owner, item.owner)
    add("Collaborators", base.collaborators.joined(separator: ", "), item.collaborators.joined(separator: ", "))
    add("Due date", base.dueDate, item.dueDate)
    add("Follow up", base.followUpDate, item.followUpDate)
    func actions(_ item: WorkItem) -> String {
        item.actions.map { ($0.completed ? "☑ " : "☐ ") + $0.title + ($0.assignee.isEmpty ? "" : " · " + $0.assignee) }.joined(separator: "\n")
    }
    add("Next actions", actions(base), actions(item))
    add("Context", base.context, item.context)
    add("Done when", base.doneWhen, item.doneWhen)
    add("Latest update", base.latestUpdate, item.latestUpdate)
    add("Source notes", base.references, item.references)
    add("Agent instructions", base.agentInstructions, item.agentInstructions)
    add("Workspace folder", base.workspace, item.workspace)
    return fields
}

private struct InboxEdit: Identifiable {
    let proposal: Proposal
    let draft: WorkItem
    var id: Int { proposal.id }
}

struct InboxView: View {
    @EnvironmentObject var desk: Desk
    @InboxState private var tab = ReviewState.pending
    @InboxState private var selection: Int?
    @InboxState private var edit: InboxEdit?
    @InboxState private var denied = false
    @Environment(\.scenePhase) private var phase
    private var items: [Proposal] { desk.proposals.filter { $0.state == tab } }
    private var selected: Proposal? { items.first { $0.id == selection } ?? items.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Inbox").font(.system(size: 26, weight: .semibold))
                Spacer()
                if tab == .approved, !items.isEmpty {
                    Button("Apply all approved (\(items.count))") { desk.changeInbox { try $0.applyApproved(items) } }
                }
            }.padding(.horizontal, 20).padding(.top, 18)
            Picker("Review status", selection: $tab) {
                ForEach(ReviewState.allCases, id: \.self) { state in
                    Text(state.rawValue + " (\(desk.proposals.filter { $0.state == state }.count))").tag(state)
                }
            }.pickerStyle(.segmented).labelsHidden().padding(.horizontal, 20).padding(.vertical, 12)
            if denied {
                HStack {
                    Text("Mac notifications are turned off for Task Desk.").font(.callout)
                    Button("Notification settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") { NSWorkspace.shared.open(url) }
                    }
                }.padding(.horizontal, 20).padding(.bottom, 10)
            }
            Divider()
            if let p = selected {
                HSplitView {
                    List(items, selection: Binding(get: { selected?.id }, set: { selection = $0 })) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.isNew ? "New task" : "Update · " + item.base.label).font(.caption).foregroundStyle(.secondary)
                            Text(item.draft.title).lineLimit(2)
                        }.padding(.vertical, 4).tag(item.id)
                    }.listStyle(.sidebar).frame(minWidth: 185, idealWidth: 245, maxWidth: 330)
                    proposalDetail(p).frame(minWidth: 340)
                }
            } else {
                ContentUnavailableView("No \(tab.rawValue.lowercased()) proposals", systemImage: "tray")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: phase) { denied = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .denied }
        .sheet(item: $edit) { session in
            TaskEditor(draft: session.draft) { edited in
                try desk.reviewStore().editProposal(session.proposal, draft: edited)
                desk.refresh()
                tab = .pending
                selection = session.id
            }.environmentObject(desk)
        }
    }

    private func proposalDetail(_ p: Proposal) -> some View {
        let live = desk.tasks.first { $0.id == p.base.id }
        let stale = !p.isNew && live?.version != p.base.version
        return VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 13) {
                    Text(p.isNew ? "New task" : "Update · " + p.base.label).font(.caption).foregroundStyle(Ink.muted)
                    Text(p.draft.title).font(.title2.bold())
                    if let id = p.appliedTaskID { Text("Applied to T-" + String(format: "%03d", id)).font(.subheadline) }
                    if stale && (p.state == .pending || p.state == .approved) {
                        if let live {
                            Text("The task changed. Edit the proposal to review it against the latest version. Conflicting fields start with the live value.").foregroundStyle(Ink.warning)
                            ForEach(changes(from: p.base, to: live)) { field in
                                Text("Current \(field.id.lowercased()) · \(field.after.isEmpty ? "Empty" : field.after)").font(.callout)
                            }
                        } else { Text("The target task was deleted. You can reject this proposal.").foregroundStyle(Ink.warning) }
                    }
                    ForEach(changes(from: p.base, to: p.draft, new: p.isNew)) { change in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(change.id).font(.caption.weight(.semibold)).foregroundStyle(Ink.muted)
                            if !change.before.isEmpty { Text("Previously · " + change.before).foregroundStyle(.secondary).font(.callout) }
                            Text(change.after.isEmpty ? "Clear field" : change.after)
                        }
                    }
                    Divider()
                    Text("Evidence").font(.headline)
                    ForEach(Array(p.citation.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                        if let start = line.range(of: "https://"), let url = URL(string: String(line[start.lowerBound...])) {
                            let name = line[..<start.lowerBound].trimmingCharacters(in: .whitespaces)
                            Link(name.isEmpty ? url.absoluteString : name, destination: url)
                        } else { Text(line) }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(20).textSelection(.enabled)
            }
            if p.state == .pending || p.state == .approved {
                Divider()
                HStack {
                    Button("Reject") { desk.changeInbox { try $0.review(p, approve: false) } }
                    Spacer()
                    Button("Edit") {
                        do { edit = try InboxEdit(proposal: p, draft: p.editableDraft(on: live ?? WorkItem())) }
                        catch { desk.error = error.localizedDescription }
                    }.disabled(!p.isNew && live == nil)
                    if p.state == .pending {
                        Button("Approve") { desk.changeInbox { try $0.review(p, approve: true) } }
                            .buttonStyle(PrimaryButton()).disabled(stale)
                    } else {
                        Button("Apply to tasks") { desk.changeInbox { try $0.applyApproved([p]) } }
                            .buttonStyle(PrimaryButton()).disabled(stale)
                    }
                }.padding(14)
            }
        }.background(Ink.surface)
    }
}
