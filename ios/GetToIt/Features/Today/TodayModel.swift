import Foundation
import Observation
import Supabase

@MainActor
@Observable
final class TodayModel {
    struct FocusItem: Identifiable {
        let goal: Goal
        let milestone: Milestone
        var id: UUID { milestone.id }
    }

    private(set) var categories: [Category] = []
    private(set) var goals: [Goal] = []
    private(set) var thought: Thought?
    private(set) var activeDays: Set<String> = []
    private(set) var isLoading = true
    var errorMessage: String?
    var toast: String?
    var celebrations: [String] = []

    /// Milestones picked for today when the screen loaded. Completed ones stay visible, checked.
    private var focusIDs: [UUID] = []
    private var badgeNames: [String: String] = [:]
    private let maxFocus = 3
    private let client = Backend.client

    private static let encouragement = [
        "Done. What's next?",
        "Nice work. On to the next one.",
        "Checked off. Keep the momentum.",
        "Good. Carry that into the next one.",
    ]

    // MARK: Derived

    var focus: [FocusItem] {
        focusIDs.compactMap { id in
            for goal in goals {
                if let milestone = goal.milestones.first(where: { $0.id == id }) {
                    return FocusItem(goal: goal, milestone: milestone)
                }
            }
            return nil
        }
    }

    var doneCount: Int { focus.filter { $0.milestone.isDone }.count }

    /// The last 7 days, oldest first, with whether each had progress.
    var week: [(label: String, active: Bool, isToday: Bool)] {
        (0..<7).reversed().map { offset in
            let date = Calendar.current.date(byAdding: .day, value: -offset, to: Date()) ?? Date()
            let label = String(Self.weekdayFormatter.string(from: date).prefix(1))
            return (label, activeDays.contains(Self.dayString(date)), offset == 0)
        }
    }

    var activeThisWeek: Int { week.filter(\.active).count }

    func category(for goal: Goal) -> Category? {
        categories.first { $0.id == goal.categoryId }
    }

    // MARK: Loading

    func load(userID: UUID) async {
        isLoading = goals.isEmpty
        errorMessage = nil
        do {
            async let categoryRows: [Category] = client.from("categories")
                .select("id,name,color,position,archived_at")
                .order("position")
                .execute().value
            async let goalRows: [Goal] = client.from("goals")
                .select("id,title,category_id,horizon,target_label,milestones(id,title,position,due_date,completed_at,broken_down_at)")
                .eq("status", value: "active")
                .order("created_at")
                .execute().value
            async let thoughtRows: [Thought] = client.from("thoughts")
                .select("id,body,subline")
                .eq("in_morning_rotation", value: true)
                .order("created_at")
                .execute().value
            async let dayRows: [ActivityDay] = client.from("activity_days")
                .select("day")
                .gte("day", value: Self.dayString(Calendar.current.date(byAdding: .day, value: -6, to: Date()) ?? Date()))
                .execute().value
            async let badgeRows: [BadgeInfo] = client.from("badge_catalog")
                .select("key,name")
                .execute().value

            let loadedCategories = try await categoryRows
            let loadedGoals = try await goalRows
            let thoughts = try await thoughtRows
            let days = try await dayRows
            let badges = try await badgeRows

            categories = loadedCategories.filter { $0.archivedAt == nil }
            goals = loadedGoals
            activeDays = Set(days.map(\.day))
            badgeNames = Dictionary(badges.map { ($0.key, $0.name) }, uniquingKeysWith: { first, _ in first })

            if !thoughts.isEmpty {
                let dayOfYear = Calendar.current.ordinality(of: .day, in: .year, for: Date()) ?? 0
                thought = thoughts[dayOfYear % thoughts.count]
            }
            pickFocus()
            await syncTimeZone(userID: userID)
        } catch {
            errorMessage = "Couldn't load your goals. Check your connection and pull to refresh."
        }
        isLoading = false
    }

    /// One step per goal: the next open milestone, soonest due date first, up to three open.
    /// Steps picked earlier today stay on the list, checked or not.
    private func pickFocus() {
        var picks = focusIDs.filter { goalID(containing: $0) != nil }
        let pickedGoals = Set(picks.compactMap { goalID(containing: $0) })
        var openSlots = maxFocus - picks.filter { !isDone($0) }.count

        let candidates = goals
            .filter { !pickedGoals.contains($0.id) }
            .compactMap { goal in goal.nextMilestone }
            .sorted { ($0.dueDate ?? "9999-12-31") < ($1.dueDate ?? "9999-12-31") }
        for milestone in candidates where openSlots > 0 {
            picks.append(milestone.id)
            openSlots -= 1
        }
        focusIDs = picks
    }

    private func goalID(containing milestoneID: UUID) -> UUID? {
        goals.first { $0.milestones.contains { $0.id == milestoneID } }?.id
    }

    private func isDone(_ id: UUID) -> Bool {
        goals.contains { $0.milestones.contains { $0.id == id && $0.isDone } }
    }

    /// "Today" on the server follows the profile's time zone, so keep it matched to the phone.
    private func syncTimeZone(userID: UUID) async {
        _ = try? await client.from("profiles")
            .update(["timezone": TimeZone.current.identifier])
            .eq("id", value: userID.uuidString)
            .execute()
    }

    // MARK: Actions

    func toggle(_ item: FocusItem) async {
        if item.milestone.isDone {
            await uncomplete(item)
        } else {
            await complete(item)
        }
    }

    private func complete(_ item: FocusItem) async {
        setCompleted(item.milestone.id, to: ISO8601DateFormatter().string(from: Date()))
        do {
            let earned: [EarnedBadge] = try await client
                .rpc("complete_milestone", params: MilestoneParams(pMilestone: item.milestone.id))
                .execute().value
            activeDays.insert(Self.dayString(Date()))
            let names = earned.compactMap(\.badgeKey).map { badgeNames[$0] ?? $0 }
            if names.isEmpty {
                toast = Self.encouragement.randomElement()
            } else {
                celebrations.append(contentsOf: names)
            }
        } catch {
            setCompleted(item.milestone.id, to: nil)
            toast = "That didn't save. Try again."
        }
    }

    private func uncomplete(_ item: FocusItem) async {
        let previous = item.milestone.completedAt
        setCompleted(item.milestone.id, to: nil)
        do {
            try await client
                .rpc("uncomplete_milestone", params: MilestoneParams(pMilestone: item.milestone.id))
                .execute()
        } catch {
            setCompleted(item.milestone.id, to: previous)
            toast = "That didn't save. Try again."
        }
    }

    private func setCompleted(_ id: UUID, to value: String?) {
        for g in goals.indices {
            if let m = goals[g].milestones.firstIndex(where: { $0.id == id }) {
                goals[g].milestones[m].completedAt = value
            }
        }
    }

    func addGoal(title: String, category: Category, horizon: String, target: String, steps: [String], userID: UUID) async -> Bool {
        do {
            let inserted: InsertedID = try await client.from("goals")
                .insert(NewGoal(title: title, categoryId: category.id, horizon: horizon,
                                targetLabel: target.isEmpty ? nil : target))
                .select("id")
                .single()
                .execute().value
            let titles = steps.isEmpty ? ["Pick the first small step"] : steps
            let rows = titles.enumerated().map { NewMilestone(goalId: inserted.id, title: $1, position: $0 + 1) }
            try await client.from("milestones").insert(rows).execute()
            await load(userID: userID)
            toast = "Goal added. Knock out the first milestone this week."
            return true
        } catch {
            errorMessage = "Couldn't save that goal. Try again."
            return false
        }
    }

    // MARK: Dates

    static func dayString(_ date: Date) -> String {
        dayFormatter.string(from: date)
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let weekdayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEEE"
        return f
    }()
}
