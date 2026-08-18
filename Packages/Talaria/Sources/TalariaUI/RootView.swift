import Combine
import SwiftUI
import TalariaKit
import TalariaTheme

// The screen graph, ported from the prototype's flat `state.screen` switch:
//
//   onboarding (z35)
//   ── roster ⇄ chat (push) ── bot sheet / routines (push) / voice (z20)
//   ── activity / approvals / agent inbox / artifacts (tabs)
//   ── connections, new-bot sheet, search palette (z48)
//   push banner (z40) · control-theme scanlines (z60) · theme-swap animation
//
// TalariaRootView(model:) is the app target's single mount point: it applies
// the theme background, hosts every overlay and sheet, runs the demo push
// cycle, and wires the push/live-activity controllers to the model.

public struct TalariaRootView: View {
    private let model: AppModel

    // Presentation state the model doesn't own (the model keeps routing state
    // other screens drive: selectedTab, openBotID, showOnboarding).
    @State private var showSearch = false
    @State private var showCreate = false
    @State private var showProfile = false
    @State private var showVoice = false
    @State private var showConnections = false
    @State private var routinesBotID: String?

    // Demo push banner cycle.
    @State private var activeBanner: BannerPush?

    // Theme-swap flash (tSwapX/tSwapY).
    @State private var themeSwapDim = false

    public init(model: AppModel) {
        self.model = model
    }

    private var theme: ThemePack { model.theme.pack }
    private var copy: CopyPack { model.theme.copy }

    /// The tab bar lives only on the five tab screens.
    private var showsTabBar: Bool {
        model.openBotID == nil && routinesBotID == nil && !showConnections
            && !showVoice && !model.showOnboarding
    }

    /// The prototype suppresses banner pushes on voice / onboarding / search.
    private var bannersAllowed: Bool {
        model.mode == .demo && !model.showOnboarding && !showSearch && !showVoice
    }

    // MARK: - Body

    public var body: some View {
        ZStack {
            theme.bg
                .ignoresSafeArea()
                .animation(.easeInOut(duration: 0.45), value: theme.id)

            screenGraph
                .opacity(themeSwapDim ? 0.3 : 1)
                .scaleEffect(themeSwapDim ? 0.982 : 1)

            if theme.id == .control {
                ScanlineOverlay()
            }
        }
        .preferredColorScheme(theme.statusBarDark ? .dark : .light)
        .tint(theme.accent)
        .sheet(isPresented: $showProfile) {
            if let id = model.openBotID {
                BotSheetView(model: model, botID: id)
            }
        }
        .sheet(isPresented: $showCreate) {
            CreateBotView(model: model)
        }
        .onChange(of: model.theme.themeID) { runThemeSwapAnimation() }
        .onChange(of: model.openBotID) {
            // Leaving chat tears down everything stacked on it.
            if model.openBotID == nil {
                routinesBotID = nil
                showVoice = false
                showProfile = false
            }
        }
        .onAppear { wireUp() }
        .onOpenURL { url in
            _ = PushCoordinator.shared.handleDeepLink(url)
        }
        .onReceive(NotificationCenter.default.publisher(for: .talariaOpenConnections)) { _ in
            // talaria://connections deep links and gateway pushes; this view
            // owns the Connections navigation push.
            guard !showConnections else { return }
            withAnimation(pushAnimation) { showConnections = true }
        }
        .task { await runDemoPushCycle() }
    }

    // MARK: - Screen graph

    private var screenGraph: some View {
        ZStack {
            tabContent

            // Chat, pushed over the roster (any tab can deep-link into it).
            if let botID = model.openBotID {
                ZStack {
                    theme.bg.ignoresSafeArea()
                    ChatView(model: model, botID: botID,
                             onOpenProfile: { showProfile = true },
                             onRoutines: { withAnimation(pushAnimation) { routinesBotID = botID } },
                             onVoice: { withAnimation(sheetAnimation) { showVoice = true } })
                }
                .transition(pushTransition)
            }

            // Routines, pushed from chat.
            if let botID = routinesBotID {
                ZStack {
                    theme.bg.ignoresSafeArea()
                    RoutinesView(model: model, botID: botID,
                                 onBack: { withAnimation(pushAnimation) { routinesBotID = nil } })
                }
                .transition(pushTransition)
            }

            // Connections, pushed from the net chip / activity / search.
            if showConnections {
                ZStack {
                    theme.bg.ignoresSafeArea()
                    ConnectionsView(model: model,
                                    onBack: { withAnimation(pushAnimation) { showConnections = false } })
                }
                .transition(pushTransition)
            }

            // Tab bar (z15).
            if showsTabBar {
                VStack(spacing: 0) {
                    Spacer()
                    TalariaTabBar(theme: theme, copy: copy,
                                  selected: model.selectedTab,
                                  badgeCount: model.pendingApprovalCount()) { tab in
                        withAnimation(.easeOut(duration: 0.3)) {
                            model.selectedTab = tab
                        }
                    }
                }
                .transition(.opacity)
            }

            // Search palette (z48–49).
            if showSearch {
                SearchPalette(model: model, isPresented: $showSearch) { action in
                    switch action {
                    case .newBot: showCreate = true
                    case .addGateway: withAnimation(pushAnimation) { showConnections = true }
                    }
                }
                .transition(.opacity)
                .zIndex(48)
            }

            // Voice overlay (z20 — above chat, below banner).
            if showVoice, let botID = model.openBotID {
                VoiceView(model: model, botID: botID, isPresented: $showVoice)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(20)
            }

            // Push banner (z40).
            if let banner = activeBanner {
                VStack {
                    bannerView(banner)
                    Spacer()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(40)
            }

            // Onboarding cover (z35, above tabs/banner-free zone).
            if model.showOnboarding {
                OnboardingView(model: model)
                    .transition(.opacity)
                    .zIndex(50)
            }
        }
        .animation(.easeOut(duration: 0.32), value: model.openBotID)
        .animation(.easeOut(duration: 0.4), value: model.showOnboarding)
    }

    @ViewBuilder private var tabContent: some View {
        Group {
            switch model.selectedTab {
            case .home:
                RosterView(model: model,
                           onSearch: { showSearch = true },
                           onCreate: { showCreate = true },
                           onConnections: { withAnimation(pushAnimation) { showConnections = true } })
            case .activity:
                ActivityView(model: model,
                             onOpenConnections: { withAnimation(pushAnimation) { showConnections = true } })
            case .approvals:
                ApprovalsView(model: model)
            case .a2a:
                AgentInboxView(model: model)
            case .artifacts:
                ArtifactsView(model: model)
            }
        }
        .id(model.selectedTab)
        .transition(.opacity)
    }

    // MARK: - Transitions

    private var pushTransition: AnyTransition {
        .move(edge: .trailing).combined(with: .opacity)
    }

    private var pushAnimation: Animation { .easeOut(duration: 0.32) }
    private var sheetAnimation: Animation { .easeOut(duration: 0.36) }

    // MARK: - Theme swap (tSwapX / tSwapY)

    private func runThemeSwapAnimation() {
        var snap = Transaction()
        snap.disablesAnimations = true
        withTransaction(snap) { themeSwapDim = true }
        withAnimation(.easeOut(duration: 0.5)) { themeSwapDim = false }
    }

    // MARK: - Wiring

    private func wireUp() {
        // Relaunch in demo mode after onboarding once completed earlier.
        if model.mode == .demo && model.bots.isEmpty && !model.showOnboarding {
            model.enterDemoMode()
        }
        PushCoordinator.shared.configure(model: model)
        LiveActivityController.shared.attach(to: model)
    }

    // MARK: - Demo push banners

    /// The prototype's `cycleBanner`: first banner 8s in, then one every ~14s,
    /// visible for 4.8s. Suppressed during onboarding, search and voice; the
    /// cycle only runs against demo data.
    private func runDemoPushCycle() async {
        try? await Task.sleep(for: .seconds(8))
        var index = 0
        while !Task.isCancelled {
            presentDemoBanner(BannerPush.demoCycle[index % BannerPush.demoCycle.count])
            index += 1
            try? await Task.sleep(for: .seconds(14))
            if Task.isCancelled { return }
        }
    }

    private func presentDemoBanner(_ push: BannerPush) {
        guard bannersAllowed else { return }
        withAnimation(.spring(response: 0.5, dampingFraction: 0.72)) {
            activeBanner = push
        }
        let shownID = push.id
        Task {
            try? await Task.sleep(for: .seconds(4.8))
            if activeBanner?.id == shownID {
                withAnimation(.easeIn(duration: 0.25)) { activeBanner = nil }
            }
        }
    }

    private func bannerView(_ banner: BannerPush) -> some View {
        let pendingApproval = banner.approvalID.flatMap { id in
            model.approvals.first { $0.id == id }
        }
        return PushBanner(
            theme: theme, copy: copy, push: banner,
            bot: banner.botID == "gateway" ? nil : model.bot(banner.botID),
            showsApprovalActions: banner.kind == .approval && pendingApproval != nil,
            onTap: { routeBanner(banner) },
            onApprove: {
                if let approval = pendingApproval {
                    ApprovalOutcomes.shared.resolve(approval, approve: true, in: model)
                }
                withAnimation(.easeIn(duration: 0.25)) { activeBanner = nil }
            },
            onLater: {
                withAnimation(.easeIn(duration: 0.25)) { activeBanner = nil }
            })
    }

    /// bannerGo — approval → Approvals, gateway → Connections, else that
    /// bot's chat.
    private func routeBanner(_ banner: BannerPush) {
        withAnimation(.easeIn(duration: 0.2)) { activeBanner = nil }
        switch banner.kind {
        case .approval:
            withAnimation(pushAnimation) {
                model.openBotID = nil
                showConnections = false
                model.selectedTab = .approvals
            }
        case .gateway:
            withAnimation(pushAnimation) { showConnections = true }
        default:
            withAnimation(pushAnimation) {
                showConnections = false
                model.selectedTab = .home
                model.openBotID = banner.botID
            }
        }
    }
}

// MARK: - Scanline overlay (control)

/// The CRT scanline wash over everything in the control theme — 1pt lines on
/// a 3pt pitch at 1.6% white, hit-testing disabled (z60).
private struct ScanlineOverlay: View {
    var body: some View {
        Canvas { context, size in
            var y: CGFloat = 0
            while y < size.height {
                context.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1)),
                             with: .color(Color.white.opacity(0.016)))
                y += 3
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}
