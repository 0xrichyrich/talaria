import Foundation

// Toast pairing — desktop's two-beat `host.notify` shape, pinned.
//
// The pairing is the only part of the toast bus that is a contract rather than a
// look, and it is load-bearing twice over: on screen it is what makes
// "Duplicating inbox…" become "Created inbox-2" in the same card, and in the
// Activity ledger it is what keeps ONE row per act instead of two rows arguing
// (AppModelLive+Toasts.swift mirrors under `toast:<key>`, and `recordActivity`'s
// key path updates in place).
//
// Four rules with plausible wrong versions:
//
//   * A replacement keeps the first card's `id`. Remove-and-insert would look
//     almost right — same text, same slot — and would flicker, retrigger the
//     entrance transition, and hand the ledger a second identity.
//   * A replacement keeps its POSITION. Moving the pair to the end would make a
//     stack of toasts reorder itself as answers land.
//   * Overflow drops the OLDEST. The newest is the one the thumb just caused.
//   * `settle` clears the key rather than rewriting the text — that is what
//     shortens the lifetime from the long unconfirmed-pair hold, and what stops
//     a late second answer reaching into a card already shown as final.

extension ProtocolChecks {

    static func toastPairing() throws {
        try toastReplacesInPlace()
        try toastStacksUnkeyed()
        try toastOverflowDropsOldest()
        try toastSettleAndRetract()
        try toastLifetimes()
        try toastPairMemoryEvictsOldest()
    }

    // MARK: One event, one card

    private static func toastReplacesInPlace() throws {
        let other = Toast(kind: .info, title: "unrelated")
        let opening = Toast(kind: .info, title: "Duplicating inbox…", key: "duplicate:inbox")
        var stack = ToastQueue.post(other, into: []).toasts
        stack = ToastQueue.post(opening, into: stack).toasts
        let trailing = Toast(kind: .info, title: "later")
        stack = ToastQueue.post(trailing, into: stack).toasts
        let openingID = stack[1].id

        let answer = Toast(kind: .success, title: "Created inbox-2 — full copy of inbox",
                           key: "duplicate:inbox")
        let result = ToastQueue.post(answer, into: stack)

        try expect(result.toasts.count == 3, "the confirmation replaces rather than stacks")
        try expect(result.toasts[1].id == openingID,
                   "…keeping the first card's id, so it morphs instead of flickering")
        try expect(result.filed.id == openingID, "…and the filed toast reports that same id")
        try expect(result.toasts[1].kind == .success, "…with the new words")
        try expect(result.toasts[2].title == "later", "…and without reordering the stack")
        try expect(result.retired == [openingID], "the replaced card's expiry timer is cancelled")
    }

    private static func toastStacksUnkeyed() throws {
        // Two unkeyed toasts are two events, however alike they read.
        var stack: [Toast] = []
        stack = ToastQueue.post(Toast(kind: .info, title: "same"), into: stack).toasts
        stack = ToastQueue.post(Toast(kind: .info, title: "same"), into: stack).toasts
        try expect(stack.count == 2, "keyless toasts never merge")
        try expect(stack[0].id != stack[1].id, "…and stay separate identities")
    }

    // MARK: Bounds

    private static func toastOverflowDropsOldest() throws {
        var stack: [Toast] = []
        for index in 1...ToastQueue.maxVisible {
            stack = ToastQueue.post(Toast(kind: .info, title: "t\(index)"), into: stack).toasts
        }
        let oldest = stack[0].id
        let result = ToastQueue.post(Toast(kind: .info, title: "newest"), into: stack)
        try expect(result.toasts.count == ToastQueue.maxVisible, "the stack stays readable")
        try expect(result.retired == [oldest], "the OLDEST card is the one dropped")
        try expect(result.toasts.last?.title == "newest",
                   "…never the one the user's thumb just caused")
    }

    // MARK: Closing a pair

    private static func toastSettleAndRetract() throws {
        let opening = Toast(kind: .info, title: "Pinning…", key: "pin:inbox")
        let stack = ToastQueue.post(opening, into: []).toasts

        let settled = ToastQueue.settle(key: "pin:inbox", in: stack)
        try expect(settled.toasts.count == 1, "settling leaves the card standing")
        try expect(settled.toasts[0].title == "Pinning…",
                   "…with its words unchanged — re-saying it would be the app congratulating itself")
        try expect(settled.toasts[0].key == nil,
                   "…and its key cleared, which is what shortens the lifetime")
        try expect(settled.rescheduled?.id == stack[0].id, "…so its expiry is re-armed")

        // A late second answer can no longer reach a card already shown as final.
        let late = ToastQueue.post(Toast(kind: .failure, title: "too late", key: "pin:inbox"),
                                   into: settled.toasts)
        try expect(late.toasts.count == 2, "a settled card is not replaceable by a late answer")

        let retracted = ToastQueue.retract(key: "pin:inbox", in: stack)
        try expect(retracted.toasts.isEmpty, "retracting takes the card back off screen")
        try expect(retracted.rescheduled == nil, "…with nothing left to expire")
        try expect(retracted.retired == [stack[0].id], "…and its timer cancelled")

        // Both are no-ops on a key that was never posted (or was dismissed by a
        // thumb), rather than throwing the caller off.
        try expect(ToastQueue.settle(key: "absent", in: stack).toasts.count == 1,
                   "settling an unknown key changes nothing")
        try expect(ToastQueue.retract(key: "absent", in: stack).toasts.count == 1,
                   "retracting an unknown key changes nothing")
    }

    // MARK: How long a card holds

    private static func toastLifetimes() throws {
        let unconfirmed = Toast(kind: .info, title: "Duplicating…", key: "duplicate:x")
        try expect(unconfirmed.lifetime == .seconds(12),
                   "an unanswered optimistic half holds long enough to be replaced")
        var answered = unconfirmed
        answered.key = nil
        try expect(answered.lifetime == .seconds(3), "clearing the key returns it to the short clock")
        try expect(Toast(kind: .info, title: "plain").lifetime == .seconds(3),
                   "a keyless statement of fact is short")
        try expect(Toast(kind: .success, title: "done").lifetime == .seconds(3), "success is short")
        try expect(Toast(kind: .warning, title: "note").lifetime == .seconds(5),
                   "a caution needs longer")
        try expect(Toast(kind: .failure, title: "no").lifetime == .seconds(6.5),
                   "a failure is the one a user must have time to read")
        try expect(Toast(kind: .info, title: "sticky", durationMilliseconds: 0).lifetime == nil,
                   "a sticky gateway notice never schedules expiry")
        try expect(Toast(kind: .info, title: "ttl", durationMilliseconds: 8_000).lifetime
                    == .milliseconds(8_000), "a gateway TTL overrides the per-kind default")
    }

    // MARK: The pair book

    /// Regression guard. This book used to be bounded by emptying it wholesale,
    /// which was self-healing but wrong in exactly the case it was cheap for: a
    /// pair in flight when the wipe landed lost its entry, so its answer could
    /// not settle the mirrored ledger row and that row stayed `pending` until the
    /// stale sweep found it five minutes later.
    private static func toastPairMemoryEvictsOldest() throws {
        var memory: [String: Toast] = [:]
        let base = Date(timeIntervalSince1970: 1_000_000)
        for index in 0..<ToastQueue.pairMemoryLimit {
            let toast = Toast(kind: .info, title: "t\(index)", key: "k\(index)",
                              at: base.addingTimeInterval(Double(index)))
            memory = ToastQueue.remember(toast, key: "k\(index)", in: memory)
        }
        try expect(memory.count == ToastQueue.pairMemoryLimit, "the book fills to its bound")

        let inFlight = Toast(kind: .info, title: "in flight", key: "live",
                             at: base.addingTimeInterval(9_999))
        memory = ToastQueue.remember(inFlight, key: "live", in: memory)
        try expect(memory.count == ToastQueue.pairMemoryLimit, "…and stays there")
        try expect(memory["k0"] == nil, "the OLDEST entry is the one evicted")
        try expect(memory["live"] != nil,
                   "…so a pair still in flight keeps the book-keeping its answer needs")
        try expect(memory["k1"] != nil, "…and the rest of the book survives the eviction")
    }
}
