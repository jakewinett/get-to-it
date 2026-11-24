import Foundation
import Observation
import Supabase

@MainActor
@Observable
final class TodayModel {
    private(set) var categories: [Category] = []
    private(set) var goals: [Goal] = []
    /// Today's steps, picked by the todays_focus() database function.
    private(set) var focus: [FocusRow] = []
    private(set) var thought: Thought?
    private(set) var activeDays: Set<String> = []
    private(set) var isLoading = true
    var errorMessage: String?
    var toast: String?
    var celebrations: [String] = []

    private var badgeNames: [String: String] = [:]
    private let client = Backend.client

    private static let encouragement = [
        "Done. What's next?",
        "Nice work. On to the next one.",
        "Checked off. Keep the momentum.",
        "Good. Carry that into the next one.",
    ]

    // MARK: Derived

    var doneCount: Int { focus.filter(\.isDone).count }

    /// The last 7 days, oldest first, with whether each had progress.
    var week: [(label: String, active: Bool, isToday: Bool)] {
        (0..<7).reversed().map { offset in
            let date = Calendar.current.date(byAdding: .day, value: -offset, to: Date()) ?? Date()
            let label = String(Self.weekdayFormatter.string(from: date).prefix(1))
            return (label, activeDays.contains(Self.dayString(date)), offset == 0)
        }
    }

    var activeThisWeek: Int { week.filter(\.active).count }

    // MARK: Loading

    func load(userID: UUID) async {
        isLoading = goals.isEmpty
        errorMessage = nil
        // todays_focus() works out "today" from the profile's time zone, so sync it first.
        await syncTimeZone(userID: userID)
        do {
            async let focusRows: [FocusRow] = client.rpc("todays_focus").execute().value
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
            let loadedFocus = try await focusRows

            categories = loadedCategories.filter { $0.archivedAt == nil }
            goals = loadedGoals
            focus = loadedFocus
            activeDays = Set(days.map(\.day))
            badgeNames = Dictionary(badges.map { ($0.key, $0.name) }, uniquingKeysWith: { first, _ in first })

            if !thoughts.isEmpty {
                let dayOfYear = Calendar.current.ordinality(of: .day, in: .year, for: Date()) ?? 0
                thought = thoughts[dayOfYear % thoughts.count]
            }
        } catch {
            errorMessage = "Couldn't load your goals. Check your connection and pull to refresh."
        }
        isLoading = false
    }

    /// "Today" on the server follows the profile's time zone, so keep it matched to the phone.
    private func syncTimeZone(userID: UUID) async {
        _ = try? await client.from("profiles")
            .update(["timezone": TimeZone.current.identifier])
            .eq("id", value: userID.uuidString)
            .execute()
    }

    // MARK: Actions

    func toggle(_ item: FocusRow) async {
        if item.isDone {
            await uncomplete(item)
        } else {
            await complete(item)
        }
    }

    private func complete(_ item: FocusRow) async {
        setCompleted(item.milestoneId, to: ISO8601DateFormatter().string(from: Date()))
        do {
            let earned: [EarnedBadge] = try await client
                .rpc("complete_milestone", params: MilestoneParams(pMilestone: item.milestoneId))
                .execute().value
            activeDays.insert(Self.dayString(Date()))
            let names = earned.compactMap(\.badgeKey).map { badgeNames[$0] ?? $0 }
            if names.isEmpty {
                toast = Self.encouragement.randomElement()
            } else {
                celebrations.append(contentsOf: names)
            }
        } catch {
            setCompleted(item.milestoneId, to: nil)
            toast = "That didn't save. Try again."
        }
    }

    private func uncomplete(_ item: FocusRow) async {
        let previous = item.completedAt
        setCompleted(item.milestoneId, to: nil)
        do {
            try await client
                .rpc("uncomplete_milestone", params: MilestoneParams(pMilestone: item.milestoneId))
                .execute()
        } catch {
            setCompleted(item.milestoneId, to: previous)
            toast = "That didn't save. Try again."
        }
    }

    private func setCompleted(_ id: UUID, to value: String?) {
        if let f = focus.firstIndex(where: { $0.milestoneId == id }) {
            focus[f].completedAt = value
        }
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
