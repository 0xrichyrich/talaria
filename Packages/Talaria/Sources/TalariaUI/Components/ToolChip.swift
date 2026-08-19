import SwiftUI
import TalariaKit
import TalariaTheme

// Inline tool cards under an assistant bubble — desktop renders a tool block
// per call with a structured summary, duration and expandable result; this is
// the phone-sized version of the same thing.
//
// State comes straight off the wire: tool.generating parks a chip while the
// model writes arguments, tool.start names it and shows the ≤80-char argument
// preview, tool.complete stamps duration + summary. Chips stay collapsed —
// a tap opens the full result text, which scrolls in both axes so a 4k-line
// grep result can never take the transcript with it.

// MARK: - List

public struct ToolCallList: View {
    private let calls: [ToolCall]
    private let theme: ThemePack
    private let copy: CopyPack
    private let accent: Color

    public init(calls: [ToolCall], theme: ThemePack, copy: CopyPack, accent: Color) {
        self.calls = calls
        self.theme = theme
        self.copy = copy
        self.accent = accent
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: theme.id == .ink ? 2 : 5) {
            ForEach(calls) { call in
                ToolChip(call: call, theme: theme, copy: copy, accent: accent)
            }
        }
    }
}

// MARK: - Chip

public struct ToolChip: View {
    private let call: ToolCall
    private let theme: ThemePack
    private let copy: CopyPack
    private let accent: Color

    @State private var expanded = false
    @State private var copied = false
    @Environment(\.talariaReducedMotion) private var reducedMotion

    public init(call: ToolCall, theme: ThemePack, copy: CopyPack, accent: Color) {
        self.call = call
        self.theme = theme
        self.copy = copy
        self.accent = accent
    }

    /// Full result text, else the one-line summary — what expanding reveals.
    private var detail: String? {
        if let text = call.resultText, !text.isEmpty { return text }
        if let summary = call.summary, !summary.isEmpty, summary != call.context { return summary }
        return nil
    }

    private var expandable: Bool { detail != nil && call.state != .running }

    private var stateColor: Color {
        switch call.state {
        case .running: theme.id == .control ? theme.accent : accent
        case .done: theme.id == .ink ? theme.ink.opacity(0.5) : theme.ok
        case .failed: theme.danger
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                guard expandable else { return }
                withAnimation(reducedMotion ? nil : .easeOut(duration: 0.18)) { expanded.toggle() }
            } label: {
                headline
                    .padding(.vertical, theme.id == .ink ? 5 : 7)
                    .padding(.horizontal, theme.id == .ink ? 8 : 10)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!expandable)

            if expanded, let detail {
                resultPanel(detail)
            }
        }
        .background(chrome)
    }

    // MARK: Collapsed line

    private var headline: some View {
        HStack(spacing: 7) {
            glyph
            Text(nameText)
                .font(nameFont)
                .tracking(theme.id == .soft ? 0 : theme.id == .control ? 1 : 0.8)
                .foregroundStyle(theme.id == .control ? stateColor : theme.ink.opacity(0.85))
                .lineLimit(1)
                .fixedSize()
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(subtitleFont)
                    .italic(theme.id == .ink)
                    .foregroundStyle(theme.faint)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            if let duration = durationText {
                Text(duration)
                    .font(theme.mono(theme.id == .ink ? 8 : 9))
                    .foregroundStyle(theme.faint)
                    .monospacedDigit()
            }
            if expandable {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(theme.faint)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
            }
        }
    }

    @ViewBuilder private var glyph: some View {
        switch call.state {
        case .running:
            ToolSpinner(color: stateColor, theme: theme)
        case .done:
            Text(verbatim: theme.id == .ink ? "·" : "✓")
                .font(theme.mono(theme.id == .ink ? 11 : 9.5, weight: .bold))
                .foregroundStyle(stateColor)
                .frame(width: 10)
        case .failed:
            Text(verbatim: "✕")
                .font(theme.mono(9.5, weight: .bold))
                .foregroundStyle(stateColor)
                .frame(width: 10)
        }
    }

    private var nameText: String {
        switch theme.id {
        case .soft: call.name
        case .control: call.name.uppercased()
        case .ink: call.name
        }
    }

    private var nameFont: Font {
        switch theme.id {
        case .soft: theme.body(12.5, weight: .semibold)
        case .control: theme.mono(10, weight: .semibold)
        case .ink: theme.body(13.5, weight: .semibold).smallCaps()
        }
    }

    private var subtitleFont: Font {
        switch theme.id {
        case .soft: theme.body(11.5)
        case .control: theme.mono(9.5)
        case .ink: theme.body(12.5)
        }
    }

    /// Argument preview while running; the result summary once it lands.
    private var subtitle: String {
        switch call.state {
        case .running:
            return call.context.isEmpty ? copy.toolRunning(theme.id) : call.context
        case .done:
            if let summary = call.summary, !summary.isEmpty { return summary }
            return call.context
        case .failed:
            if let summary = call.summary, !summary.isEmpty { return summary }
            return copy.toolFailed(theme.id)
        }
    }

    private var durationText: String? {
        guard let seconds = call.durationSeconds, seconds > 0 else { return nil }
        if seconds < 1 { return "\(Int(seconds * 1000))ms" }
        return String(format: "%.1fs", seconds)
    }

    // MARK: Expanded result

    private func resultPanel(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(copy.toolResultHead(theme.id))
                    .font(theme.mono(8.5, weight: .semibold))
                    .tracking(1.4)
                    .foregroundStyle(theme.faint)
                Spacer(minLength: 0)
                Button {
                    copyToPasteboard(text)
                    copied = true
                } label: {
                    Text(copied ? "✓" : "⧉")
                        .font(theme.mono(11))
                        .foregroundStyle(copied ? theme.ok : theme.faint)
                        .frame(width: 22, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            ScrollView([.horizontal, .vertical], showsIndicators: false) {
                Text(text)
                    .font(theme.mono(10.5))
                    .lineSpacing(2)
                    .foregroundStyle(theme.sub)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
            }
            .frame(maxHeight: 220)
        }
        .padding(.horizontal, theme.id == .ink ? 8 : 10)
        .padding(.bottom, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Chrome

    @ViewBuilder private var chrome: some View {
        switch theme.id {
        case .soft:
            RoundedRectangle(cornerRadius: 12)
                .fill(theme.inset)
                .overlay(RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(call.state == .running ? accent.opacity(0.3) : theme.line,
                                  lineWidth: 1))
        case .control:
            RoundedRectangle(cornerRadius: 6)
                .fill(theme.panel)
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(call.state == .running ? theme.accent.opacity(0.4)
                                    : theme.lineStrong.opacity(0.7),
                                  lineWidth: 1))
        case .ink:
            // Ledger entry, not a card: one hairline under the row.
            Rectangle()
                .fill(Color.clear)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(theme.line).frame(height: 1)
                }
        }
    }
}

// MARK: - Spinner

/// The running marker: a rotating arc (soft/ink) that also carries the control
/// theme's phosphor glow.
struct ToolSpinner: View {
    var color: Color
    var theme: ThemePack

    @State private var spinning = false
    @Environment(\.talariaReducedMotion) private var reducedMotion

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.7)
            .stroke(color, style: StrokeStyle(lineWidth: 1.7,
                                              lineCap: theme.id == .ink ? .butt : .round))
            .frame(width: 10, height: 10)
            .rotationEffect(.degrees(TranscriptMotionPolicy.toolSpinnerDegrees(
                spinning: spinning, reducedMotion: reducedMotion
            )))
            .animation(reducedMotion ? nil
                       : .linear(duration: 0.9).repeatForever(autoreverses: false),
                       value: spinning)
            .shadow(color: theme.glowRadius > 0 ? color.opacity(0.7) : .clear, radius: 4)
            .onAppear { spinning = !reducedMotion }
            .onChange(of: reducedMotion) { _, reduced in spinning = !reduced }
    }
}
