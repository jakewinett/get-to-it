import Foundation

// Rows as the app reads them. Dates stay as the strings Postgres sends
// ("2026-11-24" for date, ISO 8601 for timestamptz) until a screen needs more.

struct Category: Decodable, Identifiable, Hashable {
    let id: UUID
    let name: String
    let color: String
    let position: Int
    let archivedAt: String?

    enum CodingKeys: String, CodingKey {
        case id, name, color, position
        case archivedAt = "archived_at"
    }
}

struct Milestone: Decodable, Identifiable, Hashable {
    let id: UUID
    let title: String
    let position: Int
    let dueDate: String?
    var completedAt: String?
    let brokenDownAt: String?

    var isDone: Bool { completedAt != nil }

    enum CodingKeys: String, CodingKey {
        case id, title, position
        case dueDate = "due_date"
        case completedAt = "completed_at"
        case brokenDownAt = "broken_down_at"
    }
}

struct Goal: Decodable, Identifiable, Hashable {
    let id: UUID
    let title: String
    let categoryId: UUID
    let horizon: String
    let targetLabel: String?
    var milestones: [Milestone]

    /// Milestones still in the list (a broken-down step is replaced by its smaller steps).
    var activeMilestones: [Milestone] {
        milestones.filter { $0.brokenDownAt == nil }.sorted { $0.position < $1.position }
    }

    var nextMilestone: Milestone? { activeMilestones.first { !$0.isDone } }

    enum CodingKeys: String, CodingKey {
        case id, title, horizon, milestones
        case categoryId = "category_id"
        case targetLabel = "target_label"
    }
}

struct Thought: Decodable, Identifiable {
    let id: UUID
    let body: String
    let subline: String?
}

struct BadgeInfo: Decodable, Identifiable {
    let key: String
    let name: String
    var id: String { key }
}

/// One row returned by complete_milestone / add_note.
struct EarnedBadge: Decodable {
    let badgeKey: String?
    enum CodingKeys: String, CodingKey { case badgeKey = "badge_key" }
}

struct ActivityDay: Decodable {
    let day: String
}

// MARK: - Writes

struct NewGoal: Encodable {
    let title: String
    let categoryId: UUID
    let horizon: String
    let targetLabel: String?
    let source = "ios"

    enum CodingKeys: String, CodingKey {
        case title, horizon, source
        case categoryId = "category_id"
        case targetLabel = "target_label"
    }
}

struct NewMilestone: Encodable {
    let goalId: UUID
    let title: String
    let position: Int

    enum CodingKeys: String, CodingKey {
        case title, position
        case goalId = "goal_id"
    }
}

struct MilestoneParams: Encodable {
    let pMilestone: UUID
    enum CodingKeys: String, CodingKey { case pMilestone = "p_milestone" }
}

struct InsertedID: Decodable {
    let id: UUID
}
