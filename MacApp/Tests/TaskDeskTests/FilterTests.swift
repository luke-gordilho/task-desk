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

    @Test func multipleOutcomesAndUnassignedSurviveSaving() throws {
        var filters = TaskFilters()
        filters.priorities = [.high]
        filters.outcomeIDs = [7, 8, nil]
        let preset = SavedFilter(name: "Launch", filters: filters, search: "")
        let data = try JSONEncoder().encode(preset)
        let restored = try JSONDecoder().decode(SavedFilter.self, from: data).filters
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

    @Test func oldPresetStillMatchesTasksAcrossOutcomes() throws {
        let data = Data("""
            [{"id":"A12BF316-348A-4EDB-A860-8671F9DDEFD2","name":"Urgent","search":"review",
            "filters":{"statuses":[],"priorities":["High"],"kinds":[],"groups":[],"people":[]}}]
            """.utf8)
        let preset = try #require(JSONDecoder().decode([SavedFilter].self, from: data).first)
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
