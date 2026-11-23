import Foundation

public enum ReviewState: String, Codable, CaseIterable {
    case pending = "Pending", approved = "Approved", rejected = "Rejected", applied = "Applied"
}

public struct Proposal: Codable, Identifiable {
    public var id: Int
    public var revision: Int
    public var state: ReviewState
    public let source: String
    public let evidence: String
    public let citation: String
    public let receivedAt: String
    public var base: WorkItem
    public var draft: WorkItem
    public var appliedTaskID: Int?
    public var isNew: Bool { base.id == 0 }

    // Rebuild an edit on current data. Overlapping edits start with Luke's live value.
    public func editableDraft(on current: WorkItem) throws -> WorkItem {
        let encoder = JSONEncoder()
        func fields(_ task: WorkItem) throws -> [String: NSObject] {
            guard let result = try JSONSerialization.jsonObject(with: encoder.encode(task)) as? [String: NSObject] else {
                throw DeskError("Could not read task fields.")
            }
            return result
        }
        let original = try fields(base), suggested = try fields(draft)
        var result = try fields(current)
        for (key, value) in suggested where value != original[key] && original[key] == result[key] {
            result[key] = value
        }
        return try JSONDecoder().decode(WorkItem.self, from: JSONSerialization.data(withJSONObject: result))
    }
}

public struct ProposalReceipt: Codable {
    public let inboxID: Int?
    public let existingTaskID: Int?
    public let inserted: Bool
}
