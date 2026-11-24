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
    public var citation: String
    public var contributionCount: Int?
    public let receivedAt: String
    public var base: WorkItem
    public var draft: WorkItem
    public var appliedTaskID: Int?
    public var isNew: Bool { base.id == 0 }

    private func fields(_ task: WorkItem) throws -> [String: NSObject] {
        guard let result = try JSONSerialization.jsonObject(with: JSONEncoder().encode(task)) as? [String: NSObject] else {
            throw DeskError("Could not read task fields.")
        }
        return result
    }

    // Rebuild an edit on current data. Overlapping edits start with Luke's live value.
    public func editableDraft(on current: WorkItem) throws -> WorkItem {
        let original = try fields(base), suggested = try fields(draft)
        var result = try fields(current)
        for key in Set(original.keys).union(suggested.keys) where suggested[key] != original[key] && original[key] == result[key] {
            result[key] = suggested[key]
        }
        var rebased = try JSONDecoder().decode(WorkItem.self, from: JSONSerialization.data(withJSONObject: result))
        rebased.actions = mergedActions(base: base.actions, previous: draft.actions, next: current.actions)
        rebased.collaborators = mergeList(base: base.collaborators, previous: draft.collaborators,
                                          next: current.collaborators, key: { $0.lowercased() }) { _, _, live in live }
        return rebased
    }

    mutating func combine(_ incoming: Proposal, explicitFields: Set<String> = []) throws {
        // Normal submissions use the live version. Legacy drafts can have different bases.
        let current = incoming.base.version >= base.version ? incoming.base : base
        let previous = base.version == current.version ? draft : try editableDraft(on: current)
        let next = incoming.base.version == current.version ? incoming.draft : try incoming.editableDraft(on: current)
        let original = try fields(current), suggested = try fields(next)
        var result = try fields(previous)
        for key in Set(original.keys).union(suggested.keys).union(explicitFields)
            where original[key] != suggested[key] || explicitFields.contains(key) {
            result[key] = suggested[key]
        }
        var combined = try JSONDecoder().decode(WorkItem.self, from: JSONSerialization.data(withJSONObject: result))

        combined.actions = mergedActions(base: current.actions, previous: previous.actions, next: next.actions)
        combined.collaborators = mergeList(base: current.collaborators, previous: previous.collaborators,
                                           next: next.collaborators, key: { $0.lowercased() }) { _, _, incoming in incoming }

        if explicitFields.contains("actions") && next.actions.isEmpty { combined.actions = [] }
        if explicitFields.contains("collaborators") && next.collaborators.isEmpty { combined.collaborators = [] }

        // Workers append notes to the live context. Keep independent additions from both submissions.
        if next.context != current.context && next.context.hasPrefix(current.context)
            && previous.context != current.context && !next.context.hasPrefix(previous.context) {
            let addition = next.context.dropFirst(current.context.count).trimmingCharacters(in: .whitespacesAndNewlines)
            if !addition.isEmpty {
                combined.context = previous.context
                if !previous.context.contains(addition) {
                    combined.context = [previous.context, addition].filter { !$0.isEmpty }.joined(separator: "\n\n")
                }
            }
        }
        var lines = Set(citation.components(separatedBy: "\n"))
        for line in incoming.citation.components(separatedBy: "\n") where !line.isEmpty && lines.insert(line).inserted {
            citation += "\n" + line
        }
        contributionCount = (contributionCount ?? 1) + (incoming.contributionCount ?? 1)
        base = current
        draft = combined
        state = .pending
    }

}

private func mergedActions(base: [ActionItem], previous: [ActionItem], next: [ActionItem]) -> [ActionItem] {
    mergeList(base: base, previous: previous, next: next, key: { $0.id }) { original, pending, incoming in
        var action = pending
        if original.title != incoming.title { action.title = incoming.title }
        if original.assignee != incoming.assignee { action.assignee = incoming.assignee }
        if original.completed != incoming.completed { action.completed = incoming.completed }
        return action
    }
}

// Apply membership and item edits relative to the live collection. Omission of an
// independent pending addition in another live-based patch does not remove it.
private func mergeList<Element: Equatable, ID: Hashable>(
    base: [Element], previous: [Element], next: [Element], key: (Element) -> ID,
    combine: (Element, Element, Element) -> Element
) -> [Element] {
    if next == base { return previous }
    if previous == base { return next }
    let original = Dictionary(base.map { (key($0), $0) }, uniquingKeysWith: { first, _ in first })
    let nextIDs = Set(next.map(key))
    var merged = previous.filter { original[key($0)] == nil || nextIDs.contains(key($0)) }
    for value in next {
        let id = key(value)
        if let old = original[id], old == value { continue }
        if let index = merged.firstIndex(where: { key($0) == id }) {
            merged[index] = original[id].map { combine($0, merged[index], value) } ?? value
        } else { merged.append(value) }
    }
    let sharedOrder = next.map(key).filter { original[$0] != nil }
    if sharedOrder != base.map(key).filter(nextIDs.contains) {
        let values = Dictionary(merged.map { (key($0), $0) }, uniquingKeysWith: { first, _ in first })
        return next.compactMap { values[key($0)] } + merged.filter { !nextIDs.contains(key($0)) }
    }
    return merged
}

public struct ProposalReceipt: Codable {
    public let inboxID: Int?
    public let existingTaskID: Int?
    public let inserted: Bool
    public var updated: Bool?
}
