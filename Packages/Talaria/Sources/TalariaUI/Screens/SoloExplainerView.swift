import SwiftUI
import TalariaKit
import TalariaTheme

// The Solo explainer — roadmap Phase 5, docs/SOLO-MODE.md §"The explainer GUI".
//
// "Solo mode is only trustworthy if people can see exactly what they get."
//
// Three columns, side by side wherever the screen is wide enough to hold them,
// because the point is the COMPARISON and a comparison you have to scroll
// between is a list:
//
//   WORKS ON DEVICE      chat, memory, the tool list, private, no network
//   NEEDS A GATEWAY      shell and a real machine, browser automation, MCP,
//                        skills, cron routines, bot-to-bot handoffs, subagents
//   WHAT IT COSTS        model availability or download size, expected speed on
//                        THIS device class, the battery and thermal note
//
// Two rules this screen lives by, and they are the reason it exists at all:
//
// 1. NOTHING HERE IS ASSERTED. The engine row is a live probe
//    (`SoloEngineProbe`), the device figures come from `SoloDeviceProfile`, the
//    tool list is generated from `SoloPermission.toolNames` so it cannot drift
//    from what `SoloToolRegistry` actually builds, and the decode band is the
//    measured one from .research/profiles-runtime.md §8.4 rather than a
//    flattering guess. If Foundation Models is unavailable on this device the
//    screen says so plainly, in that device's own terms, and offers the
//    alternatives instead of hiding the problem.
// 2. IT IS NOT A MODAL. `SoloSettingsStore.hasSeenExplainer` only decides
//    whether onboarding opens it unprompted; the screen is reachable forever
//    from Solo settings, because a trade-off that is shown once and then buried
//    was never really disclosed.
//
// Mounted like Settings: `.talariaSoloExplainer(model:)` on the root, and
// anything that wants it posts `.talariaOpenSoloExplainer`. Neither the roster
// nor Settings has to own it or thread a binding through.

public struct SoloExplainerView: View {
    private let model: AppModel
    private let onClose: (() -> Void)?
    /// Shown only when the caller has somewhere for "Set up Solo" to go —
    /// onboarding does, a Settings visit does not.
    private let onContinue: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    @State private var foundation: SoloEngineAvailability = .unavailable(.unknown)
    @State private var mlx: SoloEngineAvailability = .unavailable(.notBuilt)
    @State private var portal: SoloEngineAvailability = .unavailable(.notSignedIn)

    public init(model: AppModel, onClose: (() -> Void)? = nil,
                onContinue: (() -> Void)? = nil) {
        self.model = model
        self.onClose = onClose
        self.onContinue = onContinue
    }

    private var theme: ThemePack { model.theme.pack }
    private var copy: CopyPack { model.theme.copy }
    private var reducedMotion: Bool {
        model.settings.prefersReducedMotion(system: systemReduceMotion)
    }

    /// Below this the three panels stack; above it they sit side by side. 640pt
    /// is where a third of the width still fits a readable measure — narrower
    /// than that and "side by side" becomes three columns of one word.
    private static let sideBySideWidth: CGFloat = 640

    public var body: some View {
        GeometryReader { geometry in
            let sideBySide = geometry.size.width >= Self.sideBySideWidth
            VStack(alignment: .leading, spacing: 0) {
                header
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        lede
                            .settingsEntrance(delay: 0, reduced: reducedMotion)
                        engineCard
                            .settingsEntrance(delay: 0.04, reduced: reducedMotion)
                        panels(sideBySide: sideBySide)
                            .settingsEntrance(delay: 0.08, reduced: reducedMotion)
                        footer
                            .settingsEntrance(delay: 0.12, reduced: reducedMotion)
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 4)
                    .padding(.bottom, 56)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(theme.bg)
        .talariaTextSize(model)
        .task {
            // Probed on every open, never cached: Apple Intelligence can be
            // switched on, and the system model finishes downloading, between
            // one visit and the next.
            foundation = SoloEngineProbe.foundationModels()
            mlx = SoloEngineProbe.mlx()
            // Signing in to Portal happens in Connections, which this screen
            // hands off to — so the row has to be read from the token store on
            // every open rather than asserted, or the person comes back from
            // signing in and the screen still says "sign in".
            portal = SoloEngineProbe.portal(
                isSignedIn: NousPortalTokenStore()
                    .load(portalURL: PortalDirectoryAPI.resolvedPortalURL) != nil)
            SoloSettingsStore.shared.hasSeenExplainer = true
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Button {
                if let onClose { onClose() } else { dismiss() }
            } label: {
                Text(verbatim: "‹")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(theme.id == .ink ? theme.ink : theme.accent)
                    .frame(width: 31, height: 31)
                    .background(theme.id == .ink ? Color.clear : theme.panel)
                    .clipShape(backShape)
                    .overlay(backShape.strokeBorder(
                        theme.id == .ink ? theme.lineStrong : theme.line, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(copy.settingsBack(theme.id)))

            VStack(alignment: .leading, spacing: 1) {
                if theme.showsKicker {
                    Text(copy.soloKicker(theme.id))
                        .font(theme.mono(9.5, weight: .semibold))
                        .tracking(2)
                        .foregroundStyle(theme.id == .ink ? theme.sub : theme.accent)
                }
                Text(copy.soloTitle(theme.id))
                    .font(titleFont)
                    .foregroundStyle(theme.ink)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    private var backShape: RoundedRectangle {
        let radius: CGFloat = theme.iconCornerFraction >= 0.5 ? 15.5 : 31 * theme.iconCornerFraction
        return RoundedRectangle(cornerRadius: radius, style: .continuous)
    }

    private var titleFont: Font {
        switch theme.id {
        case .soft: theme.display(20)
        case .control: theme.display(18)
        case .ink: theme.display(22, weight: .bold).smallCaps()
        }
    }

    private var lede: some View {
        Text(copy.soloLede(theme.id))
            .font(ledeFont)
            .italic(theme.id == .ink)
            .foregroundStyle(theme.sub)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var ledeFont: Font {
        switch theme.id {
        case .soft: theme.body(14)
        case .control: theme.mono(11)
        case .ink: theme.body(15)
        }
    }

    // MARK: Engine card — the live probe

    /// The one part of this screen that is about THIS phone rather than about
    /// Solo. It leads because "can I even run it" comes before "what does it
    /// do", and because an unavailable default is the single thing this screen
    /// must never let a person discover later.
    private var engineCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            GatewaySectionLabel(theme: theme, text: copy.soloEngineSection(theme.id))
                .padding(.horizontal, 2)

            SettingsGroup(theme: theme) {
                engineRow(.foundation, availability: foundation, isLast: false)
                engineRow(.mlx, availability: mlx, isLast: false)
                engineRow(.portal, availability: portal, isLast: true)
            }

            GatewayFootnote(theme: theme, text: engineFootnote)
                .padding(.horizontal, 2)
        }
    }

    /// When the default is unavailable, the footnote is the sentence that keeps
    /// the screen honest — it names the reason in the device's own terms and
    /// points at what still works, rather than leaving a dead row.
    private var engineFootnote: String {
        guard let reason = foundation.reason else { return copy.soloEngineNote(theme.id) }
        return copy.soloFoundationUnavailable(reason, theme.id)
    }

    private func engineRow(_ engine: SoloEngineID, availability: SoloEngineAvailability,
                           isLast: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(copy.soloEngineName(engine, theme.id))
                    .font(SettingsType.rowTitle(theme))
                    .foregroundStyle(theme.ink)
                Text(copy.soloEngineDetail(engine, theme.id))
                    .font(SettingsType.rowSubtitle(theme))
                    .italic(theme.id == .ink)
                    .foregroundStyle(theme.id == .control ? theme.faint : theme.sub)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            statusTag(availability)
        }
        .modifier(SettingsRowChrome(theme: theme, isLast: isLast))
        .accessibilityElement(children: .combine)
    }

    private func statusTag(_ availability: SoloEngineAvailability) -> some View {
        let ok = availability.isAvailable
        return HStack(spacing: 5) {
            Circle()
                .fill(ok ? theme.ok : theme.faint)
                .frame(width: 6, height: 6)
            Text(ok ? copy.soloReady(theme.id)
                    : copy.soloReasonTag(availability.reason ?? .unknown, theme.id))
                .font(theme.mono(9, weight: .semibold))
                .tracking(1)
                .foregroundStyle(ok ? theme.ok : theme.faint)
                .multilineTextAlignment(.trailing)
        }
    }

    // MARK: The three panels

    @ViewBuilder
    private func panels(sideBySide: Bool) -> some View {
        if sideBySide {
            HStack(alignment: .top, spacing: 14) {
                onDevicePanel
                gatewayPanel
                costPanel
            }
        } else {
            VStack(alignment: .leading, spacing: 20) {
                onDevicePanel
                gatewayPanel
                costPanel
            }
        }
    }

    private var onDevicePanel: some View {
        ComparisonPanel(theme: theme, tone: .yes,
                        title: copy.soloWorksHere(theme.id),
                        note: copy.soloWorksHereNote(theme.id)) {
            ForEach(copy.soloWorksHereItems(theme.id), id: \.self) { item in
                ComparisonRow(theme: theme, tone: .yes, text: item)
            }
            // Generated from the permission set, so a tool added to the
            // registry appears here and one removed disappears — this list can
            // never quietly become a brochure. `isUsableInThisBuild` rather than
            // `isCompiledIn`: a family this build cannot even ask the OS about
            // is not something that "works on this phone".
            ForEach(SoloPermission.allCases.filter(\.isUsableInThisBuild)) { permission in
                ComparisonRow(theme: theme, tone: .yes,
                              text: copy.soloPermTitle(permission, theme.id),
                              detail: permission.toolNames.joined(separator: ", "))
            }
        }
    }

    private var gatewayPanel: some View {
        ComparisonPanel(theme: theme, tone: .no,
                        title: copy.soloNeedsGateway(theme.id),
                        note: copy.soloNeedsGatewayNote(theme.id)) {
            ForEach(copy.soloNeedsGatewayItems(theme.id), id: \.0) { item in
                ComparisonRow(theme: theme, tone: .no, text: item.0, detail: item.1)
            }
        }
    }

    private var costPanel: some View {
        ComparisonPanel(theme: theme, tone: .cost,
                        title: copy.soloCosts(theme.id),
                        note: copy.soloCostsNote(theme.id)) {
            ForEach(costRows, id: \.0) { row in
                ComparisonRow(theme: theme, tone: .cost, text: row.0, detail: row.1)
            }
        }
    }

    /// Measured, in this order: what the default costs on THIS device, what the
    /// alternative would cost to download, how fast it will feel, and what it
    /// does to the battery. Every figure has a source.
    private var costRows: [(String, String)] {
        let profile = SoloDeviceProfile.current
        var rows: [(String, String)] = []

        rows.append((copy.soloCostModel(theme.id),
                     foundation.isAvailable ? copy.soloCostModelFree(theme.id)
                                            : copy.soloCostModelDownload(theme.id)))

        let fitting = SoloModelCatalog.all.filter { $0.fits(profile) }
        rows.append((copy.soloCostDownload(theme.id),
                     fitting.isEmpty
                        ? copy.soloCostNoneFit(theme.id)
                        : fitting.map { "\($0.name) \(AppModel.formattedBytes($0.downloadBytes))" }
                            .joined(separator: " · ")))

        rows.append((copy.soloCostDevice(theme.id),
                     copy.soloDeviceLine(profile, theme.id)))

        let band = SoloDeviceProfile.decodeTokensPerSecond
        rows.append((copy.soloCostSpeed(theme.id),
                     copy.soloSpeedLine(low: band.lowerBound, high: band.upperBound, theme.id)))

        rows.append((copy.soloCostBattery(theme.id), copy.soloBatteryLine(theme.id)))
        rows.append((copy.soloCostPrivacy(theme.id), copy.soloPrivacyLine(theme.id)))
        return rows
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let onContinue {
                Button(action: onContinue) {
                    Text(copy.soloContinue(theme.id))
                        .font(theme.mono(11, weight: .bold))
                        .tracking(1)
                        .foregroundStyle(theme.accentFg)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(theme.accent,
                                    in: RoundedRectangle(cornerRadius: theme.buttonRadius,
                                                         style: .continuous))
                }
                .buttonStyle(.plain)
            }

            // Never a dead end: whatever this device cannot do locally, a
            // gateway can, and the way to one is one tap from the disclosure.
            Button {
                if let onClose { onClose() } else { dismiss() }
                NotificationCenter.default.post(name: .talariaOpenConnections, object: nil)
            } label: {
                Text(copy.soloConnectGateway(theme.id))
                    .font(theme.mono(11, weight: .bold))
                    .tracking(1)
                    .foregroundStyle(theme.id == .ink ? theme.ink : theme.accent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(theme.inset,
                                in: RoundedRectangle(cornerRadius: theme.buttonRadius,
                                                     style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: theme.buttonRadius,
                                              style: .continuous)
                        .strokeBorder(theme.id == .ink ? theme.lineStrong
                                                       : theme.accent.opacity(0.35), lineWidth: 1))
            }
            .buttonStyle(.plain)

            GatewayFootnote(theme: theme, text: copy.soloFooterNote(theme.id))
                .padding(.horizontal, 2)
                .padding(.top, 2)
        }
    }
}

// MARK: - Comparison chrome

/// One column of the comparison. The three tones are the whole argument of the
/// screen, so they are a token choice per theme rather than a decoration: `yes`
/// borrows `ok`, `no` borrows `faint` (absence, not danger — a gateway feature
/// is not a failure), and `cost` borrows `warn`.
enum ComparisonTone {
    case yes, no, cost

    func color(_ theme: ThemePack) -> Color {
        switch self {
        case .yes: theme.ok
        case .no: theme.faint
        case .cost: theme.warn
        }
    }

    /// Ink sets its columns with marks rather than colour, because a ledger
    /// that shouts in green stops being a ledger.
    func mark(_ theme: ThemePack) -> String {
        switch (self, theme.id) {
        case (.yes, .ink): "✠"
        case (.no, .ink): "—"
        case (.cost, .ink): "§"
        case (.yes, _): "✓"
        case (.no, _): "✕"
        case (.cost, _): "•"
        }
    }
}

struct ComparisonPanel<Content: View>: View {
    var theme: ThemePack
    var tone: ComparisonTone
    var title: String
    var note: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Text(tone.mark(theme))
                    .font(theme.mono(10, weight: .bold))
                    .foregroundStyle(tone.color(theme))
                Text(title)
                    .font(headingFont)
                    .tracking(theme.id == .soft ? 1 : 1.8)
                    .textCase(.uppercase)
                    .foregroundStyle(theme.id == .ink ? theme.ink : tone.color(theme))
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 0) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
                .modifier(SettingsGroupChrome(theme: theme))

            Text(note)
                .font(noteFont)
                .italic(theme.id == .ink)
                .foregroundStyle(theme.id == .ink ? theme.ink.opacity(0.55) : theme.faint)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var headingFont: Font {
        switch theme.id {
        case .soft: theme.body(11, weight: .heavy)
        case .control: theme.mono(9, weight: .bold)
        case .ink: theme.mono(8.5)
        }
    }

    private var noteFont: Font {
        switch theme.id {
        case .soft: theme.body(11.5)
        case .control: theme.mono(9)
        case .ink: theme.body(12.5)
        }
    }
}

struct ComparisonRow: View {
    var theme: ThemePack
    var tone: ComparisonTone
    var text: String
    var detail: String?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(tone.mark(theme))
                .font(theme.mono(9.5, weight: .bold))
                .foregroundStyle(tone.color(theme))
                .frame(width: 11, alignment: .leading)
                // Marks are decoration on a row whose text already says it.
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(text)
                    .font(SettingsType.rowTitle(theme))
                    .foregroundStyle(theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(theme.id == .control ? theme.mono(9) : SettingsType.rowSubtitle(theme))
                        .italic(theme.id == .ink)
                        .foregroundStyle(theme.id == .control ? theme.faint : theme.sub)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, theme.rowStyle == .ledger ? 2 : 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            if theme.rowStyle == .ledger { theme.line.frame(height: 1) }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Presentation

public extension Notification.Name {
    /// Post to open the Solo explainer from anywhere — Solo settings, the
    /// onboarding third door, an offline hand-off banner.
    static let talariaOpenSoloExplainer = Notification.Name("bot.talaria.openSoloExplainer")
}

/// Hosts the explainer for whoever owns the screen graph. Mount once, beside
/// the other overlays:
///
///     TalariaRootView(model: model)
///         .talariaSoloExplainer(model: model)
///
/// Same shape as `TalariaSettingsPresenter`, and for the same reason: the
/// screens that want it — Solo settings, onboarding — must not have to own it.
public struct TalariaSoloExplainerPresenter: ViewModifier {
    private let model: AppModel

    @State private var isPresented = false
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    public init(model: AppModel) { self.model = model }

    private var pushAnimation: Animation {
        model.settings.prefersReducedMotion(system: systemReduceMotion)
            ? .easeOut(duration: 0.15) : .easeOut(duration: 0.32)
    }

    public func body(content: Content) -> some View {
        content
            .overlay {
                if isPresented {
                    ZStack {
                        model.theme.pack.bg.ignoresSafeArea()
                        SoloExplainerView(model: model, onClose: {
                            withAnimation(pushAnimation) { isPresented = false }
                        })
                    }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                    // Above Settings (14), because Solo settings is what opens
                    // it and a disclosure behind the screen that asked for it
                    // is not a disclosure.
                    .zIndex(16)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .talariaOpenSoloExplainer)) { _ in
                guard !isPresented else { return }
                withAnimation(pushAnimation) { isPresented = true }
            }
            .onReceive(NotificationCenter.default.publisher(for: .talariaOpenConnections)) { _ in
                // The footer hands off to Connections; it must not stay stacked
                // on top of the screen it just asked for.
                guard isPresented else { return }
                withAnimation(pushAnimation) { isPresented = false }
            }
    }
}

public extension View {
    /// Mount the Solo explainer on this view tree.
    func talariaSoloExplainer(model: AppModel) -> some View {
        modifier(TalariaSoloExplainerPresenter(model: model))
    }
}

// MARK: - Copy

/// Voice for Solo's disclosure surfaces. Shared with SoloSettingsView, because
/// the two screens name the same seven permissions and must not name them
/// differently.
public extension CopyPack {

    func soloKicker(_ t: ThemeID) -> String {
        switch t {
        case .soft: "TALARIA // ALONE"
        case .control: "NO UPLINK"
        case .ink: "WITHOUT THE GATEWAY"
        }
    }

    func soloTitle(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Solo mode"
        case .control: "SOLO MODE"
        case .ink: "The Solitary Familiar"
        }
    }

    func soloLede(_ t: ThemeID) -> String {
        switch t {
        case .soft:
            return "Solo is an agent that runs entirely on this phone — no gateway, no server, "
                + "nothing leaving the device. It is genuinely useful and genuinely smaller. "
                + "Here is exactly what you get, and exactly what you don’t."
        case .control:
            return "SOLO = ON-DEVICE AGENT LOOP. NO GATEWAY, NO SERVER, NO EGRESS. "
                + "FULL CAPABILITY DELTA BELOW — READ IT BEFORE YOU RELY ON IT."
        case .ink:
            return "Solo is a familiar that keeps entirely to this device — no gateway, no "
                + "distant house, and nothing carried abroad. It is a true help and a lesser "
                + "one. What follows is the whole of the bargain, plainly set down."
        }
    }

    // MARK: Engines

    func soloEngineSection(_ t: ThemeID) -> String {
        switch t {
        case .soft: "On this device, right now"
        case .control: "ENGINE PROBE — THIS DEVICE"
        case .ink: "WHAT THIS DEVICE CAN BEAR"
        }
    }

    func soloEngineName(_ engine: SoloEngineID, _ t: ThemeID) -> String {
        switch (engine, t) {
        case (.foundation, .soft): "Apple on-device model"
        case (.foundation, .control): "APPLE FOUNDATION MODELS"
        case (.foundation, .ink): "the model Apple keeps here"
        case (.mlx, .soft): "A model you download"
        case (.mlx, .control): "MLX — LOCAL WEIGHTS"
        case (.mlx, .ink): "a model of your own choosing"
        case (.portal, .soft): "Nous Portal"
        case (.portal, .control): "NOUS PORTAL"
        case (.portal, .ink): "the Portal at Nous"
        }
    }

    func soloEngineDetail(_ engine: SoloEngineID, _ t: ThemeID) -> String {
        switch (engine, t) {
        case (.foundation, .soft):
            "Already on the phone. Nothing to download, and it calls tools properly."
        case (.foundation, .control):
            "ZERO DOWNLOAD. NATIVE TOOL CALLING + GUIDED GENERATION."
        case (.foundation, .ink):
            "Already at hand. Nothing to fetch, and it takes instruction well."
        case (.mlx, .soft):
            "Qwen or Llama, 1–2.3 GB, downloaded once. Needs the MLX build of the app."
        case (.mlx, .control):
            "mlx-community 4-BIT. 1.0–2.3 GB ON DISK. REQUIRES THE TalariaLocal BUILD."
        case (.mlx, .ink):
            "Qwen or Llama, a gigabyte or two, fetched once and kept. Wants the MLX build."
        case (.portal, .soft):
            "Any hosted model, far faster — but the conversation leaves this device."
        case (.portal, .control):
            "HOSTED INFERENCE. FASTEST TIER. CONVERSATION LEAVES THE DEVICE."
        case (.portal, .ink):
            "Any hand you like and swifter by far — but the words travel abroad."
        }
    }

    func soloEngineNote(_ t: ThemeID) -> String {
        switch t {
        case .soft:
            return "Checked just now on this device. Apple’s model is the default because it "
                + "costs no storage and calls tools reliably; the other two are there for when "
                + "it isn’t available or isn’t enough."
        case .control:
            return "PROBED AT OPEN, NOT CACHED. FOUNDATION MODELS IS THE DEFAULT TIER — "
                + "ZERO STORAGE COST, FRAMEWORK-NATIVE TOOL LOOP."
        case .ink:
            return "Asked of the device this moment. Apple’s own is preferred, costing no "
                + "storage and heeding instruction; the others wait for when it will not serve."
        }
    }

    /// The sentence that must never be softened: the default is unavailable
    /// HERE, this is why, and these are the alternatives.
    func soloFoundationUnavailable(_ reason: SoloUnavailableReason, _ t: ThemeID) -> String {
        let cause: String
        switch (reason, t) {
        case (.deviceNotEligible, .soft):
            cause = "This iPhone cannot run Apple’s on-device model — it needs a device that "
                + "supports Apple Intelligence."
        case (.deviceNotEligible, .control):
            cause = "DEVICE NOT ELIGIBLE FOR APPLE INTELLIGENCE."
        case (.deviceNotEligible, .ink):
            cause = "This device cannot carry Apple’s own model; it is not of the right making."
        case (.appleIntelligenceOff, .soft):
            cause = "Apple Intelligence is switched off. Turn it on in Settings → Apple "
                + "Intelligence & Siri and come back."
        case (.appleIntelligenceOff, .control):
            cause = "APPLE INTELLIGENCE DISABLED — ENABLE IN SYSTEM SETTINGS."
        case (.appleIntelligenceOff, .ink):
            cause = "Apple Intelligence sleeps. Wake it in the device’s own settings and return."
        case (.modelNotReady, .soft):
            cause = "Apple’s model is still downloading in the background. It will appear here "
                + "when it is ready."
        case (.modelNotReady, .control):
            cause = "SYSTEM MODEL STILL DOWNLOADING — RETRY LATER."
        case (.modelNotReady, .ink):
            cause = "Apple’s model is still being fetched. It will show itself when it is whole."
        case (.osTooOld, .soft):
            cause = "Apple’s on-device model needs iOS 26 or later. This system is older."
        case (.osTooOld, .control):
            cause = "FOUNDATION MODELS REQUIRES iOS 26+. HOST OS IS OLDER."
        case (.osTooOld, .ink):
            cause = "Apple’s model asks for a newer system than this one."
        default:
            cause = t == .control ? "APPLE'S ON-DEVICE MODEL IS UNAVAILABLE HERE."
                                  : "Apple’s on-device model is not available on this device."
        }
        let fallback: String
        switch t {
        case .soft:
            fallback = " Solo still runs: download a model, sign in to Nous Portal, or connect "
                + "a gateway for the full thing."
        case .control:
            fallback = " SOLO REMAINS AVAILABLE VIA MLX OR PORTAL. GATEWAY GIVES FULL CAPABILITY."
        case .ink:
            fallback = " Solo may still be kept: fetch a model of your own, swear to the Portal, "
                + "or attend a gateway for the whole of it."
        }
        return cause + fallback
    }

    func soloReady(_ t: ThemeID) -> String {
        switch t {
        case .soft: "READY"
        case .control: "AVAILABLE"
        case .ink: "AT HAND"
        }
    }

    func soloReasonTag(_ reason: SoloUnavailableReason, _ t: ThemeID) -> String {
        switch reason {
        case .osTooOld: t == .ink ? "TOO OLD" : "NEEDS iOS 26"
        case .deviceNotEligible: t == .ink ? "NOT OF THIS MAKE" : "NOT SUPPORTED"
        case .appleIntelligenceOff: t == .ink ? "ASLEEP" : "TURNED OFF"
        case .modelNotReady: t == .ink ? "STILL COMING" : "DOWNLOADING"
        case .notBuilt: t == .ink ? "NOT IN THIS COPY" : "NOT IN THIS BUILD"
        case .noModelDownloaded: t == .ink ? "NONE FETCHED" : "NO MODEL YET"
        case .notSignedIn: t == .ink ? "UNSWORN" : "SIGN IN"
        case .unknown: t == .ink ? "UNKNOWN" : "UNAVAILABLE"
        }
    }

    // MARK: Works on device

    func soloWorksHere(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Works on this phone"
        case .control: "ON DEVICE"
        case .ink: "What is kept here"
        }
    }

    /// The three exceptions are named, not glossed. "Works offline" is the
    /// claim people check this screen for, and a tool that reaches the network
    /// or hands control to another app has to be called out here or the privacy
    /// row further down contradicts this one.
    func soloWorksHereNote(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Everything in this column works with the phone in aeroplane mode, with three exceptions: fetching a web page needs the network, running a shortcut leaves Talaria, and the Nous Portal engine sends the conversation off the device."
        case .control: "OFFLINE EXCEPT: web_fetch (NETWORK), shortcuts_run (HANDS OFF TO THE SHORTCUTS APP), PORTAL TIER (CONVERSATION LEAVES THE DEVICE)."
        case .ink: "All of this holds with the device shut away from the world, save three: the fetching of a page must reach abroad, the running of a devising leaves Talaria altogether, and the Portal carries the discourse away."
        }
    }

    func soloWorksHereItems(_ t: ThemeID) -> [String] {
        switch t {
        case .soft:
            return ["Conversation, with the whole history kept on the phone",
                    "A memory note Solo writes and you can edit",
                    "Every tool below, each behind its own switch and its own approval"]
        case .control:
            return ["CHAT — FULL TRANSCRIPT STORED LOCALLY",
                    "MEMORY NOTE — AGENT-WRITTEN, USER-EDITABLE",
                    "TOOLS BELOW — PER-FAMILY SWITCH + APPROVAL GATE"]
        case .ink:
            return ["Discourse, its whole record kept upon this device",
                    "A note of memory, written by the familiar and amended by you",
                    "Each gift below, behind its own leave and its own seal"]
        }
    }

    /// Titles for the seven permission families. Used by BOTH this screen and
    /// Solo settings — one name per family, so a switch and its disclosure can
    /// never call the same thing two things.
    func soloPermTitle(_ permission: SoloPermission, _ t: ThemeID) -> String {
        switch (permission, t) {
        case (.files, .soft): "Files"
        case (.files, .control): "FILES"
        case (.files, .ink): "papers"
        case (.web, .soft): "Web pages"
        case (.web, .control): "WEB FETCH"
        case (.web, .ink): "the wider world"
        case (.calendar, .soft): "Calendar"
        case (.calendar, .control): "CALENDAR"
        case (.calendar, .ink): "the almanac"
        case (.reminders, .soft): "Reminders"
        case (.reminders, .control): "REMINDERS"
        case (.reminders, .ink): "the list of things owed"
        case (.photos, .soft): "Images you share"
        case (.photos, .control): "SHARED IMAGES"
        case (.photos, .ink): "pictures you hand over"
        case (.shortcuts, .soft): "Shortcuts"
        case (.shortcuts, .control): "SHORTCUTS"
        case (.shortcuts, .ink): "your own devisings"
        case (.memory, .soft): "Memory & search"
        case (.memory, .control): "MEMORY + SESSION SEARCH"
        case (.memory, .ink): "memory and recollection"
        }
    }

    // MARK: Needs a gateway

    func soloNeedsGateway(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Needs a gateway"
        case .control: "REQUIRES UPLINK"
        case .ink: "What only the gateway grants"
        }
    }

    func soloNeedsGatewayNote(_ t: ThemeID) -> String {
        switch t {
        case .soft:
            return "None of this is missing by choice — iOS has no fork/exec, so an app cannot "
                + "run a shell or a browser at all. Point Talaria at a Hermes gateway and every "
                + "row here comes back."
        case .control:
            return "NOT OMITTED — STRUCTURALLY IMPOSSIBLE. NO fork/exec IN THE iOS SANDBOX. "
                + "CONNECT A HERMES GATEWAY TO RESTORE ALL OF THE ABOVE."
        case .ink:
            return "None of this is withheld from spite. The device forbids a familiar to summon "
                + "another process at all. Attend a gateway and every line returns."
        }
    }

    func soloNeedsGatewayItems(_ t: ThemeID) -> [(String, String)] {
        switch t {
        case .soft:
            return [("A shell and a real machine",
                     "Running commands, editing a codebase, touching a filesystem that isn’t the phone’s"),
                    ("Browser automation", "Opening pages, filling forms, scraping what it finds"),
                    ("MCP servers", "Every external tool server your gateway has connected"),
                    ("Skills", "The gateway’s skill library, loaded on demand"),
                    ("Cron routines", "Scheduled work that runs while you are asleep"),
                    ("Bot-to-bot handoffs", "One bot @mentioning another and passing the job over"),
                    ("Subagents", "A bot spawning workers to run a task in parallel")]
        case .control:
            return [("SHELL / TERMINAL", "COMMANDS, CODEBASE EDITS, A REAL FILESYSTEM"),
                    ("BROWSER AUTOMATION", "NAVIGATE, FILL, EXTRACT"),
                    ("MCP SERVERS", "EVERY EXTERNAL TOOL SERVER ON THE GATEWAY"),
                    ("SKILLS", "GATEWAY SKILL LIBRARY, LOADED ON DEMAND"),
                    ("CRON ROUTINES", "SCHEDULED RUNS — REQUIRES A LONG-LIVED PROCESS"),
                    ("A2A HANDOFFS", "CROSS-PROFILE @MENTION ROUTING"),
                    ("SUBAGENTS", "PARALLEL WORKERS SPAWNED BY A BOT")]
        case .ink:
            return [("a shell, and a true machine",
                     "commands given, code amended, a filesystem that is not this one"),
                    ("the driving of a browser", "pages opened, forms filled, findings taken"),
                    ("MCP servers", "every foreign instrument your gateway has bound"),
                    ("skills", "the gateway’s library, called upon as needed"),
                    ("routines by the clock", "work performed while you sleep"),
                    ("familiar unto familiar", "one calling another by name and passing the charge"),
                    ("lesser familiars", "workers raised to labour side by side")]
        }
    }

    // MARK: What it costs

    func soloCosts(_ t: ThemeID) -> String {
        switch t {
        case .soft: "What it costs"
        case .control: "COST — THIS DEVICE"
        case .ink: "The price of it"
        }
    }

    func soloCostsNote(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Measured on this device, not estimated for a category of phone. The speed figure is from Talaria’s own runtime research, not a vendor claim."
        case .control: "READ FROM THIS HOST. THROUGHPUT BAND FROM .research/profiles-runtime.md §8.4."
        case .ink: "Taken from this very device, not supposed of its kind. The pace is our own measure, not a maker’s boast."
        }
    }

    func soloCostModel(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Model"
        case .control: "MODEL"
        case .ink: "the hand"
        }
    }

    func soloCostModelFree(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Apple’s model is already here — no download, no storage used"
        case .control: "SYSTEM MODEL RESIDENT — 0 BYTES ADDED"
        case .ink: "Apple’s own is already kept here — nothing fetched, nothing stored"
        }
    }

    func soloCostModelDownload(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Apple’s model isn’t available here, so Solo needs a download or Portal"
        case .control: "SYSTEM MODEL UNAVAILABLE — REQUIRES MLX DOWNLOAD OR PORTAL"
        case .ink: "Apple’s own will not serve here; a fetched model or the Portal is wanted"
        }
    }

    func soloCostDownload(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Downloads that fit"
        case .control: "DOWNLOADS THAT FIT"
        case .ink: "what may be fetched"
        }
    }

    func soloCostNoneFit(_ t: ThemeID) -> String {
        switch t {
        case .soft: "None — this device hasn’t the memory for any of the catalogue"
        case .control: "NONE — INSUFFICIENT PHYSICAL MEMORY FOR THE CATALOGUE"
        case .ink: "None — this device has not the room for any of them"
        }
    }

    func soloCostDevice(_ t: ThemeID) -> String {
        switch t {
        case .soft: "This device"
        case .control: "HOST"
        case .ink: "this device"
        }
    }

    func soloDeviceLine(_ profile: SoloDeviceProfile, _ t: ThemeID) -> String {
        let memory = AppModel.formattedBytes(Int64(profile.physicalMemoryBytes))
        switch t {
        case .soft: return "\(profile.machine) · \(memory) memory · \(profile.processorCount) cores"
        case .control: return "\(profile.machine.uppercased()) · \(memory) RAM · \(profile.processorCount) CPU"
        case .ink: return "\(profile.machine) · \(memory) of memory · \(profile.processorCount) cores"
        }
    }

    func soloCostSpeed(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Expected speed"
        case .control: "DECODE THROUGHPUT"
        case .ink: "the pace of it"
        }
    }

    func soloSpeedLine(low: Int, high: Int, _ t: ThemeID) -> String {
        switch t {
        case .soft:
            return "About \(low)–\(high) words a second once it starts. Long questions take a "
                + "few seconds before the first word, because the whole prompt is read first."
        case .control:
            return "\(low)–\(high) tok/s SUSTAINED DECODE. PREFILL DOMINATES TTFT ON LONG PROMPTS."
        case .ink:
            return "Some \(low) to \(high) words a second once begun. A long question waits a "
                + "moment first, the whole of it being read before a word is said."
        }
    }

    func soloCostBattery(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Battery & heat"
        case .control: "THERMAL / POWER"
        case .ink: "warmth and wear"
        }
    }

    func soloBatteryLine(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Thinking on the phone warms it and drains the battery. Solo is built for short exchanges, not for agent runs that last minutes."
        case .control: "SUSTAINED DECODE THROTTLES AND DRAINS. SCOPED TO SHORT EXCHANGES, NOT MULTI-MINUTE LOOPS."
        case .ink: "Thought upon the device warms it and spends its charge. Solo is meant for short exchanges, not for long labours."
        }
    }

    func soloCostPrivacy(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Privacy"
        case .control: "EGRESS"
        case .ink: "what is kept close"
        }
    }

    func soloPrivacyLine(_ t: ThemeID) -> String {
        switch t {
        case .soft: "On the Apple or downloaded-model tiers nothing leaves the phone — except a web page you approve, or a shortcut you approve. Portal sends the conversation to Nous."
        case .control: "ON-DEVICE TIERS: ZERO EGRESS EXCEPT APPROVED web_fetch / shortcuts_run. PORTAL TIER: CONVERSATION LEAVES."
        case .ink: "By Apple’s hand or your own fetched model, nothing departs — save a page you allow, or a devising you allow. The Portal carries the whole discourse abroad."
        }
    }

    // MARK: Footer

    func soloContinue(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Set up Solo"
        case .control: "CONFIGURE SOLO"
        case .ink: "make ready the solitary"
        }
    }

    func soloConnectGateway(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Connect a gateway instead"
        case .control: "CONNECT A GATEWAY"
        case .ink: "attend a gateway instead"
        }
    }

    func soloFooterNote(_ t: ThemeID) -> String {
        switch t {
        case .soft: "This screen stays in Solo settings. Nothing here is a one-time notice you have to remember."
        case .control: "PERSISTENT — REACHABLE FROM SOLO SETTINGS. NOT A ONE-SHOT MODAL."
        case .ink: "This page keeps its place in Solo’s settings. It is no notice shown once and taken away."
        }
    }
}
