import SwiftUI
import TalariaKit
import TalariaTheme

#if canImport(UIKit)
import UIKit
#endif

// ── The toast bus ────────────────────────────────────────────────────────────
//
// Desktop Bot Mode answers every mutation out loud. `host.notify` fires on a
// pin (plugin.js:4056-4066), a duplicate (4079 / 4083 / 4085), a look save
// (5004 / 5038), a delete (7974) — always in the same two-beat shape: say what
// is being attempted, then say what happened.
//
// Talaria said nothing. The only banner slot in the app is RootView's
// `activeBanner`, and it is gated on `demoDataLoaded` — the demo push cycle
// owns it, so on a real gateway a failed pin, a duplicate or a cosmetic save
// that the gateway rejected produced no user-visible feedback at all. The row
// just slid back.
//
// This is that missing slot, and it is deliberately NOT the push banner:
//
//   · a push is news from a bot — it deserves a card with an avatar, an
//     approve/later row and a 4.8 s stage;
//   · a toast is the app answering the thumb that just tapped — it is small, it
//     stacks, it never asks for a decision, and it goes away.
//
// The queue's rules — key pairing, oldest-drops, what `settle` actually changes
// — are `TalariaKit/ToastQueue`, where `talaria-verify` executes them. What is
// left here is the part that has to be a class in a view tree: an `@Observable`
// array, one expiry Task per card, and the VoiceOver announcement.
//
// The bus is mode-agnostic on purpose. Demo mode mutates local state and the
// answer is instant; live mode round-trips a gateway and the answer can be
// "no". Both get the same voice — that is what "ungated from demo mode" means.
// (Only the Activity ledger is live-only; see AppModelLive+Toasts.swift.)

// MARK: - The bus

/// The live toast queue. A MainActor singleton for the same reason
/// `LiveRuntime`, `RosterSignals` and `FeedsRuntime` are: `AppModel`'s stored
/// properties live in AppModel.swift, which this phase does not own, and a
/// Swift extension cannot add storage.
@MainActor
@Observable
public final class ToastBus {
    public static let shared = ToastBus()

    /// Newest last — the host draws them top-down in arrival order, so a stack
    /// reads like a transcript rather than shuffling under the eye.
    public private(set) var toasts: [Toast] = []

    /// Expiry timers, one per live toast, cancelled when it is replaced or
    /// dismissed early.
    @ObservationIgnored private var timers: [UUID: Task<Void, Never>] = [:]

    /// The last text posted under each pair key, so a silent settle can clear
    /// the ledger row's pending flag without the caller repeating itself.
    @ObservationIgnored private var lastPosted: [String: Toast] = [:]

    private init() {}

    /// Post (or replace) a toast. Returns the toast as it was filed, so the
    /// caller can mirror the same values into the Activity ledger.
    @discardableResult
    func post(_ toast: Toast) -> Toast {
        let result = ToastQueue.post(toast, into: toasts)
        for id in result.retired { timers.removeValue(forKey: id)?.cancel() }
        toasts = result.toasts
        if let key = result.filed.key {
            lastPosted = ToastQueue.remember(result.filed, key: key, in: lastPosted)
        }
        announce(result.filed)
        schedule(result.filed)
        return result.filed
    }

    /// The optimistic half turned out to be the whole truth (a pin that simply
    /// worked). The card stays exactly as written — re-saying it would be the
    /// app congratulating itself — but it stops being an unanswered half, so it
    /// leaves on the ordinary three-second clock instead of the long one an
    /// unconfirmed pair holds.
    @discardableResult
    func settle(key: String) -> Toast? {
        apply(ToastQueue.settle(key: key, in: toasts), key: key)
    }

    /// Take the optimistic half back off the screen — the outcome was real but
    /// not worth saying (an older gateway that cannot store cosmetics at all, a
    /// switch that parked its own dialog). Returns it so the caller can still
    /// settle the ledger row it wrote.
    @discardableResult
    func retract(key: String) -> Toast? {
        apply(ToastQueue.retract(key: key, in: toasts), key: key)
    }

    private func apply(_ result: ToastQueue.CloseResult, key: String) -> Toast? {
        for id in result.retired { timers.removeValue(forKey: id)?.cancel() }
        toasts = result.toasts
        if let rescheduled = result.rescheduled { schedule(rescheduled) }
        return lastPosted.removeValue(forKey: key)
    }

    /// Take one card off the screen — it expired, or a thumb flicked it away.
    ///
    /// The pair's book-keeping deliberately survives: a user who swipes the
    /// "Duplicating…" card away has dismissed a card, not cancelled the write,
    /// and its answer still has a ledger row waiting to be settled.
    public func dismiss(_ id: UUID) {
        timers.removeValue(forKey: id)?.cancel()
        toasts.removeAll { $0.id == id }
    }

    /// Drop everything on screen — a gateway swap, a demo-world flush.
    public func clear() {
        for timer in timers.values { timer.cancel() }
        timers.removeAll()
        lastPosted.removeAll()
        toasts.removeAll()
    }

    private func schedule(_ toast: Toast) {
        guard let lifetime = toast.lifetime else { return }
        timers[toast.id] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: lifetime)
            guard !Task.isCancelled else { return }
            self?.dismiss(toast.id)
        }
    }

    /// VoiceOver has no eyes on a card that appears and leaves by itself, so the
    /// words are spoken as they land — otherwise the one user who most needs to
    /// hear "that pin did not stick" is the one who never learns it.
    private func announce(_ toast: Toast) {
        #if canImport(UIKit)
        let spoken = toast.message.isEmpty ? toast.title : "\(toast.title). \(toast.message)"
        UIAccessibility.post(notification: .announcement, argument: spoken)
        #endif
    }
}

// MARK: - The host

/// Mount point for the toast stack. RootView adds one line for it.
///
/// `topInset` exists for exactly one collision: demo mode can have a push banner
/// on stage (RootView's own 4.8 s cycle) at the same moment a demo mutation
/// toasts. RootView passes the banner's height there so the two stack instead
/// of overlapping; the default is the top of the safe area.
public struct ToastHost: View {
    private let model: AppModel
    private let topInset: CGFloat

    @Environment(\.talariaReducedMotion) private var reducedMotion

    public init(model: AppModel, topInset: CGFloat = 0) {
        self.model = model
        self.topInset = topInset
    }

    private var theme: ThemePack { model.theme.pack }
    private var copy: CopyPack { model.theme.copy }

    public var body: some View {
        VStack(spacing: 8) {
            ForEach(ToastBus.shared.toasts) { toast in
                ToastCard(toast: toast,
                          bot: toast.botID.map { model.identity($0) },
                          theme: theme,
                          copy: copy) {
                    ToastBus.shared.dismiss(toast.id)
                }
                .transition(transition)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, topInset)
        .animation(reducedMotion ? .easeInOut(duration: 0.2)
                                 : .spring(response: 0.42, dampingFraction: 0.82),
                   value: ToastBus.shared.toasts)
        // The stack owns only the cards; taps land on the screen underneath
        // everywhere else, so a toast can never eat the button the user is
        // reaching for next.
        .allowsHitTesting(!ToastBus.shared.toasts.isEmpty)
    }

    private var transition: AnyTransition {
        reducedMotion ? .opacity
                      : .move(edge: .top).combined(with: .opacity)
    }
}

// MARK: - The card

/// One toast, in the pack's voice. Deliberately the push banner's silhouette
/// (Components/PushBanner.swift) at a smaller scale — same corner language, same
/// chrome per pack — so the two read as one family, with a kind rail the banner
/// has no need for.
private struct ToastCard: View {
    let toast: Toast
    let bot: Bot?
    let theme: ThemePack
    let copy: CopyPack
    let dismiss: () -> Void

    @State private var drag: CGFloat = 0

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            leading
            VStack(alignment: .leading, spacing: 1) {
                Text(toast.title)
                    .font(titleFont)
                    .tracking(theme.id == .control ? 0.5 : 0)
                    .foregroundStyle(theme.ink)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if !toast.message.isEmpty {
                    Text(toast.message)
                        .font(messageFont)
                        .italic(theme.id == .ink)
                        .foregroundStyle(theme.id == .ink ? theme.ink.opacity(0.65) : theme.sub)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(theme.panel)
        .overlay(alignment: .leading) { rail }
        .overlay(border)
        // Clip first, THEN cast the shadow: a shadow drawn by the background
        // would be cut off by this very clip and the card would sit flat on
        // whatever screen it is floating over.
        .clipShape(RoundedRectangle(cornerRadius: cardRadius, style: .continuous))
        .shadow(color: shadowColor, radius: shadowRadius, y: shadowY)
        .padding(.horizontal, 12)
        .offset(y: min(drag, 0))
        .opacity(drag < 0 ? max(0, 1 + drag / 60) : 1)
        .contentShape(Rectangle())
        // A toast answers a tap the user already made; tapping it again means
        // "understood, go away" rather than "take me somewhere", so it never
        // navigates out from under the screen that caused it.
        .onTapGesture(perform: dismiss)
        .gesture(
            DragGesture(minimumDistance: 8)
                .onChanged { value in drag = min(0, value.translation.height) }
                .onEnded { value in
                    if value.translation.height < -24 { dismiss() } else { drag = 0 }
                }
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(toast.message.isEmpty ? toast.title
                                                  : "\(toast.title). \(toast.message)")
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(Text(copy.toastDismissHint(theme.id)))
        .accessibilityAction(named: Text(copy.toastDismiss(theme.id)), dismiss)
    }

    // MARK: Pieces

    /// The bot that was acted on wears its own face; an app- or gateway-level
    /// toast gets the kind glyph instead. Same rule the ledger row uses, so a
    /// toast and the row it becomes look like the same event.
    @ViewBuilder private var leading: some View {
        if let bot {
            AvatarView(bot: bot, size: 28, theme: theme)
                .overlay(alignment: .bottomTrailing) {
                    Circle()
                        .fill(kindColor)
                        .frame(width: 9, height: 9)
                        .overlay(Circle().strokeBorder(theme.panel, lineWidth: 1.5))
                        .offset(x: 2, y: 2)
                }
        } else {
            ZStack {
                switch theme.id {
                case .soft:
                    Circle().fill(kindColor.opacity(0.14)).frame(width: 28, height: 28)
                case .control:
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(kindColor.opacity(0.5), lineWidth: 1)
                        .frame(width: 26, height: 26)
                case .ink:
                    Circle().fill(kindColor).frame(width: 12, height: 12)
                        .overlay(Circle().inset(by: 2).stroke(theme.panel, lineWidth: 1.2))
                }
                if theme.id != .ink {
                    Text(glyph)
                        .font(theme.id == .control ? theme.mono(11, weight: .bold)
                                                   : theme.body(12, weight: .black))
                        .foregroundStyle(kindColor)
                }
            }
            .frame(width: 28, height: 28)
        }
    }

    /// The kind rail: a hairline of colour down the leading edge. Ink gets none
    /// — a ledger page marks importance with weight, not with paint.
    @ViewBuilder private var rail: some View {
        if theme.id != .ink {
            Rectangle()
                .fill(kindColor)
                .frame(width: theme.id == .control ? 2 : 3)
        }
    }

    /// Each pack's edge: soft keeps its hairline and lets the shadow do the
    /// lifting, control borders in the kind's own colour the way its panels do,
    /// and ink rules the note off — a note pinned to the page, not a
    /// proclamation.
    @ViewBuilder private var border: some View {
        switch theme.id {
        case .soft:
            RoundedRectangle(cornerRadius: cardRadius, style: .continuous)
                .strokeBorder(theme.line, lineWidth: 1)
        case .control:
            RoundedRectangle(cornerRadius: cardRadius, style: .continuous)
                .strokeBorder(kindColor.opacity(0.35), lineWidth: 1)
        case .ink:
            Rectangle().strokeBorder(theme.ink.opacity(0.45), lineWidth: 1)
        }
    }

    private var shadowColor: Color {
        // Control floats over a near-black terminal, so its lift has to come
        // from real black rather than from the ink token, which is the LIGHT
        // colour in that pack and would glow instead of lifting.
        theme.id == .control ? Color.black.opacity(0.55) : theme.ink.opacity(0.16)
    }

    private var shadowRadius: CGFloat { theme.id == .soft ? 14 : 12 }
    private var shadowY: CGFloat { theme.id == .soft ? 9 : 8 }

    private var cardRadius: CGFloat {
        switch theme.id {
        case .soft: 16
        case .control: 9
        case .ink: 0
        }
    }

    private var kindColor: Color {
        switch toast.kind {
        case .info:
            switch theme.id {
            // Control's `accent` and `ok` are the SAME green (Packs.swift), so a
            // plain accent here would paint the optimistic half and its
            // confirmation identically — and the glyph that would have told them
            // apart is replaced by the bot's face whenever a toast names one.
            // The dim form keeps the pack's voice while leaving "still going"
            // visibly short of "done".
            case .control: theme.accentFaint
            // Ink's `accent` is its `danger`: a plain statement of fact must not
            // be written in the colour this pack reserves for something going
            // wrong.
            case .ink: theme.ink
            case .soft: theme.accent
            }
        case .success: theme.ok
        case .warning: theme.warn
        case .failure: theme.danger
        }
    }

    /// Never a bare colour: colour alone is not a signal on a phone held at
    /// arm's length, and it is not a signal at all for a colour-blind reader.
    private var glyph: String {
        switch toast.kind {
        case .info: "·"
        case .success: "✓"
        case .warning: "!"
        case .failure: "×"
        }
    }

    private var titleFont: Font {
        switch theme.id {
        case .soft: theme.body(13, weight: .bold)
        case .control: theme.mono(11, weight: .bold)
        case .ink: theme.body(14.5, weight: .semibold)
        }
    }

    private var messageFont: Font {
        switch theme.id {
        case .soft: theme.body(12)
        case .control: theme.body(11.5)
        case .ink: theme.body(12.5)
        }
    }
}
