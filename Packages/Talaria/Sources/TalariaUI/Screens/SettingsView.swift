import SwiftUI
import TalariaKit
import TalariaTheme

// Settings — roadmap Phase 2.
//
// Desktop ships 202 discrete settings controls; this screen is deliberately not
// a port of them. The settled decision is that raw config and env editing does
// not belong on a phone — "an agent can be asked to make config changes, that
// doesn't need to live on device" — so what is here is the set a phone-first
// operator reaches for, and everything else is an honest pointer at desktop
// (with the reminder that asking a bot is usually faster than either).
//
// Sections, in the roadmap's order:
//   Gateways      — the connection registry, merged from Connections.
//   Appearance    — the three packs, text size, motion.
//   Notifications ┐
//   Models        ├ owned by Screens/Settings/, embedded directly below.
//   Voice         ┘
//   Privacy & data— measured local storage, and the verbs that undo it.
//   About         — versions, gateway contract, copyable diagnostics, links.
//
// Reached from the roster header and from Connections. Neither of those owns
// the screen graph, so both go through `AppModel.requestSettings()`, whose
// notification lands on `View.talariaSettings(model:)` at the bottom of this
// file — the same shape `requestCapabilities` already uses.

public struct SettingsView: View {
    private let model: AppModel
    private let onBack: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    public init(model: AppModel, onBack: (() -> Void)? = nil) {
        self.model = model
        self.onBack = onBack
    }

    private var theme: ThemePack { model.theme.pack }
    private var copy: CopyPack { model.theme.copy }
    private var reducedMotion: Bool {
        model.settings.prefersReducedMotion(system: systemReduceMotion)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    GatewaySettingsSection(model: model, onAddGateway: addGateway)
                        .settingsEntrance(delay: 0, reduced: reducedMotion)

                    AppearanceSettingsSection(model: model)
                        .settingsEntrance(delay: 0.05, reduced: reducedMotion)

                    // Owned by Screens/Settings/*, referenced directly: they are
                    // in this module, and each already renders its own honest
                    // empty/degraded state, so there is nothing for an indirection
                    // to decide.
                    NotificationSettingsSection(model: model)
                        .settingsEntrance(delay: 0.1, reduced: reducedMotion)

                    ModelSettingsSection(model: model)
                        .settingsEntrance(delay: 0.13, reduced: reducedMotion)

                    VoiceSettingsSection(model: model)
                        .settingsEntrance(delay: 0.16, reduced: reducedMotion)

                    // Solo sits above Privacy on purpose: it is the one section
                    // here that is *not* about the gateway, and a person looking
                    // for "does this work without a server" looks in Settings.
                    SoloSettingsSection(model: model)
                        .settingsEntrance(delay: 0.2, reduced: reducedMotion)

                    PrivacySettingsSection(model: model)
                        .settingsEntrance(delay: 0.24, reduced: reducedMotion)

                    AboutSettingsSection(model: model)
                        .settingsEntrance(delay: 0.28, reduced: reducedMotion)

                    DesktopPointerSection(theme: theme, copy: copy)
                        .settingsEntrance(delay: 0.32, reduced: reducedMotion)
                }
                .padding(.horizontal, 18)
                .padding(.top, 4)
                .padding(.bottom, 60)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.bg)
        // The picker in Appearance is live because the screen it lives on
        // adopts its own setting.
        .talariaTextSize(model)
        .task {
            // `desktop_contract` only ever rides a session.info payload, so the
            // watcher has to be listening before About can report it.
            model.attachSettingsDiagnostics()
            await model.refreshGatewayStatus()
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Button {
                if let onBack { onBack() } else { dismiss() }
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
                    Text(copy.settingsKicker(theme.id))
                        .font(theme.mono(9.5, weight: .semibold))
                        .tracking(2)
                        .foregroundStyle(theme.id == .ink ? theme.sub : theme.accent)
                }
                Text(copy.settingsTitle(theme.id))
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

    /// Connections owns the probe → PKCE sign-in flow and Hermes Cloud
    /// discovery; duplicating either here would be two sign-in paths to keep in
    /// step. Leave, then ask for that screen.
    private func addGateway() {
        if let onBack { onBack() } else { dismiss() }
        NotificationCenter.default.post(name: .talariaOpenConnections, object: nil)
    }
}

// MARK: - About & diagnostics

/// Versions, the gateway's contract, and one copyable block for a bug report.
/// Every row is either a fact the app knows or an honest dash — nothing here is
/// inferred, and a gateway that has not answered yet says so.
struct AboutSettingsSection: View {
    let model: AppModel

    @State private var didCopy = false

    private var theme: ThemePack { model.theme.pack }
    private var copy: CopyPack { model.theme.copy }

    private static let repoURL = URL(string: "https://github.com/0xrichyrich/talaria")!
    private static let docsURL = URL(string: "https://github.com/0xrichyrich/talaria/tree/main/app/docs")!
    private static let upstreamURL = URL(string: "https://github.com/NousResearch/hermes-agent")!

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsSection(theme: theme, title: copy.settingsAboutSec(theme.id), footnote: nil) {
                SettingsGroup(theme: theme) {
                    SettingsRow(theme: theme, title: copy.settingsAppVersion(theme.id),
                                value: AppModel.appVersionString)
                    SettingsRow(theme: theme, title: copy.settingsPlatform(theme.id),
                                value: AppModel.platformString,
                                isLast: gatewayRows.isEmpty)
                    ForEach(Array(gatewayRows.enumerated()), id: \.offset) { index, row in
                        SettingsRow(theme: theme, title: row.title,
                                    value: row.value, valueTone: row.tone,
                                    isLast: index == gatewayRows.count - 1)
                    }
                }
            }

            SettingsSection(theme: theme, title: copy.settingsDiagnosticsSec(theme.id),
                            footnote: copy.settingsDiagnosticsNote(theme.id)) {
                SettingsGroup(theme: theme) {
                    SettingsActionRow(theme: theme,
                                      title: didCopy ? copy.settingsCopied(theme.id)
                                                     : copy.settingsCopyDiagnostics(theme.id),
                                      isLast: true) {
                        copyToPasteboard(model.diagnosticsSummary())
                        didCopy = true
                        Task { @MainActor in
                            try? await Task.sleep(for: .seconds(2))
                            didCopy = false
                        }
                    }
                }
            }

            SettingsSection(theme: theme, title: copy.settingsLinksSec(theme.id), footnote: nil) {
                SettingsGroup(theme: theme) {
                    SettingsLinkRow(theme: theme, title: copy.settingsRepo(theme.id),
                                    subtitle: Self.repoURL.host(), url: Self.repoURL)
                    SettingsLinkRow(theme: theme, title: copy.settingsDocs(theme.id),
                                    subtitle: copy.settingsDocsNote(theme.id), url: Self.docsURL)
                    SettingsLinkRow(theme: theme, title: copy.settingsUpstream(theme.id),
                                    subtitle: copy.settingsUpstreamNote(theme.id),
                                    url: Self.upstreamURL, isLast: true)
                }
            }
        }
    }

    private struct AboutRow {
        var title: String
        var value: String
        var tone: Color?
    }

    /// Gateway facts, only for a gateway that exists. `desktop_contract` is
    /// reported as "—" until a session.info has carried one, because guessing a
    /// contract version is how a client ends up speaking the wrong protocol.
    private var gatewayRows: [AboutRow] {
        guard let gateway = model.liveGateway else { return [] }
        var rows: [AboutRow] = [
            AboutRow(title: copy.settingsGateway(theme.id),
                     value: ConnectionRegistry.address(for: gateway), tone: nil),
            AboutRow(title: copy.settingsLink(theme.id),
                     value: model.isOffline ? copy.linkDownTitle(theme.id)
                                            : copy.connActive(theme.id),
                     tone: model.isOffline ? theme.danger : theme.ok),
        ]
        if let diagnostics = model.liveGatewayDiagnostics {
            if let version = diagnostics.version, !version.isEmpty {
                rows.append(AboutRow(title: copy.settingsGatewayVersion(theme.id),
                                     value: "v\(version)", tone: nil))
            }
            rows.append(AboutRow(title: copy.settingsAuthMode(theme.id),
                                 value: copy.authModeLabel(diagnostics.authMode, theme.id),
                                 tone: nil))
            if let ping = diagnostics.pingMS {
                rows.append(AboutRow(title: copy.settingsPing(theme.id),
                                     value: "\(ping)ms", tone: nil))
            }
        }
        rows.append(AboutRow(title: copy.settingsContract(theme.id),
                             value: model.gatewayDesktopContract.map { "v\($0)" } ?? "—",
                             tone: nil))
        if let status = model.gatewayStatus {
            rows.append(AboutRow(title: copy.settingsHealth(theme.id),
                                 value: status.overall,
                                 tone: status.overall == "ok" ? theme.ok : theme.warn))
            rows.append(AboutRow(title: copy.settingsActiveAgents(theme.id),
                                 value: "\(status.activeAgents)", tone: nil))
        }
        return rows
    }
}

// MARK: - Managed on desktop

/// The honest end of the screen. These exist on desktop and are deliberately
/// not on the phone; naming them is better than letting somebody hunt.
struct DesktopPointerSection: View {
    let theme: ThemePack
    let copy: CopyPack

    var body: some View {
        SettingsSection(theme: theme,
                        title: copy.settingsDesktopSec(theme.id),
                        footnote: copy.settingsAskABot(theme.id)) {
            SettingsGroup(theme: theme) {
                let items = copy.settingsDesktopItems(theme.id)
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    SettingsRow(theme: theme, title: item.0, subtitle: item.1,
                                isLast: index == items.count - 1)
                }
            }
        }
    }
}

// MARK: - Presentation

/// Hosts the Settings screen for whoever owns the screen graph. Mount once,
/// next to the other overlays:
///
///     TalariaRootView(model: model)      // or the root ZStack inside it
///         .talariaSettings(model: model)
///
/// It listens for `AppModel.requestSettings()`, so the roster header and
/// Connections only have to call that — neither needs a binding threaded
/// through it, and neither has to know Settings exists.
public struct TalariaSettingsPresenter: ViewModifier {
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
                        SettingsView(model: model) {
                            withAnimation(pushAnimation) { isPresented = false }
                        }
                    }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                    .zIndex(14)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .talariaOpenSettings)) { _ in
                guard !isPresented else { return }
                withAnimation(pushAnimation) { isPresented = true }
            }
            .onReceive(NotificationCenter.default.publisher(for: .talariaOpenConnections)) { _ in
                // Settings hands the add-gateway flow to Connections; it must
                // not stay stacked on top of the screen it just asked for.
                guard isPresented else { return }
                withAnimation(pushAnimation) { isPresented = false }
            }
            .onChange(of: model.showOnboarding) { _, showing in
                // "Delete local data" ends in onboarding, and onboarding is the
                // topmost surface in the app. An overlay mounted above the
                // screen graph would otherwise hide it.
                if showing, isPresented { isPresented = false }
            }
    }
}

public extension View {
    /// Mount the Settings screen on this view tree.
    func talariaSettings(model: AppModel) -> some View {
        modifier(TalariaSettingsPresenter(model: model))
    }
}

// MARK: - Copy

extension CopyPack {

    func settingsKicker(_ t: ThemeID) -> String {
        switch t {
        case .soft: "TALARIA // DEVICE"
        case .control: "DEVICE CONTROL"
        case .ink: "OF THIS DEVICE"
        }
    }

    func settingsTitle(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Settings"
        case .control: "Settings"
        case .ink: "The Settings"
        }
    }

    /// VoiceOver label for the back chevron. Not `cancel` — leaving Settings
    /// abandons nothing, every control here has already taken effect.
    func settingsBack(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Back"
        case .control: "BACK"
        case .ink: "return"
        }
    }

    // MARK: About

    func settingsAboutSec(_ t: ThemeID) -> String {
        switch t {
        case .soft: "About"
        case .control: "BUILD & LINK"
        case .ink: "OF THIS COPY"
        }
    }

    func settingsAppVersion(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Talaria"
        case .control: "TALARIA BUILD"
        case .ink: "this copy"
        }
    }

    func settingsPlatform(_ t: ThemeID) -> String {
        switch t {
        case .soft: "System"
        case .control: "HOST OS"
        case .ink: "the machine"
        }
    }

    func settingsGateway(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Gateway"
        case .control: "UPLINK"
        case .ink: "the way"
        }
    }

    func settingsGatewayVersion(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Gateway version"
        case .control: "GATEWAY BUILD"
        case .ink: "its making"
        }
    }

    func settingsAuthMode(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Sign-in"
        case .control: "AUTH MODE"
        case .ink: "the seal"
        }
    }

    func settingsPing(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Round trip"
        case .control: "RTT"
        case .ink: "the distance"
        }
    }

    func settingsLink(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Link"
        case .control: "LINK STATE"
        case .ink: "the way's state"
        }
    }

    /// The backend contract this gateway speaks (`desktop_contract`), which is
    /// what tells a client which RPC shapes it may use.
    func settingsContract(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Backend contract"
        case .control: "DESKTOP CONTRACT"
        case .ink: "the covenant"
        }
    }

    func settingsHealth(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Gateway health"
        case .control: "OVERALL"
        case .ink: "its humour"
        }
    }

    func settingsActiveAgents(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Active agents"
        case .control: "ACTIVE AGENTS"
        case .ink: "familiars afoot"
        }
    }

    // MARK: Diagnostics

    func settingsDiagnosticsSec(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Diagnostics"
        case .control: "DIAGNOSTICS"
        case .ink: "THE ACCOUNT"
        }
    }

    func settingsDiagnosticsNote(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Versions, link state and the gateway's contract as plain text — paste it into a bug report. No tokens, no message contents."
        case .control: "PLAIN-TEXT SNAPSHOT: BUILD, LINK, CONTRACT. NO CREDENTIALS, NO MESSAGE CONTENT."
        case .ink: "A plain account of build, way and covenant, fit to be copied into a report. No seals and no words of the familiars."
        }
    }

    func settingsCopyDiagnostics(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Copy diagnostics"
        case .control: "COPY SNAPSHOT"
        case .ink: "copy the account"
        }
    }

    func settingsCopied(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Copied ✓"
        case .control: "COPIED ✓"
        case .ink: "copied ✓"
        }
    }

    // MARK: Links

    func settingsLinksSec(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Links"
        case .control: "REFERENCES"
        case .ink: "WHERE TO READ FURTHER"
        }
    }

    func settingsRepo(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Source code"
        case .control: "SOURCE"
        case .ink: "the source"
        }
    }

    func settingsDocs(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Documentation"
        case .control: "DOCS"
        case .ink: "the papers"
        }
    }

    func settingsDocsNote(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Roadmap, parity audits and protocol notes"
        case .control: "ROADMAP · PARITY · PROTOCOL"
        case .ink: "roadmap, parity and the protocol"
        }
    }

    func settingsUpstream(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Hermes Agent"
        case .control: "HERMES AGENT"
        case .ink: "Hermes itself"
        }
    }

    func settingsUpstreamNote(_ t: ThemeID) -> String {
        switch t {
        case .soft: "The gateway and agent runtime this app talks to"
        case .control: "GATEWAY + AGENT RUNTIME"
        case .ink: "the runtime this app attends"
        }
    }

    // MARK: Managed on desktop

    func settingsDesktopSec(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Managed on desktop"
        case .control: "NOT ON DEVICE"
        case .ink: "KEPT ELSEWHERE"
        }
    }

    /// Named rather than hidden: these are real desktop settings that are
    /// deliberately absent here, and a person hunting for them deserves to be
    /// told where they went.
    func settingsDesktopItems(_ t: ThemeID) -> [(String, String)] {
        switch t {
        case .soft:
            return [("Environment variables", "hermes config env — on the machine running the gateway"),
                    ("config.yaml", "Provider keys, toolsets and defaults, edited in place"),
                    ("Storage paths", "Where profiles, sessions and skills live on disk"),
                    ("Update channel", "Gateway updates are applied where the gateway runs")]
        case .control:
            return [("ENV VARS", "HERMES CONFIG ENV — GATEWAY HOST ONLY"),
                    ("CONFIG.YAML", "PROVIDER KEYS / TOOLSETS / DEFAULTS"),
                    ("STORAGE PATHS", "PROFILE, SESSION AND SKILL DIRECTORIES"),
                    ("UPDATE CHANNEL", "APPLIED ON THE GATEWAY HOST")]
        case .ink:
            return [("the environment", "set where the gateway itself runs"),
                    ("the config", "keys, gifts and defaults, written in place"),
                    ("the storage", "where natures, audiences and gifts are kept"),
                    ("the updates", "applied at the gateway, not here")]
        }
    }

    func settingsAskABot(_ t: ThemeID) -> String {
        switch t {
        case .soft: "A phone is a poor YAML editor — but you can just ask a bot. “Set my default model to Hermes 4 405B” does the same job from the chat you are already in."
        case .control: "NO RAW CONFIG EDITING ON DEVICE BY DESIGN. ASK AN AGENT INSTEAD: \"SET DEFAULT MODEL TO HERMES-4-405B\"."
        case .ink: "A phone makes a poor scriptorium. Ask a familiar instead — “set my default model to Hermes 4” is asked and done from the chat you already keep."
        }
    }
}
