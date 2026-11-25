import Observation
import Supabase
import SwiftUI

/// One conversation with the assistant (the `assistant` Edge Function, which calls Claude).
@MainActor
@Observable
final class AssistantModel {
    struct Message: Identifiable, Equatable {
        enum Role: String { case user, assistant }
        let id = UUID()
        let role: Role
        let text: String
    }

    private(set) var messages: [Message] = []
    private(set) var isSending = false
    /// Whether anything was added or changed, so Today reloads afterwards.
    private(set) var changedData = false
    private(set) var badges: [String] = []

    private struct Request: Encodable {
        let input: String
        let inputMode: String
        let history: [Turn]
        let today: String
        let timezone: String

        struct Turn: Encodable { let role: String; let content: String }

        enum CodingKeys: String, CodingKey {
            case input, history, today, timezone
            case inputMode = "input_mode"
        }
    }

    private struct Reply: Decodable {
        let reply: String
        let changed: Bool
        let badges: [String]
    }

    func send(_ text: String, byVoice: Bool) async {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, !isSending else { return }
        let history = messages.suffix(12).map { Request.Turn(role: $0.role.rawValue, content: $0.text) }
        messages.append(Message(role: .user, text: input))
        isSending = true
        defer { isSending = false }

        do {
            let reply: Reply = try await Backend.client.functions.invoke(
                "assistant",
                options: FunctionInvokeOptions(body: Request(
                    input: input,
                    inputMode: byVoice ? "voice" : "text",
                    history: Array(history),
                    today: TodayModel.dayString(Date()),
                    timezone: TimeZone.current.identifier
                ))
            )
            messages.append(Message(role: .assistant, text: reply.reply))
            if reply.changed { changedData = true }
            badges.append(contentsOf: reply.badges)
        } catch {
            messages.append(Message(role: .assistant, text: "That didn't go through. Check your connection and try again."))
        }
    }
}

struct AssistantView: View {
    /// Start listening as soon as the screen opens (it was opened with the mic button).
    var listenOnOpen = true
    /// Called when the screen closes: whether goals changed, and any badges earned.
    let onClose: (_ changed: Bool, _ badges: [String]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var model = AssistantModel()
    @State private var speech = SpeechInput()
    @State private var draft = ""
    @FocusState private var isTyping: Bool

    private let suggestions = [
        "Add a goal: run a 10K by April",
        "I finished the first milestone",
        "Move my target date to next month",
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                conversation
                composer
            }
            .background(Theme.surface)
            .navigationTitle("Ask")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task {
            speech.onFinished = { words in Task { await model.send(words, byVoice: true) } }
            if listenOnOpen { await speech.start() }
        }
        .onDisappear {
            speech.stop()
            onClose(model.changedData, model.badges)
        }
    }

    // MARK: Conversation

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if model.messages.isEmpty && !speech.isListening {
                        emptyState
                    }
                    ForEach(model.messages) { message in
                        bubble(message).id(message.id)
                    }
                    if model.isSending {
                        ProgressView()
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .id("sending")
                    }
                    if speech.isListening {
                        Text(speech.transcript.isEmpty ? "Listening…" : speech.transcript)
                            .foregroundStyle(speech.transcript.isEmpty ? Theme.muted : Theme.ink)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .id("listening")
                    }
                }
                .padding(20)
            }
            .onChange(of: model.messages.count) {
                withAnimation { proxy.scrollTo(model.messages.last?.id, anchor: .bottom) }
            }
            .onChange(of: speech.transcript) {
                proxy.scrollTo("listening", anchor: .bottom)
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Add a goal, change one, or say what you got done.")
                .font(.body.weight(.semibold))
                .foregroundStyle(Theme.ink)
            ForEach(suggestions, id: \.self) { suggestion in
                Button(suggestion) { Task { await model.send(suggestion, byVoice: false) } }
                    .font(.subheadline)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Theme.accentSoft, in: Capsule())
            }
        }
    }

    private func bubble(_ message: AssistantModel.Message) -> some View {
        let isUser = message.role == .user
        return Text(message.text)
            .foregroundStyle(isUser ? Theme.accentInk : Theme.ink)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(isUser ? Theme.accent : Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
            .padding(isUser ? .leading : .trailing, 40)
            .textSelection(.enabled)
    }

    // MARK: Composer

    private var composer: some View {
        VStack(spacing: 6) {
            if let problem = speech.problem {
                Text(problem)
                    .font(.footnote)
                    .foregroundStyle(Theme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if speech.isListening {
                Text("Pause when you're done, or tap the mic.")
                    .font(.footnote)
                    .foregroundStyle(Theme.muted)
            }
            HStack(alignment: .bottom, spacing: 10) {
                TextField("Type or tap the mic", text: $draft, axis: .vertical)
                    .lineLimit(1...4)
                    .focused($isTyping)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Theme.line))
                    .onSubmit(sendDraft)
                    .onChange(of: isTyping) { _, typing in if typing { speech.stop() } }

                if draft.trimmingCharacters(in: .whitespaces).isEmpty {
                    MicButton(isListening: speech.isListening) {
                        if speech.isListening {
                            speech.finish()
                        } else {
                            isTyping = false
                            Task { await speech.start() }
                        }
                    }
                    .disabled(model.isSending)
                } else {
                    Button(action: sendDraft) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(Theme.accentInk)
                            .frame(width: 46, height: 46)
                            .background(Theme.accent, in: Circle())
                    }
                    .disabled(model.isSending)
                    .accessibilityLabel("Send")
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .background(Theme.surface)
    }

    private func sendDraft() {
        let text = draft
        draft = ""
        Task { await model.send(text, byVoice: false) }
    }
}

/// The round accent mic button, used on Today and in the composer.
struct MicButton: View {
    var isListening = false
    var size: CGFloat = 46
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isListening ? "waveform" : "mic.fill")
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(Theme.accentInk)
                .symbolEffect(.variableColor.iterative, isActive: isListening)
                .frame(width: size, height: size)
                .background(Theme.accent, in: Circle())
        }
        .accessibilityLabel(isListening ? "Stop listening" : "Talk to Get To It")
    }
}
