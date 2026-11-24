import Foundation
import Testing
import TaskCore
@testable import TaskDesk

struct FilterTests {
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
