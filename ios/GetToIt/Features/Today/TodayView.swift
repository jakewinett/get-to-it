import SwiftUI

struct TodayView: View {
    @Environment(AuthModel.self) private var auth
    @State private var model = TodayModel()
    @State private var showingAddGoal = false

    private var userID: UUID? {
        if case let .signedIn(id) = auth.state { return id }
        return nil
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    if let thought = model.thought {
                        thoughtCard(thought)
                    }
                    if model.isLoading {
                        ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                    } else if model.goals.isEmpty {
                        emptyState
                    } else {
                        focusSection
                        weekSection
                    }
                    if let message = model.errorMessage {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(Theme.muted)
                            .padding(.top, 16)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 32)
            }
            .background(Theme.surface)
            .refreshable { await reload() }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Add a goal", systemImage: "plus") { showingAddGoal = true }
                        Button("Sign out", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                            Task { await auth.signOut() }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .sheet(isPresented: $showingAddGoal) {
                AddGoalSheet(categories: model.categories) { title, category, horizon, target, steps in
                    guard let userID else { return false }
                    return await model.addGoal(title: title, category: category, horizon: horizon,
                                               target: target, steps: steps, userID: userID)
                }
            }
            .overlay(alignment: .bottom) { toastView }
            .overlay { celebrationView }
            .task { await reload() }
        }
    }

    private func reload() async {
        guard let userID else { return }
        await model.load(userID: userID)
    }

    // MARK: Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(Date.now.formatted(.dateTime.weekday(.wide).month(.wide).day()).uppercased())
                .font(.caption.weight(.semibold))
                .tracking(0.8)
                .foregroundStyle(Theme.muted)
            Text(greeting)
                .font(.largeTitle.bold())
                .foregroundStyle(Theme.ink)
        }
        .padding(.top, 4)
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: .now) {
        case ..<12: return "Good morning"
        case ..<17: return "Good afternoon"
        default: return "Good evening"
        }
    }

    private func thoughtCard(_ thought: Thought) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("TODAY'S THOUGHT")
                .font(.caption.weight(.semibold))
                .tracking(0.8)
                .foregroundStyle(Theme.accent)
            Text(thought.body)
                .font(Theme.thoughtFont)
                .foregroundStyle(Theme.ink)
            if let subline = thought.subline {
                Text(subline)
                    .font(.subheadline)
                    .foregroundStyle(Theme.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.top, 18)
    }

    private var focusSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionTitle("TODAY'S FOCUS · \(model.doneCount) OF \(model.focus.count)")
            VStack(alignment: .leading, spacing: 14) {
                ForEach(model.focus) { item in
                    focusRow(item)
                }
            }
            .padding(16)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))

            HStack {
                Text(model.doneCount == model.focus.count && !model.focus.isEmpty
                     ? "All done. Got energy left? Add a goal."
                     : "Ordered by what's due first.")
                    .font(.footnote)
                    .foregroundStyle(Theme.muted)
                Spacer()
                Button("+ Add a goal") { showingAddGoal = true }
                    .font(.subheadline.weight(.semibold))
            }
            .padding(.top, 8)
            .padding(.horizontal, 2)
        }
    }

    private func focusRow(_ item: FocusRow) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Button {
                Task { await model.toggle(item) }
            } label: {
                ZStack {
                    Circle()
                        .strokeBorder(item.isDone ? Theme.accent : Theme.line, lineWidth: 2)
                        .background(Circle().fill(item.isDone ? Theme.accent : Theme.card))
                    if item.isDone {
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .heavy))
                            .foregroundStyle(Theme.accentInk)
                    }
                }
                .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item.isDone ? "Mark not done: \(item.milestoneTitle)" : "Mark done: \(item.milestoneTitle)")
            .sensoryFeedback(.success, trigger: item.isDone) { _, done in done }

            VStack(alignment: .leading, spacing: 3) {
                Text(item.milestoneTitle)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(item.isDone ? Theme.muted : Theme.ink)
                    .strikethrough(item.isDone, color: Theme.line)
                HStack(spacing: 6) {
                    Circle()
                        .fill(Theme.category(item.categoryColor))
                        .frame(width: 8, height: 8)
                    Text(item.goalTitle)
                        .font(.footnote)
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                }
            }
        }
    }

    private var weekSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionTitle("THIS WEEK")
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("\(model.activeThisWeek) of the last 7 days")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Theme.ink)
                    Spacer()
                    Text(weekMessage)
                        .font(.footnote)
                        .foregroundStyle(Theme.muted)
                }
                HStack {
                    ForEach(Array(model.week.enumerated()), id: \.offset) { _, day in
                        VStack(spacing: 6) {
                            Circle()
                                .fill(day.active ? Theme.accent : Color.clear)
                                .overlay(
                                    Circle().strokeBorder(
                                        day.isToday ? Theme.accent : Theme.line,
                                        style: StrokeStyle(lineWidth: 2, dash: day.active || day.isToday ? [] : [3, 3])
                                    )
                                )
                                .frame(width: 30, height: 30)
                            Text(day.label)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Theme.muted)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                Text("Missed days don't reset anything. Today counts the moment you check something off.")
                    .font(.footnote)
                    .foregroundStyle(Theme.muted)
            }
            .padding(16)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    private var weekMessage: String {
        let active = model.activeThisWeek
        if active >= 5 { return "Strong week. Keep it going." }
        if active >= 3 { return "\(5 - active) more day\(5 - active == 1 ? "" : "s") to earn Steady." }
        return "Check one thing off to make today count."
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Text("No goals yet.")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Theme.ink)
            Text("Add one, and its first step lands here.")
                .foregroundStyle(Theme.muted)
            Button("Add your first goal") { showingAddGoal = true }
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.top, 28)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.bold))
            .tracking(0.8)
            .foregroundStyle(Theme.muted)
            .padding(.top, 28)
            .padding(.bottom, 10)
    }

    // MARK: Feedback

    @ViewBuilder private var toastView: some View {
        if let toast = model.toast {
            Text(toast)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.surface)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Theme.ink, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(.bottom, 24)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task(id: toast) {
                    try? await Task.sleep(for: .seconds(2.6))
                    withAnimation { model.toast = nil }
                }
        }
    }

    @ViewBuilder private var celebrationView: some View {
        if let badge = model.celebrations.first {
            ZStack {
                Color.black.opacity(0.35).ignoresSafeArea()
                VStack(spacing: 10) {
                    Image(systemName: "rosette")
                        .font(.system(size: 56))
                        .foregroundStyle(Theme.gold)
                        .frame(width: 112, height: 112)
                        .background(Theme.goldSoft, in: Circle())
                        .overlay(Circle().strokeBorder(Theme.gold, lineWidth: 3))
                    Text("BADGE EARNED")
                        .font(.caption.weight(.bold))
                        .tracking(0.8)
                        .foregroundStyle(Theme.gold)
                    Text(badge)
                        .font(.title2.bold())
                        .foregroundStyle(Theme.ink)
                    Button(model.celebrations.count > 1 ? "Next" : "Keep going") {
                        withAnimation { _ = model.celebrations.removeFirst() }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .padding(.top, 8)
                }
                .padding(28)
                .frame(maxWidth: 320)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            }
            .transition(.opacity)
        }
    }
}
