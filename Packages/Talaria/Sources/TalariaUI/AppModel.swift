import SwiftUI
import TalariaKit
import TalariaTheme

// The app's observable state tree. Two modes:
// - demo: the onboarding "Explore with demo data" path — canned roster,
//   scripted replies, simulated pushes. Mirrors the design prototype and
//   gives App Review the full experience without a gateway.
// - live: bound to a GatewayClient; RPCs + events drive the same state.

public enum AppMode: Sendable, Equatable {
    case demo
    case live
}

/// Per-bot chat state.
@MainActor
@Observable
public final class ChatState {
    public var messages: [ChatMessage]
    public var isTyping: Bool = false
    /// Runtime session id (live mode).
    public var sessionID: String?
    /// Durable session key for resume-after-reconnect.
    public var storedSessionID: String?
    public var usage: Usage?
    public var yolo: Bool = false

    public init(messages: [ChatMessage] = []) {
        self.messages = messages
    }
}

@MainActor
@Observable
public final class AppModel {
    public var mode: AppMode = .demo
    public let theme = ThemeManager()

    // Roster + surfaces
    public var bots: [Bot] = []
    public var approvals: [Approval] = []
    public var activity: [ActivityDay] = []
    public var agentInbox: [A2AMessage] = []
    public var routines: [Routine] = []
    public var artifacts: [Artifact] = []
    public var connections: [GatewayConnection] = []
    public var notificationPrefs: [NotificationPref] = []
    public var chats: [String: ChatState] = [:]
    public var memory: [String: BotMemory] = [:]
    public var sessions: [String: [SessionSummary]] = [:]
    public var contextMeter: [ContextSegment] = []
    public var models: [String] = []
    public var skills: [String] = []

    // Navigation
    public var selectedTab: CopyPack.Tab = .home
    public var openBotID: String?
    public var showOnboarding: Bool
    public var isOffline: Bool = false
    /// Messages composed while unreachable; flushed on reconnect.
    public var composeQueue: [(botID: String, text: String)] = []

    // Live mode
    public var client: GatewayClient?

    public init() {
        showOnboarding = !UserDefaults.standard.bool(forKey: "talaria-onboarded")
    }

    // MARK: - Demo mode

    /// True while the canned demo world is loaded. Drives the exit affordance
    /// in Connections and the flush when a real gateway connects.
    public internal(set) var demoDataLoaded = false

    /// UserDefaults key remembering that demo was the user's explicit choice,
    /// so relaunches restore the same world.
    public static let demoChoiceKey = "talaria-demo-chosen"

    public func enterDemoMode() {
        mode = .demo
        demoDataLoaded = true
        UserDefaults.standard.set(true, forKey: Self.demoChoiceKey)
        bots = DemoData.bots
        approvals = DemoData.approvals
        activity = DemoData.activity
        agentInbox = DemoData.agentInbox
        routines = DemoData.routines
        artifacts = DemoData.artifacts
        connections = DemoData.connections
        notificationPrefs = DemoData.notificationPrefs
        memory = DemoData.memory
        sessions = DemoData.sessions
        contextMeter = DemoData.contextMeter
        models = DemoData.models
        skills = DemoData.skills
        chats = DemoData.chats.mapValues { ChatState(messages: $0) }
    }

    public func completeOnboarding() {
        UserDefaults.standard.set(true, forKey: "talaria-onboarded")
        showOnboarding = false
    }

    /// Leave the demo world for the honest empty state (notification prefs
    /// are real device settings and survive; saved gateways re-appear from
    /// the registry).
    public func exitDemoMode() {
        flushDemoWorld()
        connections = ConnectionRegistry.shared.rows
    }

    /// Re-run onboarding from the first step.
    public func resetOnboarding() {
        UserDefaults.standard.removeObject(forKey: "talaria-onboarded")
        showOnboarding = true
    }

    /// Launch restore, in order of intent: reconnect the most recent saved
    /// gateway; else reload the demo world if that was the explicit choice;
    /// else stay on the honest empty state.
    public func restoreWorldAtLaunch() async {
        guard mode == .demo, bots.isEmpty, !showOnboarding else { return }
        let registry = ConnectionRegistry.shared
        for gateway in registry.saved {
            guard let base = gateway.baseURL,
                  let credential = registry.credential(for: gateway) else { continue }
            do {
                try await connectGateway(baseURL: base, credential: credential)
                return
            } catch {
                registry.noteState(.offline, forURL: base)
            }
        }
        if UserDefaults.standard.bool(forKey: Self.demoChoiceKey) {
            enterDemoMode()
        } else {
            connections = registry.rows
        }
    }

    /// Drop every demo-populated surface. Called on exit and when a real
    /// gateway connection replaces the demo world.
    func flushDemoWorld() {
        demoDataLoaded = false
        UserDefaults.standard.removeObject(forKey: Self.demoChoiceKey)
        bots = []
        approvals = []
        activity = []
        agentInbox = []
        routines = []
        artifacts = []
        chats = [:]
        memory = [:]
        sessions = [:]
        contextMeter = []
        composeQueue = []
        openBotID = nil
        selectedTab = .home
    }

    // MARK: - Shared actions (mode-dispatched; live paths in AppModel+Live)

    public func chat(for botID: String) -> ChatState {
        if let existing = chats[botID] { return existing }
        let fresh = ChatState()
        chats[botID] = fresh
        return fresh
    }

    public func bot(_ id: String) -> Bot? {
        bots.first { $0.id == id }
    }

    public func send(text: String, to botID: String) {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let chat = chat(for: botID)
        chat.messages.append(ChatMessage(author: .user, time: Self.clock(), text: text))

        if isOffline {
            composeQueue.append((botID, text))
            return
        }
        switch mode {
        case .demo: demoReply(botID: botID, chat: chat)
        case .live: liveSend(text: text, botID: botID, chat: chat)
        }
    }

    public func resolveApproval(_ approval: Approval, approve: Bool) {
        approvals.removeAll { $0.id == approval.id }
        if case .live = mode {
            liveResolveApproval(approval, approve: approve)
        } else {
            let chat = chat(for: approval.botID)
            chat.messages.append(ChatMessage(
                author: .system,
                text: approve ? "Approved · \(approval.title)" : "Denied · \(approval.title)"))
        }
    }

    public func toggleRoutine(_ routine: Routine) {
        guard let idx = routines.firstIndex(where: { $0.id == routine.id }) else { return }
        routines[idx].isOn.toggle()
        if case .live = mode { liveToggleRoutine(routines[idx]) }
    }

    public func pendingApprovalCount(for botID: String? = nil) -> Int {
        botID.map { id in approvals.filter { $0.botID == id }.count } ?? approvals.count
    }

    /// Working bots drive the Live Activity / Dynamic Island.
    public var workingBots: [Bot] {
        bots.filter { $0.status == .working }
    }

    // MARK: - Demo behaviors

    private func demoReply(botID: String, chat: ChatState) {
        chat.isTyping = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(Double.random(in: 0.9...1.8)))
            chat.isTyping = false
            let reply = DemoData.cannedReplies[botID] ?? DemoData.cannedReplies["default"]!
            chat.messages.append(ChatMessage(author: .bot, time: Self.clock(), text: reply))
        }
    }

    static func clock() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: Date())
    }
}
