import SwiftUI
import TalariaKit
import TalariaTheme

/// A live-only response surface for a hidden room-member session. It owns its
/// drafts locally: reconciliation may refresh the same request (including a
/// new runtime SID) without clearing what the human has typed. A different
/// request id deliberately starts fresh.
public struct RoomPendingPromptCard: View {
    public let prompt: RoomPendingPrompt
    public let member: RoomMember?
    public let theme: ThemePack
    public let respond: ([RoomPendingPromptAnswer]) async throws -> Void

    @State private var drafts: [String: String] = [:]
    @State private var selections: [String: Set<String>] = [:]
    @State private var sending = false
    @State private var responseError: String?

    public init(prompt: RoomPendingPrompt, member: RoomMember?, theme: ThemePack,
                respond: @escaping ([RoomPendingPromptAnswer]) async throws -> Void) {
        self.prompt = prompt
        self.member = member
        self.theme = theme
        self.respond = respond
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: prompt.kind == .approval ? "hand.raised.fill" : "questionmark.bubble.fill")
                    .foregroundStyle(prompt.kind == .approval ? theme.warn : theme.accent)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(prompt.kind == .approval ? "Approval needed" : "Answer needed")
                        .font(theme.body(12, weight: .bold)).foregroundStyle(theme.ink)
                    Text(sourceLabel).font(theme.mono(9)).foregroundStyle(theme.faint)
                }
                Spacer()
                if sending { ProgressView().controlSize(.small).accessibilityLabel("Sending answer") }
            }

            switch prompt.kind {
            case .approval: approvalBody
            case .clarify: clarifyBody
            }

            if let responseError {
                Label(responseError, systemImage: "exclamationmark.triangle.fill")
                    .font(theme.body(10)).foregroundStyle(theme.danger)
            }
        }
        .padding(12)
        .background((prompt.kind == .approval ? theme.warn : theme.accent).opacity(0.075),
                    in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke((prompt.kind == .approval ? theme.warn : theme.accent).opacity(0.32), lineWidth: 1)
        }
        .onChange(of: prompt.requestID) { _, _ in
            // The key is intentionally stable across profile rename, while a
            // fresh Hermes request on the same route must not inherit a draft.
            drafts.removeAll(); selections.removeAll(); responseError = nil; sending = false
        }
    }

    @ViewBuilder private var approvalBody: some View {
        if !prompt.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text(prompt.question).font(theme.body(12)).foregroundStyle(theme.ink)
        } else {
            Text("This member needs your approval to continue.")
                .font(theme.body(12)).foregroundStyle(theme.ink)
        }
        if !prompt.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text(prompt.command).font(theme.mono(10)).foregroundStyle(theme.faint)
                .textSelection(.enabled).padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.bg.opacity(0.72), in: RoundedRectangle(cornerRadius: 8))
        }
        HStack(spacing: 7) {
            ForEach(prompt.approvalChoices, id: \.rawValue) { choice in
                Button(approvalTitle(choice)) { submit([.approval(choice)]) }
                    .buttonStyle(.plain).font(theme.body(10, weight: .semibold))
                    .foregroundStyle(choice == .deny ? theme.danger : theme.accent)
                    .padding(.horizontal, 9).frame(minHeight: 36)
                    .background(theme.bg.opacity(0.72), in: Capsule())
                    .disabled(sending)
            }
        }
    }

    @ViewBuilder private var clarifyBody: some View {
        ForEach(prompt.questions) { question in
            clarifyQuestion(question)
        }
        if !remainingQuestions.isEmpty {
            Button(prompt.isBatchClarify ? "Send answers" : "Send answer") {
                submit(clarifyAnswers())
            }
            .buttonStyle(.plain).font(theme.body(11, weight: .semibold))
            .foregroundStyle(theme.bg).padding(.horizontal, 12).frame(minHeight: 40)
            .background(theme.accent, in: Capsule())
            .disabled(sending)
        } else {
            Label("Answers accepted", systemImage: "checkmark.circle.fill")
                .font(theme.body(11, weight: .semibold)).foregroundStyle(theme.ok)
        }
    }

    @ViewBuilder private func clarifyQuestion(_ question: RoomPendingClarifyQuestion) -> some View {
        let key = questionKey(question)
        VStack(alignment: .leading, spacing: 7) {
            if prompt.isBatchClarify, let questionID = question.questionID {
                Text("Question \(questionID)").font(theme.mono(8)).foregroundStyle(theme.faint)
            }
            if !question.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(question.question).font(theme.body(12)).foregroundStyle(theme.ink)
            }
            if prompt.isQuestionLocked(question) {
                Label("Answer accepted", systemImage: "checkmark.circle.fill")
                    .font(theme.body(10, weight: .semibold)).foregroundStyle(theme.ok)
                if let accepted = prompt.lockedAnswer(for: question.questionID ?? ""), !accepted.isEmpty {
                    Text(accepted).font(theme.body(10)).foregroundStyle(theme.faint)
                        .textSelection(.enabled)
                }
            } else if !question.choices.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(question.choices, id: \.self) { choice in
                        Button {
                            choose(choice, for: question)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: isChosen(choice, for: question)
                                      ? "checkmark.circle.fill" : "circle")
                                Text(choice).lineLimit(1)
                            }
                            .font(theme.body(10, weight: .medium))
                            .foregroundStyle(isChosen(choice, for: question) ? theme.accent : theme.faint)
                            .padding(.horizontal, 8).frame(minHeight: 32)
                            .background(theme.bg.opacity(0.7), in: Capsule())
                        }
                        .buttonStyle(.plain).disabled(sending)
                    }
                }
            }
            if !prompt.isQuestionLocked(question), !question.multiSelect {
                TextField(question.choices.isEmpty ? "Your answer" : "Or type an answer",
                          text: draftBinding(for: key))
                    .textFieldStyle(.plain).font(theme.body(11)).foregroundStyle(theme.ink)
                    .padding(.horizontal, 9).frame(minHeight: 38)
                    .background(theme.bg.opacity(0.72), in: RoundedRectangle(cornerRadius: 8))
                    .disabled(sending)
            }
        }
        .padding(prompt.isBatchClarify ? 9 : 0)
        .background(prompt.isBatchClarify ? theme.bg.opacity(0.34) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 9))
    }

    private var sourceLabel: String {
        let handle = member?.handle ?? prompt.route.profile
        let source = member?.sourceLabel ?? prompt.route.gatewayID
        return "@\(handle) · \(source)"
    }

    private func approvalTitle(_ choice: ApprovalChoice) -> String {
        switch choice {
        case .once: "Allow once"
        case .session: "Allow session"
        case .always: "Always allow"
        case .deny: "Deny"
        }
    }

    private func questionKey(_ question: RoomPendingClarifyQuestion) -> String {
        question.questionID ?? "__single__"
    }

    private func draftBinding(for key: String) -> Binding<String> {
        Binding(get: { drafts[key, default: ""] }, set: { drafts[key] = $0 })
    }

    private func isChosen(_ choice: String, for question: RoomPendingClarifyQuestion) -> Bool {
        let key = questionKey(question)
        if question.multiSelect { return selections[key, default: []].contains(choice) }
        return drafts[key] == choice
    }

    private func choose(_ choice: String, for question: RoomPendingClarifyQuestion) {
        let key = questionKey(question)
        if question.multiSelect {
            if selections[key, default: []].contains(choice) { selections[key]?.remove(choice) }
            else { selections[key, default: []].insert(choice) }
        } else {
            drafts[key] = drafts[key] == choice ? "" : choice
        }
    }

    private func clarifyAnswers() -> [RoomPendingPromptAnswer] {
        remainingQuestions.map { question in
            let key = questionKey(question)
            if question.multiSelect {
                // Preserve Hermes' displayed choice order; a Set's arbitrary
                // order would make otherwise equal retries look different.
                let chosen = question.choices.filter { selections[key, default: []].contains($0) }
                return .selections(chosen, questionID: question.questionID)
            }
            return .text(drafts[key, default: ""], questionID: question.questionID)
        }
    }

    private var remainingQuestions: [RoomPendingClarifyQuestion] {
        prompt.questions.filter { !prompt.isQuestionLocked($0) }
    }

    private func submit(_ answers: [RoomPendingPromptAnswer]) {
        guard !sending else { return }
        responseError = nil; sending = true
        Task { @MainActor in
            do { try await respond(answers) }
            catch { responseError = error.localizedDescription }
            sending = false
        }
    }
}
