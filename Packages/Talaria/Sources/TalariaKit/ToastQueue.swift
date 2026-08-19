import Foundation

// ── The toast queue, as data ─────────────────────────────────────────────────
//
// Desktop Bot Mode answers every mutation out loud, always in the same two
// beats: say what is being attempted, then say what happened. `host.notify`
// fires on a pin (plugin.js:4056-4066), a duplicate (4079 / 4083 / 4085), a
// look save (5004 / 5038), a delete (7974).
//
// The half of that which is a *decision* rather than a drawing lives here, in
// TalariaKit, for the same reason `RosterSearch` and `BotCosmetics` do: it is
// the part `talaria-verify` can execute. Three rules hold the pairing together
// and every one of them has a wrong version that looks right:
//
//   * A second post under the same `key` REPLACES the first in place and keeps
//     its `id`, so the card morphs where it stands instead of flickering out
//     and back — and so the mirrored Activity row stays one row.
//   * Overflow drops the OLDEST, never the newest: the newest is the one the
//     user's thumb just caused.
//   * `settle` clears the key rather than rewriting the text. Clearing it is
//     what shortens `lifetime` from the long unconfirmed-pair hold to the
//     ordinary one, and it is what stops a late second answer reaching into a
//     card the user has already been shown as final.
//
// `ToastBus` (TalariaUI/Components/ToastBus.swift) is this queue plus the three
// things a value type cannot own: an `@Observable` array, one expiry Task per
// card, and the VoiceOver announcement.

/// What a toast is saying. Four levels rather than desktop's three
/// (`info`/`success`/`error`), because Talaria has a real fourth case: an
/// applied model switch that carried a non-fatal caution back from the gateway
/// (observed live — see AppModelLive+Toasts.swift).
public enum ToastKind: String, Sendable, Equatable {
    /// The optimistic half of a pair, or a plain statement of fact.
    case info
    /// It landed.
    case success
    /// It landed, but read this.
    case warning
    /// It did not land.
    case failure
}

/// One toast. `key` is the pairing handle: posting a second toast with the
/// same key replaces the first in place (and updates its ledger row) instead of
/// stacking a near-duplicate under it.
public struct Toast: Identifiable, Sendable, Equatable {
    public var id: UUID
    public var kind: ToastKind
    public var title: String
    public var message: String
    /// Whose action this was, for the avatar and the ledger row. nil = the app
    /// or the gateway itself.
    public var botID: String?
    public var key: String?
    public var at: Date
    /// nil = the per-kind default; 0 = sticky; positive = wire-provided TTL.
    public var durationMilliseconds: Int?

    public init(id: UUID = UUID(), kind: ToastKind, title: String, message: String = "",
                botID: String? = nil, key: String? = nil, at: Date = Date(),
                durationMilliseconds: Int? = nil) {
        self.id = id; self.kind = kind; self.title = title; self.message = message
        self.botID = botID; self.key = key; self.at = at
        self.durationMilliseconds = durationMilliseconds
    }

    /// How long it stays up. A failure is the one a user must have time to
    /// read; an unconfirmed optimistic half waits much longer than it looks,
    /// because its whole job is to be replaced by the confirmation — a pin that
    /// round-trips a sleeping tailnet can take seconds, and the toast blinking
    /// out first would leave the pair half-told.
    public var lifetime: Duration? {
        if let durationMilliseconds {
            if durationMilliseconds == 0 { return nil }
            if durationMilliseconds > 0 { return .milliseconds(durationMilliseconds) }
        }
        if kind == .info && key != nil { return .seconds(12) }
        switch kind {
        case .info, .success: return .seconds(3)
        case .warning: return .seconds(5)
        case .failure: return .seconds(6.5)
        }
    }
}

/// The pure transforms behind `ToastBus`. Every one of them takes the current
/// stack and hands back the next one, plus the ids whose expiry timer the
/// caller has to cancel — so the bus never has to reason about ordering twice.
public enum ToastQueue {

    /// Three is the point where a stack stops being readable on a phone.
    public static let maxVisible = 3

    /// How many settled-but-unclaimed pairs the caller's `lastPosted` book
    /// keeps. Bounded rather than aged: pairs settle in seconds.
    public static let pairMemoryLimit = 64

    public struct PostResult: Sendable, Equatable {
        /// The stack as it now stands, newest last.
        public var toasts: [Toast]
        /// The toast as it was filed — the caller mirrors these exact values
        /// into the Activity ledger, and schedules its expiry.
        public var filed: Toast
        /// Timers to cancel: a replaced card's own timer, or a dropped one's.
        public var retired: [UUID]
    }

    /// Post, or replace the open half of a pair.
    public static func post(_ toast: Toast, into toasts: [Toast]) -> PostResult {
        var stack = toasts
        var filed = toast
        var retired: [UUID] = []
        if let key = toast.key, let index = stack.firstIndex(where: { $0.key == key }) {
            // The confirmation of a pair: same slot, same identity, new words.
            // Keeping the id makes it an update instead of a remove+insert, so
            // the card morphs where it stands rather than flickering.
            filed.id = stack[index].id
            retired.append(filed.id)
            stack[index] = filed
        } else {
            stack.append(filed)
            if stack.count > maxVisible {
                // The oldest falls off rather than the newest being dropped,
                // because the newest is the one the thumb just caused.
                retired.append(stack.removeFirst().id)
            }
        }
        return PostResult(toasts: stack, filed: filed, retired: retired)
    }

    public struct CloseResult: Sendable, Equatable {
        public var toasts: [Toast]
        /// The card as it now reads, when one is still on screen and needs its
        /// expiry re-armed. nil when the pair was retracted or was already gone.
        public var rescheduled: Toast?
        public var retired: [UUID]
    }

    /// The optimistic half turned out to be the whole truth (a pin that simply
    /// worked). The card stays exactly as written — re-saying it would be the
    /// app congratulating itself — but it stops being an unanswered half, so it
    /// leaves on the ordinary clock instead of the long one a pair holds.
    public static func settle(key: String, in toasts: [Toast]) -> CloseResult {
        guard let index = toasts.firstIndex(where: { $0.key == key }) else {
            return CloseResult(toasts: toasts, rescheduled: nil, retired: [])
        }
        var stack = toasts
        var settled = stack[index]
        settled.key = nil
        stack[index] = settled
        return CloseResult(toasts: stack, rescheduled: settled, retired: [settled.id])
    }

    /// Take the optimistic half back off the screen — the outcome was real but
    /// not worth saying (an older gateway that cannot store cosmetics at all, a
    /// switch that parked its own dialog).
    public static func retract(key: String, in toasts: [Toast]) -> CloseResult {
        guard let index = toasts.firstIndex(where: { $0.key == key }) else {
            return CloseResult(toasts: toasts, rescheduled: nil, retired: [])
        }
        var stack = toasts
        let removed = stack.remove(at: index)
        return CloseResult(toasts: stack, rescheduled: nil, retired: [removed.id])
    }

    /// Remember the open half of a pair so a silent settle can still close its
    /// ledger row without the caller repeating itself.
    ///
    /// Bounded by evicting the OLDEST entry, not by emptying the book. The
    /// wholesale wipe this replaces was self-healing but wrong in exactly the
    /// case it was supposed to be cheap for: a pair in flight when the wipe
    /// landed lost its book-keeping, so its answer could not settle the
    /// mirrored row and the row stayed `pending` until the stale sweep found it
    /// five minutes later.
    public static func remember(_ toast: Toast, key: String,
                                in memory: [String: Toast]) -> [String: Toast] {
        var next = memory
        next[key] = toast
        while next.count > pairMemoryLimit {
            guard let oldest = next.min(by: { $0.value.at < $1.value.at })?.key else { break }
            next.removeValue(forKey: oldest)
        }
        return next
    }
}
