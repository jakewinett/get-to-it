import SwiftUI

struct AddGoalSheet: View {
    let categories: [Category]
    let onSave: (_ title: String, _ category: Category, _ horizon: String, _ target: String, _ targetDate: Date?, _ steps: [String]) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var categoryID: UUID?
    @State private var horizon = "short"
    @State private var target = ""
    /// Set only by the date picker. Typing over the picked date turns the target back into free text.
    @State private var targetDate: Date?
    @State private var showingDatePicker = false
    @State private var steps = ["", "", ""]
    @State private var isSaving = false

    private var selectedCategory: Category? {
        categories.first { $0.id == categoryID } ?? categories.first
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("What do you want to achieve?") {
                    TextField("e.g. Run a 10K", text: $title)
                }
                Section("Category") {
                    Picker("Category", selection: Binding(
                        get: { selectedCategory?.id },
                        set: { categoryID = $0 }
                    )) {
                        ForEach(categories) { category in
                            Text(category.name).tag(Optional(category.id))
                        }
                    }
                    .pickerStyle(.segmented)
                }
                Section {
                    Picker("Time frame", selection: $horizon) {
                        Text("Short").tag("short")
                        Text("Mid").tag("mid")
                        Text("Long").tag("long")
                    }
                    .pickerStyle(.segmented)
                    HStack {
                        TextField("Target date (optional), e.g. April 2027", text: $target)
                            .onChange(of: target) { _, newValue in
                                if let date = targetDate, newValue != Self.label(for: date) { targetDate = nil }
                            }
                        Button {
                            withAnimation { showingDatePicker.toggle() }
                        } label: {
                            Image(systemName: showingDatePicker ? "calendar.circle.fill" : "calendar")
                                .font(.title3)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(showingDatePicker ? "Hide the calendar" : "Pick a target date")
                    }
                    if showingDatePicker {
                        DatePicker("Target date", selection: pickedDate, in: Calendar.current.startOfDay(for: .now)...,
                                   displayedComponents: .date)
                            .datePickerStyle(.graphical)
                    }
                } header: {
                    Text("Time frame")
                } footer: {
                    Text(horizonHelp)
                }
                Section {
                    ForEach(steps.indices, id: \.self) { index in
                        TextField("Milestone \(index + 1)", text: $steps[index])
                    }
                } header: {
                    Text("First milestones")
                } footer: {
                    Text("Make the first milestone something you can finish this week.")
                }
            }
            .navigationTitle("New goal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(trimmedTitle.isEmpty || selectedCategory == nil || isSaving)
                }
            }
        }
    }

    /// The picker writes the date and its label into the text field, then folds away.
    private var pickedDate: Binding<Date> {
        Binding(
            get: { targetDate ?? Calendar.current.date(byAdding: .month, value: 1, to: .now) ?? .now },
            set: { date in
                targetDate = date
                target = Self.label(for: date)
                withAnimation { showingDatePicker = false }
            }
        )
    }

    static func label(for date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day().year())
    }

    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var horizonHelp: String {
        switch horizon {
        case "mid": return "3 to 12 months"
        case "long": return "A year or more"
        default: return "Next 3 months"
        }
    }

    private func save() async {
        guard let category = selectedCategory else { return }
        isSaving = true
        let cleanSteps = steps.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let saved = await onSave(trimmedTitle, category, horizon,
                                 target.trimmingCharacters(in: .whitespacesAndNewlines), targetDate, cleanSteps)
        isSaving = false
        if saved { dismiss() }
    }
}
