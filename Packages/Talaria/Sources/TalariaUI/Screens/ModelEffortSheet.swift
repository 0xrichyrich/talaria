import SwiftUI
import TalariaKit
import TalariaTheme

/// Model + reasoning-effort picker, opened from the chat's model strip.
/// Desktop parity: the status-bar model picker (config.set model, deferred
/// when a turn is live) and the reasoning control (config.set reasoning).
public struct ModelEffortSheet: View {
    @Environment(\.dismiss) private var dismiss
    var model: AppModel
    var botID: String

    @State private var models: [String] = []
    @State private var loading = true
    @State private var selectedModel: String?
    @State private var selectedEffort: String

    private static let efforts = ["none", "low", "medium", "high"]

    public init(model: AppModel, botID: String) {
        self.model = model
        self.botID = botID
        _selectedModel = State(initialValue: model.bot(botID)?.pinnedModel)
        _selectedEffort = State(initialValue: model.chats[botID]?.reasoningEffort ?? "")
    }

    private var theme: ThemePack { model.theme.pack }
    private var copy: CopyPack { model.theme.copy }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(copy.modelSec)
                    .font(theme.mono(10, weight: .bold))
                    .tracking(1.5)
                    .foregroundStyle(theme.faint)
                Spacer()
                Button(copy.cancel) { dismiss() }
                    .font(theme.body(13, weight: .semibold))
                    .foregroundStyle(theme.accent)
                    .buttonStyle(.plain)
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 10)

            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if loading {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(verbatim: "model.options…")
                                .font(theme.mono(11))
                                .foregroundStyle(theme.faint)
                        }
                        .padding(.vertical, 12)
                    } else {
                        ForEach(models, id: \.self) { id in
                            row(id, selected: id == selectedModel) {
                                selectedModel = id
                                model.setModel(botID: botID, to: id)
                            }
                        }
                    }

                    Text(verbatim: "REASONING")
                        .font(theme.mono(10, weight: .bold))
                        .tracking(1.5)
                        .foregroundStyle(theme.faint)
                        .padding(.top, 18)
                        .padding(.bottom, 4)

                    HStack(spacing: 7) {
                        ForEach(Self.efforts, id: \.self) { effort in
                            effortChip(effort)
                        }
                    }

                    Text(verbatim: "Model switches mid-turn are deferred by the gateway until the turn settles; reasoning effort applies to the next turn.")
                        .font(theme.body(11))
                        .foregroundStyle(theme.faint)
                        .padding(.top, 14)
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 30)
            }
        }
        .background(theme.bg)
        .presentationDetents([.medium, .large])
        .presentationBackground(theme.bg)
        .task {
            models = await model.availableModels()
            if selectedModel == nil { selectedModel = models.first }
            loading = false
        }
    }

    private func row(_ id: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(id)
                    .font(theme.id == .soft ? theme.body(13.5, weight: .semibold) : theme.mono(12, weight: .semibold))
                    .foregroundStyle(theme.ink)
                    .lineLimit(1)
                Spacer()
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(theme.accent)
                }
            }
            .padding(.vertical, 11)
            .padding(.horizontal, 13)
            .background(selected ? AnyShapeStyle(theme.accent.opacity(0.08)) : AnyShapeStyle(theme.panel),
                        in: RoundedRectangle(cornerRadius: theme.rowRadius == 0 ? 0 : 12))
            .overlay(RoundedRectangle(cornerRadius: theme.rowRadius == 0 ? 0 : 12)
                .stroke(selected ? theme.accentFaint : theme.line, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func effortChip(_ effort: String) -> some View {
        let on = selectedEffort == effort
        return Button {
            selectedEffort = effort
            model.setReasoningEffort(botID: botID, to: effort)
        } label: {
            Text(effort)
                .font(theme.mono(11, weight: .semibold))
                .foregroundStyle(on ? theme.accentFg : theme.ink)
                .padding(.vertical, 8)
                .padding(.horizontal, 13)
                .background(on ? AnyShapeStyle(theme.accent) : AnyShapeStyle(theme.inset),
                            in: RoundedRectangle(cornerRadius: theme.chipIsCapsule ? 999 : theme.buttonRadius))
                .overlay {
                    if !on {
                        RoundedRectangle(cornerRadius: theme.chipIsCapsule ? 999 : theme.buttonRadius)
                            .stroke(theme.line, lineWidth: 1)
                    }
                }
        }
        .buttonStyle(.plain)
    }
}
