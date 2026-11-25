import SwiftUI
import UserNotifications

/// The daily reminder: one local notification a day at the chosen time, showing that day's thought
/// and the step to work on.
///
/// Local notifications are fixed when they're scheduled, so the app schedules the next 14 days
/// every time Today loads or a step changes. If the app isn't opened for a while, the later
/// reminders still arrive, with the step as it was when the app last ran.
/// (A server-sent push digest, planned later, would always be current.)
@MainActor
enum DailyReminder {
    nonisolated static let enabledKey = "dailyReminderEnabled"
    nonisolated static let minutesKey = "dailyReminderMinutes"
    nonisolated static let defaultMinutes = 7 * 60 + 30
    private static let idPrefix = "daily-reminder-"
    private static let daysAhead = 14

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    static var minutes: Int {
        UserDefaults.standard.object(forKey: minutesKey) as? Int ?? defaultMinutes
    }

    /// What one day's reminder says.
    struct Content: Equatable {
        var title: String
        var subtitle: String
        var body: String
    }

    // MARK: Scheduling

    /// Replaces any scheduled reminders with the next 14 days'. Does nothing visible when the
    /// reminder is off, apart from clearing old ones.
    static func reschedule(thoughts: [Thought], goals: [Goal], focus: [FocusRow]) async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier).filter { $0.hasPrefix(idPrefix) })

        guard isEnabled else { return }
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }

        let calendar = Calendar.current
        let now = Date()
        for offset in 0..<daysAhead {
            guard let day = calendar.date(byAdding: .day, value: offset, to: now),
                  let fireDate = calendar.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: day),
                  fireDate > now
            else { continue }

            let content = Self.content(for: day, thoughts: thoughts, goals: goals, focus: offset == 0 ? focus : [])
            let notification = UNMutableNotificationContent()
            notification.title = content.title
            notification.subtitle = content.subtitle
            notification.body = content.body
            notification.sound = .default

            let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate)
            let request = UNNotificationRequest(
                identifier: idPrefix + TodayModel.dayString(day),
                content: notification,
                trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
            )
            try? await center.add(request)
        }
    }

    /// Asks for permission the first time. Returns whether notifications are allowed.
    static func requestPermission() async -> Bool {
        let center = UNUserNotificationCenter.current()
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: return true
        case .denied: return false
        default: return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        }
    }

    // MARK: Content

    static func content(for day: Date, thoughts: [Thought], goals: [Goal], focus: [FocusRow]) -> Content {
        let thought = TodayModel.thought(for: day, in: thoughts)
        let body = thought.map { "\u{201C}\($0.body)\u{201D}" } ?? "Open Today and pick one thing to finish."

        guard let step = step(for: day, goals: goals, focus: focus) else {
            return Content(title: "Let's get to it", subtitle: "Add a goal, and its first step shows up here.", body: body)
        }
        var subtitle = step.goal
        if let due = step.due {
            let dueDay = Calendar.current.startOfDay(for: due)
            let today = Calendar.current.startOfDay(for: day)
            let when = due.formatted(.dateTime.month(.abbreviated).day())
            subtitle += dueDay == today ? " · due today" : dueDay < today ? " · was due \(when)" : " · due \(when)"
        }
        return Content(title: "Your next big move: \(step.title)", subtitle: subtitle, body: body)
    }

    /// The step a day's reminder points at: today's first unfinished focus step if there is one;
    /// otherwise the open milestone most recently due on or before that day, then the next one
    /// coming due, then the first open milestone of the oldest goal.
    static func step(for day: Date, goals: [Goal], focus: [FocusRow]) -> (title: String, goal: String, due: Date?)? {
        if let item = focus.first(where: { !$0.isDone }) {
            return (item.milestoneTitle, item.goalTitle, item.dueDate.flatMap(parseDay))
        }

        let endOfDay = Calendar.current.startOfDay(for: day).addingTimeInterval(86_399)
        let open = goals.flatMap { goal in
            goal.activeMilestones.filter { !$0.isDone }.map { (milestone: $0, goal: goal, due: $0.dueDate.flatMap(parseDay)) }
        }
        let dated = open.filter { $0.due != nil }
        let pick = dated.filter { $0.due! <= endOfDay }.max { $0.due! < $1.due! }
            ?? dated.filter { $0.due! > endOfDay }.min { $0.due! < $1.due! }
            ?? goals.lazy.compactMap { goal in goal.nextMilestone.map { (milestone: $0, goal: goal, due: Date?.none) } }.first
        return pick.map { ($0.milestone.title, $0.goal.title, $0.due) }
    }

    private static func parseDay(_ string: String) -> Date? {
        dayParser.date(from: String(string.prefix(10)))
    }

    private static let dayParser: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}

// MARK: - Settings sheet

struct ReminderSettingsView: View {
    /// Tomorrow's reminder, so the setting shows what will arrive.
    let preview: DailyReminder.Content
    let onChange: (_ minutes: Int) async -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @AppStorage(DailyReminder.enabledKey) private var isEnabled = false
    @AppStorage(DailyReminder.minutesKey) private var minutes = DailyReminder.defaultMinutes
    @State private var isBlocked = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Daily reminder", isOn: $isEnabled)
                    if isEnabled {
                        DatePicker("Time", selection: time, displayedComponents: .hourAndMinute)
                    }
                } footer: {
                    Text("One notification a day with the day's thought and your next step.")
                }

                if isBlocked {
                    Section {
                        Text("Notifications are off for Get To It.")
                        Button("Turn them on in Settings") {
                            if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
                        }
                    }
                }

                if isEnabled && !isBlocked {
                    Section("Tomorrow's reminder") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(preview.title).font(.subheadline.weight(.semibold))
                            Text(preview.subtitle).font(.footnote).foregroundStyle(Theme.muted)
                            Text(preview.body).font(.footnote).foregroundStyle(Theme.ink)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .navigationTitle("Reminder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onChange(of: isEnabled) { _, on in
                Task {
                    if on { isBlocked = !(await DailyReminder.requestPermission()) }
                    await onChange(minutes)
                }
            }
            .onChange(of: minutes) { _, newValue in
                Task { await onChange(newValue) }
            }
            .task {
                if isEnabled { isBlocked = !(await DailyReminder.requestPermission()) }
            }
        }
    }

    private var time: Binding<Date> {
        Binding(
            get: { Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: .now) ?? .now },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                minutes = (parts.hour ?? 7) * 60 + (parts.minute ?? 30)
            }
        )
    }
}
