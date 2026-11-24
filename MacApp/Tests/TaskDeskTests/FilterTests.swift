import Foundation
import Testing
import TaskCore
@testable import TaskDesk

struct FilterTests {
    @Test func focusIsIndependentAndOlderTasksDefaultToOff() throws {
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        var old = try #require(JSONSerialization.jsonObject(with: encoder.encode(WorkItem())) as? [String: Any])
        old.removeValue(forKey: "focus")
        var task = try decoder.decode(WorkItem.self, from: JSONSerialization.data(withJSONObject: old))
        #expect(!task.focus)
        task.status = .blocked
        task.focus = true
        #expect(try decoder.decode(WorkItem.self, from: encoder.encode(task)) == task)
        var filters = TaskFilters()
        filters.focus = true
        #expect(try decoder.decode(TaskFilters.self, from: encoder.encode(filters)).includes(task))
        filters.focus = false
        #expect(!filters.includes(task))
        task.focus = false
        #expect(filters.includes(task) && task.status == .blocked)
    }

    @Test func nextStepOwnerFollowsChecklistOrder() {
        var task = WorkItem()
        task.actions = [ActionItem(title: "Merge into dev", assignee: " Gabriel "),
                        ActionItem(title: "Test the feature", assignee: "Luke")]
        var filters = TaskFilters()
        filters.people = ["gabriel"]
        #expect(task.nextStepOwner == "Gabriel" && filters.includes(task))
        filters.people = ["luke"]
        #expect(!filters.includes(task))
        task.actions[0].assignee = ""
        #expect(task.nextStepOwner.isEmpty && !filters.includes(task))
        task.actions[0].completed = true
        #expect(task.nextStepOwner == "Luke" && filters.includes(task))
        task.actions[1].completed = true
        #expect(task.nextStep == nil && !filters.includes(task))
        task.actions[0].completed = false
        #expect(task.nextStep?.title == "Merge into dev")
    }

    @Test func movingStepsPreservesTheChecklistAndUpdatesItsOwner() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("tasks.sqlite3")
        let store = try TaskStore(url: url)
        var task = WorkItem()
        task.title = "Release feature"
        var design = ActionItem(title: "Design feature", assignee: "Dot")
        design.completed = true
        let merge = ActionItem(title: "Merge feature", assignee: "Gabriel")
        let test = ActionItem(title: "Test feature", assignee: "Luke")
        task.actions = [design, test, merge]
        task = try store.save(task, actor: "Luke")
        task.moveStep(design.id, up: true)
        task.moveStep(merge.id, up: false)
        #expect(task.actions == [design, test, merge])
        task.moveStep(merge.id, up: true)
        _ = try store.save(task, actor: "Luke")
        var reopened = try TaskStore(url: url).get(task.id)
        #expect(reopened.actions == [design, merge, test])
        #expect(reopened.nextStepOwner == "Gabriel")
        reopened.moveStep(merge.id, up: false)
        #expect(reopened.actions == [design, test, merge])
        #expect(reopened.nextStepOwner == "Luke")
    }

    @Test func multipleOutcomesAndUnassignedSurviveSaving() throws {
        var filters = TaskFilters()
        filters.priorities = [.high]
        filters.outcomeIDs = [7, 8, nil]
        let preset = Visualization(name: "Launch", filters: filters, search: "")
        let data = try JSONEncoder().encode(preset)
        let restored = try JSONDecoder().decode(Visualization.self, from: data).filters
        #expect(restored == filters)
        #expect(restored.count == 4)
        var task = WorkItem()
        task.priority = .high
        for id: Int? in [nil, 7, 8] {
            task.outcomeID = id
            #expect(restored.includes(task))
        }
        task.outcomeID = 9
        #expect(!restored.includes(task))
        task.outcomeID = 7
        task.priority = .low
        #expect(!restored.includes(task))
    }

    @MainActor @Test func visualizationsRestoreSettingsAndToolbarOrderAcrossLaunches() throws {
        let suite = "TaskDeskTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: dir)
        }
        let store = try TaskStore(url: dir.appendingPathComponent("tasks.sqlite3"))
        let desk = Desk(defaults: defaults, store: store)
        let sorts = [DeskSort.updated.comparator, DeskSort.title.comparator]
        desk.sortOrder = sorts
        try desk.saveVisualization(named: "Updates")
        desk.filters.focus = true
        desk.search = "merge"
        desk.groupByOutcome = false
        desk.sortOrder = [DeskSort.focus.comparator]
        try desk.saveVisualization(named: "Focus")
        try desk.saveVisualization(named: "Review")
        let original = desk.visualizations
        #expect(original.map(\.name) == ["Updates", "Focus", "Review"])
        #expect(try desk.moveVisualization(original[2].id, to: original[0].id))
        #expect(try desk.moveVisualization(original[0].id, to: original[1].id))
        let reopened = Desk(defaults: defaults, store: store)
        #expect(reopened.visualizations.map(\.id) == [original[2].id, original[1].id, original[0].id])
        reopened.apply(original[0])
        #expect(reopened.sortOrder == sorts && reopened.groupByOutcome && reopened.filters.count == 0)
        #expect(reopened.matches(original[0]))
        reopened.sortOrder[0].order = .forward
        #expect(!reopened.matches(original[0]))
        reopened.apply(original[1])
        #expect(reopened.filters.focus == true && reopened.search == "merge" && !reopened.groupByOutcome)
        #expect(reopened.sortOrder == [DeskSort.focus.comparator])
        reopened.sortOrder = sorts
        try reopened.saveVisualization(named: original[1].name, replacing: original[1].id)
        let updated = Desk(defaults: defaults, store: store).visualizations[1]
        #expect(updated.id == original[1].id && reopened.matches(updated))
        let legacy = Visualization(name: "Legacy", filters: TaskFilters(), search: "old")
        reopened.apply(legacy)
        #expect(reopened.search == "old" && reopened.sortOrder == sorts && !reopened.groupByOutcome)
    }

    @Test func oldPresetStillMatchesTasksAcrossOutcomes() throws {
        let data = Data("""
            [{"id":"A12BF316-348A-4EDB-A860-8671F9DDEFD2","name":"Urgent","search":"review",
            "filters":{"statuses":[],"priorities":["High"],"kinds":[],"groups":[],"people":[]}}]
            """.utf8)
        let preset = try #require(JSONDecoder().decode([Visualization].self, from: data).first)
        #expect(preset.search == "review" && preset.filters.count == 1)
        var task = WorkItem()
        task.priority = .high
        #expect(preset.filters.includes(task))
        task.outcomeID = 12
        #expect(preset.filters.includes(task))
        task.priority = .medium
        #expect(!preset.filters.includes(task))
    }
}
