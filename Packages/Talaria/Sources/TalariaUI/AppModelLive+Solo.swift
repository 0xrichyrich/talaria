import SwiftUI
import TalariaKit
import TalariaTheme

// Solo mode's surface — roadmap Phase 5, docs/SOLO-MODE.md.
//
// Solo is Talaria with no gateway at all: a native agent loop (SoloEngine) over
// whatever this device can reach, with the iOS-permitted tool set (SoloTools)
// and the same approval vocabulary as gateway bots.
//
// Three rules this file exists to keep:
//
//   1. SOLO IS NOT A BOT. It never enters `model.bots`, never gets a
//      `session.start`, and never appears in the roster. Every roster-shaped
//      surface in the app iterates `model.bots` or `model.chats`, so Solo's
//      transcript is deliberately held here instead — a Solo conversation must
//      not be swept up by reconnect replay, liveness supervision, or the demo
//      flush.
//   2. AN ANSWER IS NEVER ANONYMOUS. Every assistant row carries the engine
//      that produced it (`SoloEngineTag`), and the transcript prints it. A
//      reply from the phone's own ~3B model and one from a hosted 70B are
//      different things and the UI says which.
//   3. AN APPROVAL IS AN APPROVAL. A Solo tool call raises an ordinary
//      `Approval` in `model.approvals`, so the Approvals tab, the inline card
//      and the badge counts all work with no new code — see the mirror below.
//
// Presentation follows the pattern SettingsView established: the screen is
// reached from anywhere via `AppModel.requestSolo()`, whose notification lands
// on `View.talariaSolo(model:)`. Mount that modifier once on the screen graph
// (RootView, beside `.talariaSettings(model:)`) and every route in works.

// MARK: - One row of a Solo transcript

/// A Solo message plus the badge. The payload is the app's own `ChatMessage`
/// so the transcript renders through exactly the same components as a bot's
/// (markdown bubbles, tool chips, inline approval cards) rather than growing a
/// parallel view layer; the tag rides alongside because `ChatMessage` has no
/// concept of *who answered* — on the gateway path the bot is the answer.
public struct SoloTurn: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID { message.id }
    public var message: ChatMessage
    /// Assistant rows only.
    public var engine: SoloEngineTag?

    public init(message: ChatMessage, engine: SoloEngineTag? = nil) {
        self.message = message
        self.engine = engine
    }
}

// MARK: - Transcript storage

/// Solo's conversations on disk.
///
/// Two stores, on purpose, and they are not redundant:
///
///   * this one keeps the *rendered* transcript — bubbles, tool chips, engine
///     badges — so reopening a conversation shows what actually happened;
///   * `SoloSessionArchive` (SoloTools.swift) keeps the plain text of every
///     turn as JSON Lines, which is what the `sessions_search` tool reads.
///
/// Both live under `SoloStore.root`, so Settings → Privacy measures them
/// together and "forget everything" takes both.
struct SoloTranscriptStore {
    static var directory: URL {
        SoloStore.root.appendingPathComponent("Transcripts", isDirectory: true)
    }

    /// A conversation as the picker lists it, without decoding every turn.
    struct Row: Identifiable, Sendable, Equatable {
        var id: String
        var title: String
        var updated: Date
        var messageCount: Int
    }

    private struct File: Codable {
        var id: String
        var title: String
        var updated: Date
        var turns: [SoloTurn]
    }

    /// Newest first.
    static func rows() -> [Row] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) else { return [] }
        let decoder = JSONDecoder()
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> Row? in
                guard let data = try? Data(contentsOf: url),
                      let file = try? decoder.decode(File.self, from: data),
                      !file.turns.isEmpty else { return nil }
                return Row(id: file.id, title: file.title, updated: file.updated,
                           messageCount: file.turns.count)
            }
            .sorted { $0.updated > $1.updated }
    }

    static func load(_ id: String) -> [SoloTurn] {
        guard let data = try? Data(contentsOf: url(for: id)),
              let file = try? JSONDecoder().decode(File.self, from: data) else { return [] }
        return file.turns
    }

    /// Written after every completed turn, not on a timer: a Solo turn is the
    /// only thing that changes it, and a crash mid-conversation should cost
    /// the turn in flight rather than the conversation.
    static func save(id: String, title: String, turns: [SoloTurn]) {
        guard !turns.isEmpty else { return }
        SoloStore.ensure(directory)
        let file = File(id: id, title: title, updated: Date(), turns: turns)
        guard let data = try? JSONEncoder().encode(file) else { return }
        try? data.write(to: url(for: id), options: .atomic)
    }

    static func delete(_ id: String) {
        try? FileManager.default.removeItem(at: url(for: id))
    }

    /// First thing the person said, clipped. Solo has no title-generation call
    /// to spend a turn on, and the opening line is what desktop shows until
    /// its own auto-title lands.
    static func derivedTitle(_ turns: [SoloTurn]) -> String {
        guard let first = turns.first(where: { $0.message.author == .user })?.message.text
            .trimmingCharacters(in: .whitespacesAndNewlines), !first.isEmpty else { return "" }
        let oneLine = first.replacingOccurrences(of: "\n", with: " ")
        return oneLine.count > 44 ? String(oneLine.prefix(43)) + "…" : oneLine
    }

    private static func url(for id: String) -> URL {
        let safe = id.components(separatedBy: CharacterSet.alphanumerics
            .union(CharacterSet(charactersIn: "-_")).inverted).joined()
        return directory.appendingPathComponent("\(safe.isEmpty ? "solo" : safe).json")
    }
}

// MARK: - Runtime

/// Solo's live state.
///
/// `AppModel`'s stored properties live in AppModel.swift (another owner) and
/// extensions cannot add storage, so — following `LiveRuntime` and
/// `ApprovalBridges` — this rides in a MainActor singleton. It is also the
/// reason Solo cannot be mistaken for a bot: nothing here is in `model.bots`
/// or `model.chats`.
@MainActor
@Observable
public final class SoloRuntime {
    public static let shared = SoloRuntime()

    /// The bot id Solo's approvals are attributed to. Not a profile — no
    /// gateway will accept it — but `Bot.unlisted(id:)` renders it as "Solo"
    /// wherever an approval card needs a name. Taken from the approval centre
    /// so the card and the mirror cannot disagree about who asked.
    public static let attributionID = SoloApprovalCenter.botID

    /// The open conversation.
    public private(set) var conversationID = UUID().uuidString
    public var turns: [SoloTurn] = []
    /// Conversation list, refreshed when the picker opens.
    private(set) var conversations: [SoloTranscriptStore.Row] = []

    /// A turn is in flight — the composer's send button becomes stop.
    public var isRunning = false
    /// Last provider failure, in words, under the composer.
    public var failure: String?

    /// The engine that will answer the next turn, resolved on appear and
    /// whenever settings change.
    public var engine: SoloEngineTag?
    /// Which tier `engine` names, so the provider is built from an enum rather
    /// than by matching a provider id string in two files.
    public private(set) var engineID: SoloEngineID?
    /// Why there is no engine, when there is none.
    public var unavailable: SoloUnavailableReason?

    var turnTask: Task<Void, Never>?
    /// Bumped whenever a turn is abandoned — stopped, or the conversation
    /// changed under it. A cancelled turn keeps running until its provider
    /// notices, and its tail would otherwise clear `isRunning` and drop
    /// `turnTask` belonging to a turn the person had already started next: the
    /// stop button would go dead on a turn that is genuinely in flight.
    var turnGeneration = 0
    var approvalMirror: Task<Void, Never>?
    /// Approval ids this runtime put into `model.approvals`, so the mirror
    /// only ever answers for its own.
    var mirrored: Set<String> = []
    /// Cached Portal model id, so every turn does not re-list them.
    var portalModel: String?

    public init() {}

    /// Abandon whatever turn is in flight. Everything that replaces the open
    /// conversation goes through here, so no path forgets to bump the
    /// generation and let a zombie tail speak for the next turn.
    func abandonTurn() {
        turnGeneration += 1
        turnTask?.cancel()
        turnTask = nil
        isRunning = false
        failure = nil
    }

    /// Start a fresh conversation, keeping the current one on disk.
    public func startNewConversation() {
        abandonTurn()
        SoloApprovalCenter.shared.endSession()
        conversationID = UUID().uuidString
        turns = []
    }

    func open(_ id: String) {
        abandonTurn()
        SoloApprovalCenter.shared.endSession()
        conversationID = id
        turns = SoloTranscriptStore.load(id)
    }

    func refreshConversations() {
        conversations = SoloTranscriptStore.rows()
    }

    /// Record the tier that will answer, and the badge that names it.
    func adopt(_ id: SoloEngineID, tag: SoloEngineTag) {
        engineID = id
        engine = tag
        unavailable = nil
    }

    /// No tier is reachable. The reason is set by the caller, which is the
    /// only place that knows which probe had the most useful verdict.
    func clearEngine() {
        engineID = nil
        engine = nil
    }

    func persist() {
        SoloTranscriptStore.save(id: conversationID,
                                 title: SoloTranscriptStore.derivedTitle(turns),
                                 turns: turns)
    }

    /// The engine's view of the conversation: what was said, nothing else.
    /// System rows are local bookkeeping and tool chips are already reflected
    /// in the assistant text, so neither is replayed into the prompt.
    var history: [InferenceMessage] {
        turns.compactMap { turn in
            let text = turn.message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            switch turn.message.author {
            case .user: return .user(text)
            case .bot: return .assistant(text)
            case .system: return nil
            }
        }
    }
}

// MARK: - Engine selection

public extension AppModel {

    /// Which engine Solo would use right now, or nil with a reason.
    ///
    /// Preference is the person's setting; availability is a measurement. A
    /// tier that is chosen but unavailable falls back rather than failing —
    /// the point of Solo is that it answers when the gateway is asleep.
    func soloResolveEngine() {
        let runtime = SoloRuntime.shared
        let preferred = SoloSettingsStore.shared.engine
        for candidate in Self.soloEngineOrder(preferring: preferred) {
            switch candidate {
            case .foundation:
                if FoundationModelsProvider.isAvailable {
                    runtime.adopt(.foundation, tag: FoundationModelsProvider().tag)
                    return
                }
            case .portal:
                if NousPortalTokenStore().load(portalURL: PortalDirectoryAPI.resolvedPortalURL) != nil {
                    let portal = NousPortalClient(portalURL: PortalDirectoryAPI.resolvedPortalURL)
                    runtime.adopt(.portal, tag: SoloEngineTag(
                        providerID: portal.providerID,
                        model: runtime.portalModel ?? "",
                        label: "Nous Portal", isOnDevice: false))
                    return
                }
            case .mlx:
                // TalariaLocal is an optional package and is deliberately not
                // in this target's dependency graph (MLX's Metal kernels must
                // not enter the default app). It reaches Solo through
                // `SoloToolHost.modelHost` when the build links it.
                continue
            }
        }
        runtime.clearEngine()
        // The on-device tier's own verdict is the most actionable thing to
        // report — "turn on Apple Intelligence" beats "not signed in" on a
        // phone that could run a model today.
        runtime.unavailable = FoundationModelsProvider.availability.reason ?? .notSignedIn
    }

    /// The person's choice first, then the rest in the order SOLO-MODE.md
    /// ranks them: on-device before the network.
    static func soloEngineOrder(preferring choice: SoloEngineID) -> [SoloEngineID] {
        var order: [SoloEngineID] = [.foundation, .mlx, .portal]
        if let index = order.firstIndex(of: choice) {
            order.remove(at: index)
            order.insert(choice, at: 0)
        }
        return order
    }

    /// The live provider for the resolved engine, or nil.
    func soloProvider() -> (any InferenceProvider)? {
        switch SoloRuntime.shared.engineID {
        case .foundation: FoundationModelsProvider()
        case .portal: NousPortalClient(portalURL: PortalDirectoryAPI.resolvedPortalURL)
        // MLX lives in the optional TalariaLocal package, which this target
        // does not link; `soloResolveEngine` never selects it here.
        case .mlx, nil: nil
        }
    }
}

// MARK: - Sending a turn

public extension AppModel {

    /// Send one Solo message. Mirrors `sendOrSteer` in shape — user bubble,
    /// streaming assistant bubble, tool chips — over a different engine.
    func soloSend(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let runtime = SoloRuntime.shared
        guard !runtime.isRunning else { return }

        soloResolveEngine()
        guard let provider = soloProvider(), let tag = runtime.engine else {
            runtime.failure = theme.copy.soloNoEngine(theme.themeID)
            return
        }
        runtime.failure = nil
        // Snapshotted before the new rows are appended: the engine wants the
        // conversation *up to* this prompt, and `prompt` is passed separately.
        let history = runtime.history

        runtime.turns.append(SoloTurn(message: ChatMessage(
            author: .user, time: AppModel.clock(), text: trimmed)))
        archive(role: "user", text: trimmed)

        // The row the deltas land in. Appended empty and streaming, exactly as
        // the gateway path does, so the bubble grows rather than appearing.
        let replyID = UUID()
        runtime.turns.append(SoloTurn(
            message: ChatMessage(id: replyID, author: .bot, time: AppModel.clock(),
                                 text: "", isStreaming: true),
            engine: tag))
        runtime.isRunning = true
        soloStartApprovalMirror()

        // Identifies this turn for the tail below. A stopped turn keeps running
        // until its provider observes the cancellation, and by then the person
        // may already have sent the next one.
        let generation = runtime.turnGeneration
        runtime.turnTask = Task { @MainActor [weak self] in
            // Engine events arrive from whatever executor the provider streams
            // on. Hopping each one through its own `Task { @MainActor }` would
            // let two deltas land out of order and scramble the reply, so they
            // ride one stream and are applied by a single consumer in order.
            let (events, feed) = AsyncStream<SoloEvent>.makeStream()
            let pump = Task { @MainActor in
                for await event in events {
                    SoloRuntime.shared.apply(event, to: replyID)
                }
            }
            do {
                // Portal serves many models and the seam needs one id; the
                // on-device tiers name their own and skip this round trip.
                let model = tag.model.isEmpty
                    ? try await (self?.soloDefaultModel(for: provider) ?? "")
                    : tag.model
                let engine = SoloEngine(provider: provider, model: model, tag: tag,
                                        toolbelt: SoloRegistryToolbelt())
                _ = try await engine.run(history: history, prompt: trimmed) { event in
                    feed.yield(event)
                }
            } catch is CancellationError {
                // `soloStop` already said so in the transcript.
            } catch {
                // Only the turn still on screen gets to report a failure; an
                // abandoned one would put its error under someone else's reply.
                if runtime.turnGeneration == generation {
                    runtime.failure = self?.theme.copy
                        .soloFailure(SoloEngine.describe(error: error),
                                     self?.theme.themeID ?? .soft)
                }
            }
            // Drain before finishing: the last delta must be in the bubble
            // before the row is closed and written to disk.
            feed.finish()
            await pump.value
            // The row this turn owns is closed either way — it is keyed by
            // `replyID` and belongs to nobody else. The shared running state is
            // only cleared if this is still the turn in flight.
            self?.soloFinishStreaming(replyID)
            guard runtime.turnGeneration == generation else { return }
            runtime.isRunning = false
            runtime.turnTask = nil
        }
    }

    /// Halt the running turn. Solo's sibling of `stopTurn(botID:)`: cancelling
    /// the task stops generation, and `SoloApprovalCenter` resolves anything
    /// parked to deny rather than leaving a tool thread waiting.
    func soloStop() {
        let runtime = SoloRuntime.shared
        guard runtime.isRunning else { return }
        runtime.abandonTurn()
        SoloApprovalCenter.shared.denyAll()
        runtime.turns.append(SoloTurn(message: ChatMessage(
            author: .system, text: theme.copy.stopNote(theme.themeID))))
        runtime.persist()
    }

    func soloNewConversation() {
        SoloRuntime.shared.startNewConversation()
    }

    func soloOpen(conversation id: String) {
        SoloRuntime.shared.open(id)
    }

    func soloDelete(conversation id: String) {
        SoloTranscriptStore.delete(id)
        SoloSessionArchive.shared.erase(sessionID: id)
        SoloRuntime.shared.refreshConversations()
        if SoloRuntime.shared.conversationID == id {
            SoloRuntime.shared.startNewConversation()
        }
    }

    /// Close the streaming row, drop it if the engine said nothing, and write
    /// the conversation to disk.
    private func soloFinishStreaming(_ replyID: UUID) {
        let runtime = SoloRuntime.shared
        guard let index = runtime.turns.firstIndex(where: { $0.id == replyID }) else { return }
        runtime.turns[index].message.isStreaming = false
        let text = runtime.turns[index].message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty, runtime.turns[index].message.toolCalls.isEmpty {
            runtime.turns.remove(at: index)
        } else if !text.isEmpty {
            archive(role: "assistant", text: text)
        }
        runtime.persist()
    }

    /// Portal serves many models and the seam needs one id; take the first the
    /// account can use and remember it for the rest of the session.
    private func soloDefaultModel(for provider: any InferenceProvider) async throws -> String {
        if let cached = SoloRuntime.shared.portalModel { return cached }
        let first = try await provider.models().first ?? ""
        SoloRuntime.shared.portalModel = first
        return first
    }

    /// The searchable half of Solo's memory. Kept behind one call so the
    /// `sessions_search` tool and this file cannot drift apart.
    private func archive(role: String, text: String) {
        let runtime = SoloRuntime.shared
        SoloSessionArchive.shared.record(
            sessionID: runtime.conversationID,
            title: SoloTranscriptStore.derivedTitle(runtime.turns),
            role: role, text: text)
    }
}

// MARK: - Applying engine events

extension SoloRuntime {

    /// Fold one `SoloEvent` into the streaming row. Deliberately the same
    /// shape as the gateway chat router's delta/tool handling, so a Solo turn
    /// and a bot turn render identically.
    func apply(_ event: SoloEvent, to replyID: UUID) {
        guard let index = turns.firstIndex(where: { $0.id == replyID }) else { return }
        switch event {
        case .delta(let chunk):
            turns[index].message.text += chunk
        case .reasoningDelta(let chunk):
            turns[index].message.reasoning = (turns[index].message.reasoning ?? "") + chunk
        case .toolStart(let id, let name, let preview):
            guard !turns[index].message.toolCalls.contains(where: { $0.id == id }) else { return }
            turns[index].message.toolCalls.append(
                ToolCall(id: id, name: name, context: preview, state: .running))
        case .toolEnd(let id, let summary, let detail, let seconds, let failed):
            guard let call = turns[index].message.toolCalls.firstIndex(where: { $0.id == id })
            else { return }
            turns[index].message.toolCalls[call].state = failed ? .failed : .done
            turns[index].message.toolCalls[call].summary = summary
            turns[index].message.toolCalls[call].resultText = detail
            turns[index].message.toolCalls[call].durationSeconds = seconds
        }
    }
}

// MARK: - The approval bridge

// A Solo tool call raises an approval in `SoloApprovalCenter` (SoloTools.swift),
// which parks the tool thread on a continuation. The app's approval surfaces —
// the Approvals tab, the inline card, the tab badge, the push banner — all read
// `model.approvals`. This mirror is the two-way join between them, and it is
// why a Solo tool is approved *exactly* like a bot's.
//
// Resolution is watched rather than intercepted: `resolveApproval` belongs to
// AppModelLive+Approvals.swift, and every path through it (the card, the tab,
// the notification action) removes the row and records the choice in
// `ApprovalOutcomes`. So the removal is the signal, and an id that leaves with
// no recorded choice is treated as a denial — the safe direction.

public extension AppModel {

    /// Start mirroring Solo approvals into the shared surfaces. Idempotent,
    /// and it stops on its own once nothing is pending and no turn is running.
    func soloStartApprovalMirror() {
        let runtime = SoloRuntime.shared
        guard runtime.approvalMirror == nil else { return }
        runtime.approvalMirror = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.soloSyncApprovals()
                if !runtime.isRunning, SoloApprovalCenter.shared.pending.isEmpty,
                   runtime.mirrored.isEmpty {
                    runtime.approvalMirror = nil
                    return
                }
                // A parked tool thread is a person-shaped wait; polling four
                // times a second costs nothing and avoids threading an
                // observation callback through two singletons.
                try? await Task.sleep(for: .milliseconds(250))
            }
            runtime.approvalMirror = nil
        }
    }

    /// One pass of the join: publish what is parked, answer what was decided.
    func soloSyncApprovals() {
        let runtime = SoloRuntime.shared
        let center = SoloApprovalCenter.shared

        for approval in center.pending where !approvals.contains(where: { $0.id == approval.id }) {
            // Solo can offer the full choice set — there is no server to
            // narrow it — so the shared cards are told so through the same
            // side table the gateway's own details ride in.
            ApprovalBridges.shared.details[approval.id] = Self.soloApprovalDetail(
                approval, choices: center.choices(for: approval.id))
            approvals.append(approval)
            runtime.mirrored.insert(approval.id)
            // Desktop renders an approval as a card inside the thread, not
            // only in a side list; the Solo transcript does the same.
            if !runtime.turns.contains(where: { $0.message.card == .approvalRef(approval.id) }) {
                runtime.turns.append(SoloTurn(message: ChatMessage(
                    author: .bot, time: AppModel.clock(), text: "",
                    card: .approvalRef(approval.id))))
            }
        }

        for id in runtime.mirrored where !approvals.contains(where: { $0.id == id }) {
            // Decided somewhere in the app. No recorded choice means it was
            // dropped rather than answered, and a dropped approval is a denial.
            let choice = ApprovalOutcomes.shared.choice(for: id) ?? .deny
            center.resolve(id, choice: choice)
            ApprovalBridges.shared.details.removeValue(forKey: id)
            runtime.mirrored.remove(id)
        }
        soloDrainAttributionChat()

        // Anything the centre dropped on its own (a cancelled turn) leaves the
        // shared surfaces with it — a card nobody is waiting on is a lie.
        for id in runtime.mirrored where !center.pending.contains(where: { $0.id == id }) {
            approvals.removeAll { $0.id == id }
            ApprovalBridges.shared.details.removeValue(forKey: id)
            runtime.mirrored.remove(id)
        }
    }

    /// Solo's approvals carry the full once / session / always / deny set:
    /// `SoloApprovalCenter` implements all four, scoped per host and per
    /// shortcut rather than per tool.
    ///
    /// The set is asked of the centre rather than written out here, so the card
    /// can only ever offer an answer the centre can actually honour — the same
    /// contract the gateway's own `choices` array carries
    /// (GatewayEvents.swift:237).
    static func soloApprovalDetail(_ approval: Approval,
                                   choices: [ApprovalChoice]) -> ApprovalDetail {
        ApprovalDetail(.object([
            "request_id": .string(approval.id),
            "command": .string(approval.subject),
            "description": .string(approval.why),
            "allow_permanent": .bool(choices.contains(.always)),
            "allow_session": .bool(choices.contains(.session)),
            "choices": .array(choices.map { .string($0.rawValue) }),
        ]), sessionID: "")
    }
}

// MARK: - The toolbelt adapter

/// `SoloEngine`'s view of the tool layer, over `SoloToolRegistry`.
///
/// The engine deliberately knows nothing about permissions, ask policies or
/// approval drafts — all of that is inside `SoloToolRegistry.run`, which
/// applies both gates before anything happens. This adapter is the whole of
/// the join, and intentionally the only place that names both sides.
struct SoloRegistryToolbelt: SoloToolbelt {

    func descriptors() async -> [SoloToolDescriptor] {
        await MainActor.run {
            SoloToolRegistry.shared.tools().map {
                SoloToolDescriptor(name: $0.name, description: $0.description,
                                   parameters: $0.parameters)
            }
        }
    }

    /// The registry already writes the human sentence for a call — it is what
    /// the approval card would say — so the chip borrows it rather than
    /// inventing a second phrasing of the same request.
    func preview(name: String, arguments: JSONValue) async -> String {
        await MainActor.run {
            SoloToolRegistry.shared.tool(named: name)?.approval(for: arguments)?.target ?? ""
        }
    }

    func run(name: String, arguments: JSONValue) async -> SoloToolOutcome {
        let result = await SoloToolRegistry.shared.run(name: name, arguments: arguments)
        return SoloToolOutcome(text: result.text, summary: result.summary,
                               failed: result.isError)
    }
}

// MARK: - Routing

public extension Notification.Name {
    /// Open Solo. Posted by `AppModel.requestSolo()`; handled by
    /// `View.talariaSolo(model:)`, the same shape Settings and Capabilities use.
    static let talariaOpenSolo = Notification.Name("bot.talaria.openSolo")
}

public extension AppModel {
    /// Ask for the Solo screen from anywhere — no screen owns the graph.
    func requestSolo() {
        NotificationCenter.default.post(name: .talariaOpenSolo, object: nil)
    }

    /// Whether Solo is worth offering at all on this device. False means every
    /// tier is out of reach, and the honest move is to hide the entry point
    /// rather than show a door that opens onto an apology.
    var soloIsPossible: Bool {
        FoundationModelsProvider.isAvailable
            || NousPortalTokenStore().load(portalURL: PortalDirectoryAPI.resolvedPortalURL) != nil
    }
}

// MARK: - Erasing everything Solo wrote

public extension AppModel {

    /// Solo's half of "delete local data" (Settings → Privacy & data).
    ///
    /// Solo's storage is the one part of Talaria with no server copy: a gateway
    /// bot's history lives on the gateway and survives a wipe by design, but a
    /// Solo transcript, its memory note and the images handed to it exist here
    /// and nowhere else. `deleteAllLocalData` erasing everything *except* those
    /// would be the worst possible reading of that sentence.
    ///
    /// Order matters, for the reason `deleteAllLocalData` states about its own
    /// stores: each of these writes an index or a preference back on the way
    /// out, so they are emptied before the directory tree and the defaults keys
    /// go — otherwise the wipe recreates what it just removed.
    func soloForgetEverything() {
        let runtime = SoloRuntime.shared
        runtime.turnTask?.cancel()
        runtime.approvalMirror?.cancel()
        runtime.approvalMirror = nil
        for id in runtime.mirrored { approvals.removeAll { $0.id == id } }
        runtime.mirrored.removeAll()
        SoloApprovalCenter.shared.denyAll()
        SoloApprovalCenter.shared.clearAllowlist()

        SoloPhotoShelf.shared.removeAll()
        SoloFileScopes.shared.removeAll()
        SoloShortcutBook.shared.removeAll()
        SoloSettingsStore.shared.resetToDefaults()

        SoloStore.eraseEverything()
        runtime.startNewConversation()
        runtime.refreshConversations()
    }
}

// MARK: - Erasing one conversation

extension SoloSessionArchive {

    /// Drop one conversation's searchable copy. `SoloSessionArchive` ships
    /// `eraseAll()` only, but "delete this chat" has to mean it — a transcript
    /// removed from the picker that `sessions_search` can still read is a
    /// privacy bug, not an inconsistency.
    ///
    /// The file name mirrors the archive's own (`<sanitised id>.jsonl`); Solo
    /// ids are UUID strings, so the sanitiser is a no-op in practice and the
    /// worst case of drift is a file that outlives its row rather than the
    /// wrong file being deleted.
    func erase(sessionID: String) {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let safe = sessionID.components(separatedBy: allowed.inverted).joined()
        let name = safe.isEmpty ? "session" : safe
        try? FileManager.default.removeItem(
            at: SoloStore.sessions.appendingPathComponent("\(name).jsonl"))
    }
}

// MARK: - Solo chat

/// Solo's transcript and composer.
///
/// Rendering is ChatView's, component for component — `MarkdownText` bubbles,
/// `ToolCallList` chips, `ThoughtBlock` reasoning, `InlineApprovalCard` seals —
/// because a Solo answer is not a different *kind* of answer. What it adds is
/// the one thing a bot chat never needs: a badge saying which engine spoke.
public struct SoloChatView: View {
    private let model: AppModel
    private let onBack: () -> Void

    @State private var draft = ""
    @State private var showConversations = false
    @State private var showExplainer = false
    @FocusState private var composerFocused: Bool
    @Environment(\.talariaReducedMotion) private var reducedMotion

    public init(model: AppModel, onBack: @escaping () -> Void = {}) {
        self.model = model
        self.onBack = onBack
    }

    private var theme: ThemePack { model.theme.pack }
    private var copy: CopyPack { model.theme.copy }
    private var runtime: SoloRuntime { SoloRuntime.shared }
    private var transcriptPolicy: TranscriptPresentationPolicy {
        TranscriptPresentationPolicy(detail: model.settings.transcriptDetail)
    }

    private var hasLiveTranscriptDetail: Bool {
        runtime.turns.contains { turn in
            let message = turn.message
            return (message.isStreaming && !(message.reasoning ?? "").isEmpty)
                || message.toolCalls.contains { $0.state == .running }
        }
    }

    /// Solo's own colour. Violet is the app's accent hue everywhere a thing is
    /// Talaria's rather than a bot's.
    private var accent: Color { theme.color(for: .violet) }

    public var body: some View {
        VStack(spacing: 0) {
            header
            if runtime.turns.isEmpty {
                emptyState
            } else {
                transcript
            }
            if let failure = runtime.failure {
                failureLine(failure)
            }
            composer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.bg)
        .sheet(isPresented: $showConversations) {
            SoloConversationsSheet(model: model)
        }
        .sheet(isPresented: $showExplainer) {
            // Screens/SoloExplainerView.swift owns the comparison screen; Solo
            // shows it as a sheet rather than posting its notification, so the
            // trade-off is readable without the root presenter being mounted.
            SoloExplainerView(model: model, onClose: { showExplainer = false })
        }
        .onReceive(NotificationCenter.default.publisher(for: .talariaOpenConnections)) { _ in
            // The explainer's footer hands off to Connections ("run a gateway
            // instead"); a sheet still covering it would swallow the answer.
            showExplainer = false
        }
        .onAppear {
            model.soloResolveEngine()
            runtime.refreshConversations()
            // Warming the system model costs nothing and takes the worst
            // latency out of the first token of the first turn.
            if let provider = model.soloProvider() as? FoundationModelsProvider {
                Task { await provider.prewarm() }
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            HeaderIconButton(theme: theme, size: 31, action: onBack) {
                Text(verbatim: "‹")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(theme.id == .ink ? theme.ink : theme.accent)
                    .padding(.bottom, 2)
            }
            Button { showExplainer = true } label: {
                VStack(alignment: .leading, spacing: 1) {
                    titleLine
                    engineLine
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            headerButton(copy.soloHistory(theme.id)) { showConversations = true }
            headerButton(copy.soloNew(theme.id)) {
                model.soloNewConversation()
                composerFocused = true
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.line).frame(height: 1)
        }
    }

    private var titleLine: some View {
        Group {
            switch theme.id {
            case .soft: Text(verbatim: "\(copy.soloChatTitle(theme.id)) ›").font(theme.body(16, weight: .bold))
            case .control: Text(verbatim: "\(copy.soloChatTitle(theme.id)) ›").font(theme.body(15, weight: .bold))
            case .ink: Text(verbatim: "\(copy.soloChatTitle(theme.id)) ›")
                    .font(theme.body(19, weight: .bold).smallCaps()).tracking(0.5)
            }
        }
        .foregroundStyle(theme.ink)
        .lineLimit(1)
    }

    /// The header's half of the honest badge: which engine will answer the
    /// *next* turn, before anyone has typed anything.
    private var engineLine: some View {
        // No engine is not a dead end: name the reason this device gave, so
        // the line says what to do rather than only that something is wrong.
        let line = runtime.engine.map { copy.soloEngineLine($0, theme.id) }
            ?? runtime.unavailable.map { copy.soloBlocked($0, theme.id) }
            ?? copy.soloNoEngine(theme.id)
        return Group {
            switch theme.id {
            case .soft: Text(line).font(theme.body(11.5, weight: .medium))
            case .control: Text(line.uppercased()).font(theme.mono(9.5)).tracking(0.8)
            case .ink: Text(line.uppercased()).font(theme.mono(8.5)).tracking(1.5)
            }
        }
        .foregroundStyle(runtime.engine == nil ? theme.warn : theme.faint)
        .lineLimit(1)
    }

    private func headerButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                switch theme.id {
                case .soft: Text(title).font(theme.body(12, weight: .semibold))
                case .control: Text(title).font(theme.mono(10, weight: .semibold)).tracking(1)
                case .ink: Text(title).font(theme.body(13, weight: .semibold).smallCaps()).tracking(1)
                }
            }
            .foregroundStyle(theme.ink)
            .padding(.vertical, 7)
            .padding(.horizontal, 11)
            .chipShell(theme)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 11) {
                    ForEach(runtime.turns) { turn in
                        row(turn)
                    }
                    if transcriptPolicy.showsWorkingAvatar(
                        isTurnRunning: runtime.isRunning,
                        hasLiveDetail: hasLiveTranscriptDetail
                    ) {
                        TranscriptWorkingAvatar(model: nil, bot: nil, theme: theme,
                                                label: copy.soloWorking(theme.id))
                    }
                    Color.clear.frame(height: 1).id("solo-bottom")
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 8)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: runtime.turns.count) {
                withAnimation(ChatComposerLayoutPolicy.animation(
                    reducedMotion: reducedMotion, duration: 0.25
                )) {
                    proxy.scrollTo("solo-bottom", anchor: .bottom)
                }
            }
        }
    }

    @ViewBuilder private func row(_ turn: SoloTurn) -> some View {
        switch turn.message.author {
        case .system: systemRow(turn.message)
        case .user: userRow(turn.message)
        case .bot: botRow(turn)
        }
    }

    private func systemRow(_ message: ChatMessage) -> some View {
        HStack(spacing: 8) {
            if theme.id == .ink {
                Rectangle().fill(theme.line).frame(height: 1)
            } else {
                Spacer(minLength: 0)
            }
            Text(theme.id == .soft ? message.text : message.text.uppercased())
                .font(theme.id == .soft ? theme.body(11, weight: .semibold) : theme.mono(9.5))
                .tracking(theme.id == .soft ? 0 : 1)
                .foregroundStyle(theme.ink.opacity(0.4))
                .padding(.vertical, theme.id == .ink ? 0 : 5)
                .padding(.horizontal, theme.id == .ink ? 0 : 12)
                .background(theme.id == .soft ? theme.ink.opacity(0.05) : .clear, in: Capsule())
                .lineLimit(1)
                .fixedSize()
            if theme.id == .ink {
                Rectangle().fill(theme.line).frame(height: 1)
            } else {
                Spacer(minLength: 0)
            }
        }
        .padding(.vertical, 3)
    }

    private func userRow(_ message: ChatMessage) -> some View {
        HStack(spacing: 0) {
            Spacer(minLength: 70)
            userBubble(message.text)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    @ViewBuilder private func userBubble(_ text: String) -> some View {
        switch theme.id {
        case .soft:
            MarkdownText(text, theme: theme, size: 14.5, color: theme.accentFg,
                         lineSpacing: 3, onAccent: true)
                .padding(.vertical, 11).padding(.horizontal, 14)
                .background(LinearGradient(colors: [theme.color(for: .violet), theme.accent],
                                           startPoint: .topLeading, endPoint: .bottomTrailing),
                            in: UnevenRoundedRectangle(topLeadingRadius: 20, bottomLeadingRadius: 20,
                                                       bottomTrailingRadius: 6, topTrailingRadius: 20))
                .shadow(color: theme.accent.opacity(0.24), radius: 6, y: 4)
        case .control:
            MarkdownText(text, theme: theme, size: 14, color: theme.ink, lineSpacing: 3.5)
                .padding(.vertical, 11).padding(.horizontal, 13)
                .background(theme.accent.opacity(0.12),
                            in: UnevenRoundedRectangle(topLeadingRadius: 10, bottomLeadingRadius: 10,
                                                       bottomTrailingRadius: 3, topTrailingRadius: 10))
                .overlay(UnevenRoundedRectangle(topLeadingRadius: 10, bottomLeadingRadius: 10,
                                                bottomTrailingRadius: 3, topTrailingRadius: 10)
                    .strokeBorder(theme.accent.opacity(0.25), lineWidth: 1))
        case .ink:
            MarkdownText(text, theme: theme, size: 15.5, color: theme.bg,
                         lineSpacing: 3, onAccent: true)
                .padding(.vertical, 11).padding(.horizontal, 15)
                .background(theme.ink,
                            in: UnevenRoundedRectangle(topLeadingRadius: 16, bottomLeadingRadius: 16,
                                                       bottomTrailingRadius: 3, topTrailingRadius: 16))
        }
    }

    private func botRow(_ turn: SoloTurn) -> some View {
        let message = turn.message
        return HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                if let reasoning = message.reasoning, !reasoning.isEmpty,
                   transcriptPolicy.showsReasoning(isLive: message.isStreaming) {
                    ThoughtBlock(reasoning: reasoning, theme: theme,
                                 isLive: message.isStreaming && message.text.isEmpty)
                        .padding(.bottom, message.text.isEmpty ? 0 : 5)
                }
                if !message.text.isEmpty {
                    botBubble(message.text)
                }
                let visibleToolCalls = transcriptPolicy.visibleToolCalls(message.toolCalls)
                if !visibleToolCalls.isEmpty {
                    ToolCallList(calls: visibleToolCalls, theme: theme, copy: copy, accent: accent)
                        .padding(.top, message.text.isEmpty ? 0 : 7)
                        .padding(.leading, theme.id == .ink ? 12 : 0)
                }
                if case .approvalRef(let id)? = message.card {
                    InlineApprovalCard(model: model, approvalID: id,
                                       botID: SoloRuntime.attributionID)
                        .padding(.top, 8)
                        .padding(.leading, theme.id == .ink ? 14 : 0)
                }
                // The badge. Held back until the row has settled so it does
                // not flicker under a bubble that is still growing.
                if let engine = turn.engine, !message.isStreaming, !message.text.isEmpty {
                    SoloEngineBadge(theme: theme, copy: copy, engine: engine)
                        .padding(.top, 5)
                        .padding(.leading, theme.id == .ink ? 12 : 2)
                }
            }
            Spacer(minLength: 44)
        }
    }

    @ViewBuilder private func botBubble(_ text: String) -> some View {
        switch theme.id {
        case .soft:
            MarkdownText(text, theme: theme, size: 14.5,
                         color: theme.ink.opacity(0.94), lineSpacing: 3)
                .padding(.vertical, 11).padding(.horizontal, 14)
                .background(theme.panel,
                            in: UnevenRoundedRectangle(topLeadingRadius: 20, bottomLeadingRadius: 6,
                                                       bottomTrailingRadius: 20, topTrailingRadius: 20))
                .overlay(UnevenRoundedRectangle(topLeadingRadius: 20, bottomLeadingRadius: 6,
                                                bottomTrailingRadius: 20, topTrailingRadius: 20)
                    .strokeBorder(theme.ink.opacity(0.06), lineWidth: 1))
        case .control:
            MarkdownText(text, theme: theme, size: 14,
                         color: theme.ink.opacity(0.88), lineSpacing: 3.5)
                .padding(.vertical, 11).padding(.horizontal, 13)
                .background(theme.panel,
                            in: UnevenRoundedRectangle(topLeadingRadius: 10, bottomLeadingRadius: 3,
                                                       bottomTrailingRadius: 10, topTrailingRadius: 10))
                .overlay(UnevenRoundedRectangle(topLeadingRadius: 10, bottomLeadingRadius: 3,
                                                bottomTrailingRadius: 10, topTrailingRadius: 10)
                    .strokeBorder(theme.line, lineWidth: 1))
        case .ink:
            MarkdownText(text, theme: theme, size: 16.5, color: theme.ink, lineSpacing: 4)
                .padding(.vertical, 2).padding(.leading, 12)
                .overlay(alignment: .leading) {
                    Rectangle().fill(accent).frame(width: 2)
                }
        }
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Text(copy.soloEmptyTitle(theme.id))
                .font(theme.id == .ink ? theme.display(24, weight: .bold) : theme.body(20, weight: .bold))
                .foregroundStyle(theme.ink)
                .multilineTextAlignment(.center)
            Text(copy.soloEmptyBody(theme.id))
                .font(theme.body(theme.id == .ink ? 15 : 13.5))
                .foregroundStyle(theme.sub)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .padding(.horizontal, 34)
            Button { showExplainer = true } label: {
                Text(copy.soloExplainerLink(theme.id))
                    .font(theme.body(13, weight: .semibold))
                    .foregroundStyle(theme.accent)
                    .padding(.vertical, 9).padding(.horizontal, 14)
                    .chipShell(theme)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func failureLine(_ text: String) -> some View {
        HStack(spacing: 6) {
            Text(verbatim: "!")
                .font(theme.mono(10, weight: .bold))
                .foregroundStyle(theme.danger)
            Text(text)
                .font(theme.id == .soft ? theme.body(11.5) : theme.mono(9.5))
                .foregroundStyle(theme.danger)
                .lineLimit(3)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 4)
    }

    // MARK: Composer

    private var composer: some View {
        HStack(spacing: 8) {
            TextField("", text: $draft,
                      prompt: Text(copy.soloComposer(theme.id)).foregroundStyle(theme.faint))
                .textFieldStyle(.plain)
                .font(theme.id == .control ? theme.mono(13) : theme.body(14.5))
                .foregroundStyle(theme.ink)
                .tint(theme.accent)
                .focused($composerFocused)
                .frame(height: 42)
                .padding(.horizontal, 15)
                .background(composerChrome)
                .onSubmit(send)
            sendOrStop
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    @ViewBuilder private var composerChrome: some View {
        switch theme.id {
        case .soft:
            Capsule().fill(theme.panel)
                .overlay(Capsule().strokeBorder(theme.ink.opacity(0.09), lineWidth: 1))
        case .control:
            RoundedRectangle(cornerRadius: 8).fill(theme.panel)
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(theme.lineStrong.opacity(0.8), lineWidth: 1))
        case .ink:
            RoundedRectangle(cornerRadius: 2).fill(theme.panel)
                .overlay(RoundedRectangle(cornerRadius: 2)
                    .strokeBorder(theme.ink.opacity(0.4), lineWidth: 1))
        }
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespaces).isEmpty && runtime.engine != nil
    }

    /// Same control as the gateway composer: while a turn runs the send button
    /// becomes stop, because a runaway loop on a phone is a battery problem as
    /// well as a wrong answer.
    private var sendOrStop: some View {
        Button {
            if runtime.isRunning { model.soloStop() } else { send() }
        } label: {
            Group {
                if runtime.isRunning {
                    RoundedRectangle(cornerRadius: theme.id == .soft ? 3 : theme.id == .control ? 1 : 2)
                        .fill(theme.id == .control ? theme.danger : theme.accentFg)
                        .frame(width: 12, height: 12)
                } else {
                    Text(verbatim: "↑")
                        .font(.system(size: 18, weight: .heavy))
                        .foregroundStyle(theme.accentFg)
                }
            }
            .frame(width: ChatComposerLayoutPolicy.controlHitTarget,
                   height: ChatComposerLayoutPolicy.controlHitTarget)
            .background(sendBackground,
                        in: RoundedRectangle(cornerRadius: theme.id == .control ? 8 : 20,
                                             style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: theme.id == .control ? 8 : 20,
                                           style: .continuous))
        }
        .buttonStyle(.plain)
        .animation(ChatComposerLayoutPolicy.animation(reducedMotion: reducedMotion, duration: 0.2),
                   value: canSend)
        .animation(ChatComposerLayoutPolicy.animation(reducedMotion: reducedMotion, duration: 0.2),
                   value: runtime.isRunning)
        .accessibilityLabel(runtime.isRunning ? copy.stopLabel(theme.id) : copy.sendLabel(theme.id))
    }

    private var sendBackground: Color {
        if runtime.isRunning {
            return theme.id == .control ? theme.danger.opacity(0.14) : theme.danger
        }
        return canSend ? theme.accent : theme.ink.opacity(theme.id == .soft ? 0.18 : 0.16)
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespaces)
        guard canSend else { return }
        draft = ""
        model.soloSend(text)
    }
}

// MARK: - Engine badge

/// The honest badge. Says which engine answered and, for the one thing people
/// actually want to know, whether the words left the phone.
struct SoloEngineBadge: View {
    var theme: ThemePack
    var copy: CopyPack
    var engine: SoloEngineTag

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(engine.isOnDevice ? theme.ok : theme.accent)
                .frame(width: 5, height: 5)
            Text(copy.soloBadge(engine, theme.id))
                .font(theme.mono(theme.id == .ink ? 8 : 9))
                .tracking(theme.id == .ink ? 1.2 : 0.6)
                .foregroundStyle(theme.faint)
                .lineLimit(1)
        }
    }
}

// MARK: - Conversation picker

/// Solo's own history. Never `session.list` — these conversations never
/// existed on a gateway, and mixing them into that sheet would be a lie about
/// where they live.
struct SoloConversationsSheet: View {
    let model: AppModel

    @Environment(\.dismiss) private var dismiss

    private var theme: ThemePack { model.theme.pack }
    private var copy: CopyPack { model.theme.copy }
    private var runtime: SoloRuntime { SoloRuntime.shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScreenHeader(theme: theme, kicker: copy.soloKicker(theme.id),
                         title: copy.soloHistoryTitle(theme.id)) {
                HeaderIconButton(theme: theme, action: { dismiss() }) {
                    Text(verbatim: "✕")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(theme.ink.opacity(0.6))
                }
            }
            if runtime.conversations.isEmpty {
                Text(copy.soloNoHistory(theme.id))
                    .font(theme.body(13.5))
                    .foregroundStyle(theme.sub)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                Spacer()
            } else {
                ScrollView {
                    SettingsGroup(theme: theme) {
                        ForEach(Array(runtime.conversations.enumerated()), id: \.element.id) { index, row in
                            SettingsRow(theme: theme,
                                        title: row.title.isEmpty
                                            ? copy.soloUntitled(theme.id) : row.title,
                                        subtitle: subtitle(row),
                                        showsChevron: true,
                                        isLast: index == runtime.conversations.count - 1) {
                                model.soloOpen(conversation: row.id)
                                dismiss()
                            }
                            .contextMenu {
                                Button(role: .destructive) {
                                    model.soloDelete(conversation: row.id)
                                } label: {
                                    Label(copy.soloDelete(theme.id), systemImage: "trash")
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 4)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.bg)
        .onAppear { runtime.refreshConversations() }
    }

    private func subtitle(_ row: SoloTranscriptStore.Row) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return "\(formatter.string(from: row.updated)) · \(row.messageCount)"
    }
}

// MARK: - Presentation

/// Mounts Solo on the screen graph. Same shape as `talariaSettings(model:)`:
/// the screen is pushed in response to `AppModel.requestSolo()`, so no caller
/// needs a binding threaded to it.
///
/// Add `.talariaSolo(model: model)` beside `.talariaApprovalPolicy(model:)` in
/// RootView to give every route in — the roster header, the search palette,
/// onboarding's third door — somewhere to land.
struct TalariaSoloPresenter: ViewModifier {
    let model: AppModel

    @State private var isPresented = false
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    private var pushAnimation: Animation {
        model.settings.prefersReducedMotion(system: systemReduceMotion)
            ? .easeOut(duration: 0.15) : .easeOut(duration: 0.32)
    }

    func body(content: Content) -> some View {
        content
            .overlay {
                if isPresented {
                    ZStack {
                        model.theme.pack.bg.ignoresSafeArea()
                        SoloChatView(model: model) {
                            withAnimation(pushAnimation) { isPresented = false }
                        }
                    }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                    // Above Settings (14), which is one of the places Solo is
                    // opened from; below the explainer (16), which Solo opens.
                    .zIndex(15)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .talariaOpenSolo)) { _ in
                guard !isPresented else { return }
                withAnimation(pushAnimation) { isPresented = true }
            }
            .onChange(of: model.showOnboarding) { _, showing in
                // Onboarding is the topmost surface in the app; a screen
                // mounted above the graph would otherwise hide it.
                if showing, isPresented { isPresented = false }
            }
    }
}

public extension View {
    /// Mount the Solo screen on this view tree.
    func talariaSolo(model: AppModel) -> some View {
        modifier(TalariaSoloPresenter(model: model))
    }
}

// MARK: - Copy

// Solo's voice in all three packs. Soft explains, control reports, ink narrates
// — the same split every other screen keeps. Nothing here is a string CopyPack
// already owns: Solo reuses `stopLabel` / `sendLabel` / `stopNote` from the
// chat pack, because stopping a Solo turn and stopping a bot's are the same act.

extension CopyPack {

    /// The header's engine line — what will answer the next turn.
    /// The chat header's name. Short on purpose — `soloTitle` is the
    /// explainer's screen title ("The Solitary Familiar") and reads as a
    /// pronouncement above a transcript rather than a name.
    func soloChatTitle(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Solo"
        case .control: "SOLO"
        case .ink: "Alone"
        }
    }

    func soloEngineLine(_ engine: SoloEngineTag, _ t: ThemeID) -> String {
        switch t {
        case .soft:
            engine.isOnDevice ? "\(engine.label) · stays on this phone"
                              : "\(engine.label) · leaves this phone"
        case .control:
            engine.isOnDevice ? "\(engine.label) · ON-DEVICE" : "\(engine.label) · REMOTE"
        case .ink:
            engine.isOnDevice ? "\(engine.label) — it thinks here"
                              : "\(engine.label) — it thinks elsewhere"
        }
    }

    /// The badge under a finished answer.
    func soloBadge(_ engine: SoloEngineTag, _ t: ThemeID) -> String {
        let model = engine.model.isEmpty ? "" : " · \(engine.model)"
        switch t {
        case .soft: return engine.isOnDevice ? "\(engine.label)\(model), on device"
                                             : "\(engine.label)\(model)"
        case .control: return "\(engine.label.uppercased())\(model.uppercased())"
        case .ink: return engine.isOnDevice ? "answered here by \(engine.label)"
                                            : "answered afar by \(engine.label)"
        }
    }

    /// No tier is reachable. Never a dead end — it names the way out.
    func soloNoEngine(_ t: ThemeID) -> String {
        switch t {
        case .soft: "No engine yet — turn on Apple Intelligence, or sign in to Nous Portal."
        case .control: "NO ENGINE — ENABLE APPLE INTELLIGENCE OR SIGN IN TO PORTAL"
        case .ink: "nothing here can think yet — wake Apple Intelligence, or sign into Portal"
        }
    }

    func soloWorking(_ t: ThemeID) -> String {
        switch t {
        case .soft: "thinking…"
        case .control: "GENERATING"
        case .ink: "it considers"
        }
    }

    func soloComposer(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Ask Solo…"
        case .control: "PROMPT"
        case .ink: "speak to it…"
        }
    }

    func soloNew(_ t: ThemeID) -> String {
        switch t {
        case .soft: "New"
        case .control: "NEW"
        case .ink: "begin again"
        }
    }

    func soloHistory(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Past"
        case .control: "LOG"
        case .ink: "before"
        }
    }

    func soloHistoryTitle(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Past conversations"
        case .control: "Session log"
        case .ink: "What Was Said Before"
        }
    }

    func soloNoHistory(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Nothing yet. Solo conversations stay on this phone."
        case .control: "NO SESSIONS ON DEVICE."
        case .ink: "nothing yet — what is said here stays here"
        }
    }

    func soloUntitled(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Untitled"
        case .control: "UNTITLED"
        case .ink: "unnamed"
        }
    }

    func soloDelete(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Delete"
        case .control: "PURGE"
        case .ink: "burn it"
        }
    }

    func soloEmptyTitle(_ t: ThemeID) -> String {
        switch t {
        case .soft: "An agent, on this phone"
        case .control: "SOLO — NO GATEWAY REQUIRED"
        case .ink: "An Agent, Here"
        }
    }

    func soloEmptyBody(_ t: ThemeID) -> String {
        switch t {
        case .soft:
            "No gateway, no server, no account. Solo answers here, with a small "
                + "set of tools the phone actually permits."
        case .control:
            "NO GATEWAY. NO SERVER. INFERENCE AND TOOLS RUN LOCAL, WITHIN THE "
                + "PERMISSIONS YOU GRANT."
        case .ink:
            "no gateway, no distant machine. It answers from here, with the few "
                + "hands this phone allows it."
        }
    }

    func soloExplainerLink(_ t: ThemeID) -> String {
        switch t {
        case .soft: "What can Solo do?"
        case .control: "CAPABILITY MATRIX"
        case .ink: "what it can and cannot do"
        }
    }

}

// MARK: - Draining the attribution chat

extension AppModel {

    /// `resolveApproval` writes its "Approved · …" note into `chat(for:)`,
    /// which for a Solo approval mints a `ChatState` under Solo's attribution
    /// id. Nothing renders that — Solo's transcript is not in `model.chats`,
    /// deliberately — so the note is moved where it belongs and the stray
    /// entry is dropped rather than left to look like a bot nobody can open.
    func soloDrainAttributionChat() {
        guard let stray = chats[SoloRuntime.attributionID] else { return }
        let runtime = SoloRuntime.shared
        for message in stray.messages where message.author == .system {
            runtime.turns.append(SoloTurn(message: message))
        }
        chats.removeValue(forKey: SoloRuntime.attributionID)
        runtime.persist()
    }
}

// MARK: - Failure copy

extension CopyPack {

    /// Provider failures in Solo's voice.
    ///
    /// `SoloEngine.describe(error:)` deliberately hands back short tokens for
    /// the Foundation Models cases a person can act on — this is where they
    /// become sentences. Anything unrecognised is passed through: a raw
    /// transport message is more useful than a shrug.
    func soloFailure(_ detail: String, _ t: ThemeID) -> String {
        switch detail {
        case "guardrail":
            switch t {
            case .soft: return "The on-device model declined to answer that."
            case .control: return "REFUSED BY ON-DEVICE SAFETY MODEL"
            case .ink: return "it would not say"
            }
        case "context-window-exceeded":
            switch t {
            case .soft: return "This conversation is too long for the on-device model. Start a new one."
            case .control: return "CONTEXT WINDOW EXCEEDED — START A NEW SESSION"
            case .ink: return "it has heard too much; begin again"
            }
        case "rate-limited":
            switch t {
            case .soft: return "The model is busy. Try again in a moment."
            case .control: return "RATE LIMITED — RETRY"
            case .ink: return "it is otherwise engaged; ask again shortly"
            }
        case "unsupported-language":
            switch t {
            case .soft: return "The on-device model does not speak this device's language yet."
            case .control: return "LOCALE UNSUPPORTED BY ON-DEVICE MODEL"
            case .ink: return "it does not have this tongue"
            }
        case "assets-unavailable":
            switch t {
            case .soft: return "The model is still downloading. Try again shortly."
            case .control: return "MODEL ASSETS PENDING"
            case .ink: return "it has not finished arriving"
            }
        default:
            return detail
        }
    }

    /// Why Solo cannot answer at all, phrased as the next move.
    func soloBlocked(_ reason: SoloUnavailableReason, _ t: ThemeID) -> String {
        switch reason {
        case .appleIntelligenceOff:
            switch t {
            case .soft: return "Turn on Apple Intelligence to answer here"
            case .control: return "APPLE INTELLIGENCE DISABLED"
            case .ink: return "wake Apple Intelligence, and it will think here"
            }
        case .modelNotReady:
            switch t {
            case .soft: return "The on-device model is still downloading"
            case .control: return "ON-DEVICE ASSETS PENDING"
            case .ink: return "the model has not finished arriving"
            }
        case .deviceNotEligible, .osTooOld:
            switch t {
            case .soft: return "This iPhone can't run a model — sign in to Nous Portal"
            case .control: return "NO ON-DEVICE TIER — USE PORTAL"
            case .ink: return "this device cannot think alone — call on Portal"
            }
        case .notSignedIn, .notBuilt, .noModelDownloaded, .unknown:
            return soloNoEngine(t)
        }
    }
}
