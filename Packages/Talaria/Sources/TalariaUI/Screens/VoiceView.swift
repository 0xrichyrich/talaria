import SwiftUI
import TalariaKit
import TalariaTheme

// Voice — the full-screen overlay reached from the chat composer's mic.
// Two counter-rotating rings (solid + dashed; ink adds astrolabe crosshairs)
// around a breathing bot-avatar orb, a 12-bar waveform, the spoken quote, and
// hush / write side buttons around the red end button.
// Ported from Talaria.dc.html `data-screen-label="Voice"`.
//
// Demo mode plays the canned copy.voiceQuote. Live mode rides the gateway's
// voice.* surface: `voice.toggle` on entry/exit and mute, `voice.transcript` /
// `voice.status` events feed the quote line.

public struct VoiceView: View {
    private let model: AppModel
    private let botID: String
    @Binding private var isPresented: Bool

    @State private var link = VoiceLinkController()

    public init(model: AppModel, botID: String, isPresented: Binding<Bool>) {
        self.model = model
        self.botID = botID
        self._isPresented = isPresented
    }

    private var theme: ThemePack { model.theme.pack }
    private var copy: CopyPack { model.theme.copy }
    private var bot: Bot? { model.bot(botID) }

    /// The 12 bars' full-cycle durations + stagger, lifted from the prototype.
    private static let waveDurations: [Double] = [0.9, 1.4, 0.7, 1.1, 1.6, 0.8,
                                                  1.2, 0.6, 1.5, 1.0, 1.3, 0.75]

    public var body: some View {
        ZStack {
            background.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                    .padding(.top, 40)
                ringStage
                    .padding(.top, 42)
                waveform
                    .padding(.top, 36)
                quote
                    .padding(.top, 28)
                    .padding(.horizontal, 44)
                Spacer(minLength: 20)
                controls
                    .padding(.bottom, 30)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .onAppear { link.begin(model: model) }
        .onDisappear { link.end() }
    }

    // MARK: Background (the voiceBgCss token, derived from pack colors)

    @ViewBuilder
    private var background: some View {
        switch theme.id {
        case .soft:
            // linear 180deg: warm paper fading into lavender.
            theme.bg.overlay(
                LinearGradient(
                    stops: [.init(color: .clear, location: 0),
                            .init(color: theme.accent.opacity(0.10), location: 0.55),
                            .init(color: theme.accent.opacity(0.20), location: 1)],
                    startPoint: .top, endPoint: .bottom))
        case .control:
            // radial phosphor bloom behind the orb (circle at 50% 38%).
            theme.bg.overlay(
                RadialGradient(colors: [theme.accent.opacity(0.06), .clear],
                               center: UnitPoint(x: 0.5, y: 0.38),
                               startRadius: 0, endRadius: 320))
        case .ink:
            theme.bg
        }
    }

    // MARK: Header

    private var header: some View {
        Text(verbatim: "\(copy.voiceHead) \(plainUpper(botID))")
            .font(headFont)
            .tracking(theme.id == .soft ? 0 : 2.5)
            .foregroundStyle(headColor)
            .lineLimit(1)
    }

    private var headFont: Font {
        switch theme.id {
        case .soft: theme.body(13, weight: .bold)
        case .control: theme.mono(10, weight: .semibold)
        case .ink: theme.mono(9)
        }
    }

    private var headColor: Color {
        switch theme.id {
        case .soft: theme.ink.opacity(0.5)
        case .control: theme.accent
        case .ink: theme.ink.opacity(0.55)
        }
    }

    // MARK: Ring stage — 234pt: rings, orb, crosshairs, avatar

    private var ringStage: some View {
        ZStack {
            // Outer solid ring, 9s clockwise; control tips it with a bright arc.
            ZStack {
                Circle().strokeBorder(theme.voiceRing1, lineWidth: 1)
                Circle()
                    .trim(from: 0.62, to: 0.88)
                    .stroke(theme.voiceRing1Top, lineWidth: 1)
                    .padding(0.5)
            }
            .frame(width: 234, height: 234)
            .modifier(Spinning(duration: 9))

            // Inner dashed ring, 13s counter-clockwise.
            Circle()
                .strokeBorder(theme.voiceRing2, style: StrokeStyle(lineWidth: 1, dash: [4, 5]))
                .frame(width: 194, height: 194)
                .modifier(Spinning(duration: 13, reverse: true))

            // Breathing orb glow (soft/control; ink keeps the plate bare).
            if let orbStops = theme.voiceOrb {
                Circle()
                    .fill(RadialGradient(colors: [orbStops.center, orbStops.edge],
                                         center: UnitPoint(x: 0.37, y: 0.31),
                                         startRadius: 0, endRadius: 105))
                    .frame(width: 150, height: 150)
                    .modifier(Breathing())
            }

            // Ink's astrolabe crosshairs, over the rings, under the face.
            if theme.id == .ink {
                Rectangle().fill(theme.line).frame(width: 250, height: 1)
                Rectangle().fill(theme.line).frame(width: 1, height: 250)
            }

            AvatarView(shape: bot?.shape ?? .circle, hue: bot?.hue ?? .teal,
                       size: 90, isWorking: true, theme: theme)
                .modifier(Breathing())
        }
        .frame(width: 234, height: 234)
    }

    // MARK: Waveform

    private var waveform: some View {
        HStack(alignment: .center, spacing: 3.5) {
            ForEach(Array(Self.waveDurations.enumerated()), id: \.offset) { index, duration in
                WaveBar(color: theme.voiceWave,
                        glow: theme.voiceWaveGlow,
                        cornerRadius: theme.voiceBarRadius,
                        duration: duration,
                        delay: Double(index) * 0.09,
                        idle: link.isMuted)
            }
        }
        .frame(height: 33)
        .accessibilityHidden(true)
    }

    // MARK: Quote

    private var quote: some View {
        Text(quoteText)
            .font(quoteFont)
            .italic(theme.id == .ink)
            .lineSpacing(theme.id == .control ? 4.5 : 4)
            .multilineTextAlignment(.center)
            .foregroundStyle(theme.id == .control ? theme.ink.opacity(0.9) : theme.ink)
            .frame(maxWidth: .infinity)
            .animation(.easeInOut(duration: 0.2), value: quoteText)
    }

    /// Demo: the canned themed quote. Live: the rolling voice.transcript,
    /// falling back to the gateway's voice.status state while quiet.
    private var quoteText: String {
        if let transcript = link.transcript, !transcript.isEmpty { return transcript }
        if model.mode == .demo { return copy.voiceQuote }
        return link.stateLabel ?? ""
    }

    private var quoteFont: Font {
        switch theme.id {
        case .soft: theme.body(16, weight: .medium)
        case .control: theme.body(15)
        case .ink: theme.body(18)
        }
    }

    // MARK: Controls — mute · end · text

    private var controls: some View {
        HStack(spacing: 15) {
            sideButton(copy.mute, active: link.isMuted) {
                link.toggleMute()
            }
            endButton
            sideButton(copy.textBtn) {
                dismissToChat()
            }
        }
    }

    private var endButton: some View {
        Button(action: dismissToChat) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(theme.voiceEndGlyph)
                .frame(width: 19, height: 19)
                .frame(width: 63, height: 63)
                .background(theme.danger)
                .clipShape(RoundedRectangle(cornerRadius: theme.id == .control ? 12 : 31.5,
                                            style: .continuous))
                .shadow(color: theme.danger.opacity(theme.id == .control ? 0.45 : 0.38),
                        radius: theme.id == .control ? 13 : 11,
                        y: theme.id == .control ? 0 : 8)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(copy.cancel))
    }

    private func sideButton(_ label: String, active: Bool = false,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(sideLabel(label))
                .font(sideFont)
                .tracking(theme.id == .control ? 1 : 0)
                .foregroundStyle(active ? theme.accent : sideColor)
                .frame(width: 52, height: 52)
                .background(theme.id == .ink ? Color.clear : theme.panel)
                .clipShape(sideShape)
                .overlay(sideShape.strokeBorder(
                    active ? theme.accent.opacity(0.6) : sideBorder, lineWidth: 1))
                .contentShape(sideShape)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(active ? [.isSelected] : [])
    }

    /// Ink renders its lowercase verbs in small caps via the font; soft and
    /// control ship their labels pre-cased in the copy pack.
    private func sideLabel(_ label: String) -> String { label }

    private var sideShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: theme.id == .control ? 10 : 26, style: .continuous)
    }

    private var sideFont: Font {
        switch theme.id {
        case .soft: theme.body(11, weight: .heavy)
        case .control: theme.mono(9, weight: .bold)
        case .ink: theme.body(12, weight: .bold).smallCaps()
        }
    }

    private var sideColor: Color {
        theme.ink.opacity(theme.id == .ink ? 0.6 : 0.55)
    }

    private var sideBorder: Color {
        switch theme.id {
        case .soft: theme.line
        case .control: theme.lineStrong.opacity(0.8)
        case .ink: theme.lineStrong
        }
    }

    // MARK: Routing

    private func dismissToChat() {
        link.end()
        isPresented = false
    }

    private func plainUpper(_ id: String) -> String {
        (id.prefix(1).uppercased() + id.dropFirst()).uppercased()
    }
}

// MARK: - Live voice link (gateway voice.* surface)

/// Owns the live-mode voice session: flips `voice.toggle` on entry, exit and
/// mute, and folds `voice.transcript` / `voice.status` events into observable
/// state. Demo mode leaves the gateway untouched and only tracks local mute.
@MainActor
@Observable
private final class VoiceLinkController {
    var transcript: String?
    var stateLabel: String?
    var isMuted = false

    private var client: GatewayClient?
    private var handlerID: UUID?

    func begin(model: AppModel) {
        guard self.client == nil else { return } // already linked
        transcript = nil
        stateLabel = nil
        isMuted = false
        guard model.mode == .live, let client = model.client else { return }
        self.client = client
        Task { @MainActor [weak self] in
            guard let self, let client = self.client else { return }
            let id = await client.addEventHandler { [weak self] event in
                Task { @MainActor [weak self] in
                    self?.handle(event)
                }
            }
            // Torn down between registration and now? Unwind immediately.
            if self.client == nil {
                await client.removeEventHandler(id)
                return
            }
            self.handlerID = id
            try? await client.voiceSet(on: true)
        }
    }

    func toggleMute() {
        isMuted.toggle()
        guard let client else { return }
        let on = !isMuted
        Task { try? await client.voiceSet(on: on) }
    }

    func end() {
        guard let client else { return }
        let id = handlerID
        self.client = nil
        self.handlerID = nil
        Task {
            if let id { await client.removeEventHandler(id) }
            try? await client.voiceSet(on: false)
        }
    }

    private func handle(_ event: GatewayEvent) {
        switch TypedGatewayEvent(event) {
        case .voiceTranscript(let text, let stopPhrase):
            if let text, !text.isEmpty { transcript = text }
            if stopPhrase { stateLabel = nil }
        case .voiceStatus(let state):
            stateLabel = state.isEmpty ? nil : state
        default:
            break
        }
    }
}

// MARK: - Motion (ringU / breatheU / waveU keyframes)

/// Continuous rotation; `reverse` spins counter-clockwise.
private struct Spinning: ViewModifier {
    let duration: Double
    var reverse: Bool = false
    @State private var spinning = false

    func body(content: Content) -> some View {
        content
            .rotationEffect(.degrees(spinning ? (reverse ? -360 : 360) : 0))
            .onAppear {
                withAnimation(.linear(duration: duration).repeatForever(autoreverses: false)) {
                    spinning = true
                }
            }
    }
}

/// The 3.2s scale(1 → 1.07) breathing cycle shared by orb and face.
private struct Breathing: ViewModifier {
    @State private var swollen = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(swollen ? 1.07 : 1.0)
            .onAppear {
                withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                    swollen = true
                }
            }
    }
}

/// One 4×29 waveform bar: scaleY .22 ↔ 1 on its own staggered clock; muting
/// pins every bar low.
private struct WaveBar: View {
    let color: Color
    let glow: Color?
    let cornerRadius: CGFloat
    let duration: Double
    let delay: Double
    let idle: Bool

    @State private var tall = false

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(color)
            .frame(width: 4, height: 29)
            .shadow(color: glow ?? .clear, radius: glow == nil ? 0 : 4)
            .scaleEffect(y: (tall && !idle) ? 1 : 0.22, anchor: .center)
            .animation(.easeOut(duration: 0.2), value: idle)
            .onAppear {
                withAnimation(.easeInOut(duration: duration / 2)
                    .repeatForever(autoreverses: true)
                    .delay(delay)) {
                    tall = true
                }
            }
    }
}

// MARK: - Voice tokens (ring1/ring1Top/ring2/orbFill/waveC/… derived per pack)

private extension ThemePack {
    /// Outer solid ring stroke.
    var voiceRing1: Color {
        switch id {
        case .soft: accent.opacity(0.35)
        case .control: accent.opacity(0.30)
        case .ink: ink.opacity(0.40)
        }
    }

    /// The brighter top arc of the outer ring (soft blends it away).
    var voiceRing1Top: Color {
        switch id {
        case .soft: accent.opacity(0.35)
        case .control: accent
        case .ink: ink
        }
    }

    /// Inner dashed ring stroke.
    var voiceRing2: Color {
        switch id {
        case .soft: accent.opacity(0.30)
        case .control: accent.opacity(0.25)
        case .ink: ink.opacity(0.35)
        }
    }

    /// Radial orb fill stops; nil = no orb (ink's bare astrolabe).
    var voiceOrb: (center: Color, edge: Color)? {
        switch id {
        case .soft: (color(for: .violet).opacity(0.50), accent.opacity(0.15))
        case .control: (accent.opacity(0.32), accent.opacity(0.04))
        case .ink: nil
        }
    }

    /// Waveform bar color (waveC).
    var voiceWave: Color {
        id == .ink ? ink : accent
    }

    /// Phosphor bloom behind the bars — control only (waveGlow).
    var voiceWaveGlow: Color? {
        id == .control ? accent.opacity(0.5) : nil
    }

    /// Bar end radius follows the theme's dot language (dotR).
    var voiceBarRadius: CGFloat {
        id == .control ? 1 : 2
    }

    /// The 19pt square inside the red end button (voiceEndGlyph).
    var voiceEndGlyph: Color {
        id == .soft ? panel : bg
    }
}
