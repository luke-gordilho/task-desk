import SwiftUI
import TaskCore

struct TaskDetail: View {
    @EnvironmentObject var desk: Desk
    let item: WorkItem
    private func pretty(_ value: String) -> String {
        ISO8601DateFormatter().date(from: value)?.formatted(date: .abbreviated, time: .shortened) ?? value
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text(item.label).font(.caption.monospacedDigit()).foregroundStyle(Ink.muted)
                    Spacer()
                    Button("Delete task…", role: .destructive) { desk.pendingDelete = item }
                    Button("Edit task") { desk.edit = item }
                }
                Text(item.title).font(.system(size: 26, weight: .semibold)).textSelection(.enabled)
                HStack {
                    Text(item.status.rawValue).foregroundStyle(Ink.primary).padding(.horizontal, 8).padding(.vertical, 4).background(Ink.secondary, in: Capsule())
                    Text(item.priority.rawValue + " priority").foregroundStyle(Ink.muted)
                }.font(.caption.weight(.medium))
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 7) {
                    info("Owner", item.owner)
                    info(item.group.kind.rawValue, item.group.name)
                    info("Helping", item.collaborators.joined(separator: ", "))
                    info("Due", item.dueDate)
                    info("Follow up", item.followUpDate)
                }
                HStack {
                    Button { desk.open(item) } label: { Label("Open in Codex", systemImage: "arrow.up.forward.app") }
                    if let latest = desk.results.first(where: { $0.taskID == item.id && $0.unread }) {
                        Button("Open unread Brain update") { desk.openResult(latest) }
                    }
                }.controlSize(.large)
                Divider()
                Text("Next actions").font(.headline)
                if item.actions.isEmpty {
                    Button("Add a next action") { desk.edit = item }.buttonStyle(.link)
                }
                ForEach(item.actions) { action in
                    HStack(alignment: .top, spacing: 8) {
                        Button {
                            var value = item
                            guard let idx = value.actions.firstIndex(where: { $0.id == action.id }) else { return }
                            value.actions[idx].completed.toggle()
                            do { try desk.save(value) } catch { desk.error = error.localizedDescription; desk.refresh() }
                        } label: {
                            Image(systemName: action.completed ? "checkmark.circle.fill" : "circle").foregroundStyle(Ink.primary)
                        }.buttonStyle(.plain).accessibilityLabel(action.completed ? "Reopen " + action.title : "Complete " + action.title)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(action.title).strikethrough(action.completed)
                            Text(action.assignee.isEmpty ? "Unassigned" : action.assignee).font(.caption).foregroundStyle(Ink.muted)
                        }
                    }
                }
                section("Latest update", item.latestUpdate)
                section("Context", item.context)
                section("Done when", item.doneWhen)
                section("Sources and files", item.references)
                section("Agent instructions", item.agentInstructions)
                section("Workspace folder", item.workspace)
                Divider()
                DisclosureGroup("Activity") {
                    VStack(alignment: .leading, spacing: 9) {
                        ForEach(desk.history(item.id)) { event in
                            Text(event.actor + " · " + event.summary)
                            Text(pretty(event.date)).font(.caption).foregroundStyle(Ink.muted)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
                }
                Text("Created " + pretty(item.createdAt) + " · Updated " + pretty(item.updatedAt)).font(.caption).foregroundStyle(Ink.muted)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(24)
        }
    }
    @ViewBuilder private func info(_ label: String, _ value: String) -> some View {
        if !value.isEmpty { GridRow { Text(label).foregroundStyle(Ink.muted); Text(value).textSelection(.enabled) } }
    }
    @ViewBuilder private func section(_ title: String, _ value: String) -> some View {
        if !value.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                Text(value).textSelection(.enabled)
            }
        }
    }
}
