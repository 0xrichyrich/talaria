import Foundation
import SwiftUI
import TalariaKit
import TalariaTheme

// ── Optimistic-then-confirm, for every mutation a thumb can start ────────────
//
// Desktop Bot Mode never lets a mutation happen in silence. Its pattern is
// always the same two beats — say what is being attempted, then say what the
// gateway actually did — and the plugin's own copy is used verbatim here
// wherever it exists:
//
//   pin        plugin.js:4056-4066  "<name> pinned to top" / "unpinned"
//   duplicate  plugin.js:4079       "Duplicating <name>…"
//              plugin.js:4083       "Created <new> — full copy of <src>"
//              plugin.js:4085       notifyError "Duplicate failed"
//   look save  plugin.js:5004       "Saved look locally; remote persistence failed"
//              plugin.js:5038       "<name> updated"
//              plugin.js:4999-5002  …and NOTHING at all on an older gateway,
//                                   because an error there would fire on every
//                                   save forever.
//   delete     plugin.js:7974       "Deleted profile <name>"
//
// Talaria had the mutations and none of the telling: the only banner slot is
// gated on `demoDataLoaded` (RootView.swift:82), so on a real gateway a pin
// that the gateway rejected simply slid back with no explanation.
//
// Two rules hold this file together:
//
// 1. **One event, one row.** The optimistic toast and its confirmation share a
//    `key`, so the card morphs in place and the Activity ledger keeps a single
//    row that goes from pending to settled — not two rows saying nearly the
//    same thing. `recordActivity`'s key-update path (AppModelLive+Feeds.swift)
//    is exactly this contract, reused rather than reinvented; the card half is
//    `TalariaKit/ToastQueue`, where `talaria-verify` executes the same pairing.
// 2. **Only live mutations are history.** Demo mode gets the toast (the feel
//    is the product) but never a ledger row: the journal is persisted, and a
//    demo pin must not still be in the ledger when a real gateway connects.
//    `recordActivity` itself has no mode guard — sixteen call sites reach it —
//    so the guard is `toast()`'s own, below, and it is the only thing standing
//    between a demo pin and a persisted journal.
//
// ── Verified against the live gateway (0.20.3), 2026-08-18 ──────────────────
//
// Every branch below keys off an outcome that was observed, not assumed:
//
//   profiles.configure, oversize ui_meta →
//     {"ok": false, "applied": {"ui_meta": false}}          → .failed
//   profiles.configure, block written    →
//     {"ok": true,  "applied": {"ui_meta": true}}           → .persisted
//   profiles.configure, unknown profile  → error 4064       → .failed
//     (methods_profiles.py:687-731 — the size cap rejects BEFORE any write,
//      which is what made the failure probe non-destructive)
//   config.set key=model, applied        →
//     {"key":"model","value":"gpt-5.6-sol","warning":"","confirm_required":
//      false,"confirm_message":"","scope":"session"}        → .applied
//   config.set key=model, applied with a caution →
//     warning: "Note: `claude-opus-4-1-20250805` was not found in Anthropic's
//     /v1/models listing…", confirm_required: false         → .applied(warning:)
//   config.set key=model, bad provider   → error 5001 + message → .failed
//   cron.manage remove, unknown job      →
//     {"success": false, "error": "Job with ID or name '…' not found…"}
//     (a tool failure inside a successful envelope — GatewayClient+Cron.swift
//      turns it into GatewayError 5023)                     → .failure
//   session.delete, unknown id           → error 4007       → treated as gone
//
// Not observed live, and marked as such: `confirm_required: true` (the guard
// did not fire for any model this gateway can actually reach — server.py:
// 11868-11884 is the branch), and `deferred: true`, which only exists on the
// busy-session stash path (server.py:11776-11787). Both are handled below
// from the Python rather than from a captured payload.

// MARK: - The bus, in the model's voice

public extension AppModel {

    /// Say something. The one entry point every mutation reports through.
    ///
    /// - Parameters:
    ///   - kind: how it reads — `.info` for the optimistic half, then
    ///     `.success` / `.warning` / `.failure` for what actually happened.
    ///   - key: pairs the two halves. The second post with the same key
    ///     replaces the first card in place and updates its ledger row rather
    ///     than appending a near-duplicate.
    ///   - ledger: mirror this into the Activity feed. Default true — the
    ///     point of the phase is that the ledger stops being a demo artifact —
    ///     but a purely cosmetic nudge can opt out.
    func toast(kind: ToastKind, title: String, message: String = "",
               botID: String? = nil, key: String? = nil, ledger: Bool = true,
               durationMilliseconds: Int? = nil) {
        let filed = ToastBus.shared.post(Toast(kind: kind, title: title, message: message,
                                               botID: botID, key: key,
                                               durationMilliseconds: durationMilliseconds))
        guard ledger, mode == .live else { return }
        recordActivity(kind: botID == nil ? .gateway : .task,
                       botID: botID ?? "gateway",
                       text: filed.title,
                       subtext: filed.message,
                       // An unanswered optimistic half is genuinely pending —
                       // the ledger's own chip (PEND / wax seal) already says
                       // exactly that, and the confirmation clears it.
                       pending: filed.kind == .info && filed.key != nil,
                       key: filed.key.map { "toast:\($0)" })
    }

    /// The optimistic half was the whole truth — a pin that simply took. The
    /// card stands (and expires on its own), the ledger row loses its pending
    /// chip, and nothing is said twice.
    func settleToast(key: String) {
        settleLedger(for: ToastBus.shared.settle(key: key), key: key)
    }

    /// Close a pair by taking the card back. The outcome was real, but saying
    /// it would be noise on every single save (plugin.js:4999-5002 makes the
    /// same call for the same reason). The ledger row stays, minus its pending
    /// chip — the act happened, it simply has nothing more to report.
    func retractToast(key: String) {
        settleLedger(for: ToastBus.shared.retract(key: key), key: key)
    }

    private func settleLedger(for optimistic: Toast?, key: String) {
        guard let optimistic, mode == .live else { return }
        recordActivity(kind: optimistic.botID == nil ? .gateway : .task,
                       botID: optimistic.botID ?? "gateway",
                       text: optimistic.title, subtext: optimistic.message,
                       pending: false, key: "toast:\(key)")
    }

    /// Drop every card on screen. For the two moments where a toast would be
    /// answering for a world that no longer exists: leaving the demo world, and
    /// switching gateways mid-write.
    func clearToasts() { ToastBus.shared.clear() }

    /// Render the gateway's driver-agnostic notice stream. These are account or
    /// provider status, not mutations initiated by this app, so they never add
    /// a second row to the Activity ledger.
    func showAgentNotice(_ payload: NotificationPayload) {
        guard let notice = AgentNoticePolicy.presentation(payload) else { return }
        let kind: ToastKind
        switch notice.level.lowercased() {
        case "error": kind = .failure
        case "success": kind = .success
        case "warn", "warning": kind = .warning
        default: kind = .info
        }
        toast(kind: kind, title: notice.title, message: notice.detail,
              key: notice.key.map { "agent-notice:\($0)" }, ledger: false,
              durationMilliseconds: notice.durationMilliseconds)
    }

    /// `notification.clear` names the same key used by `notification.show`.
    func clearAgentNotice(_ key: String) {
        guard !key.isEmpty else { return }
        _ = ToastBus.shared.retract(key: "agent-notice:\(key)")
    }

    /// A background prompt finished while its initiating surface may be gone.
    /// The event is global notification traffic, so make it visible and keep a
    /// durable row; the task id pairs repeat completion frames without stacking.
    func reportBackgroundCompletion(taskID: String, text: String, botID: String?) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        toast(kind: .success,
              title: theme.copy.toastBackgroundComplete(theme.themeID),
              message: ActivityNotice.clip(clean, to: ActivityNotice.replyLimit),
              botID: botID,
              key: taskID.isEmpty ? nil : "background:\(taskID)")
    }

    /// Clear pending flags on mutation rows whose answer can never arrive.
    ///
    /// The ledger is persisted, and the confirmation half lives in memory: kill
    /// the app while a pin is in flight (or lose the link mid-write) and the
    /// row comes back on the next launch still marked pending, pulsing its wax
    /// seal at an event that finished being uncertain hours ago. Anything older
    /// than the grace window is settled to what it actually is — an attempt
    /// this app never heard the end of.
    ///
    /// Only rows this file wrote (`toast:` keys) are touched; an approval that
    /// is genuinely still waiting for a human keeps its chip forever, which is
    /// the whole point of that chip.
    func settleStalePendingToasts(olderThan grace: TimeInterval = 300) {
        guard mode == .live else { return }
        let cutoff = Date().addingTimeInterval(-grace)
        let stale = FeedsRuntime.shared.journal.filter {
            $0.pending && $0.at < cutoff && ($0.key?.hasPrefix("toast:") ?? false)
        }
        for row in stale {
            // Written back through `recordActivity`'s own key path rather than
            // by mutating the journal in place: one owner for that array, one
            // save, one publish.
            recordActivity(kind: row.kind, botID: row.botID, text: row.text,
                           subtext: row.subtext, pending: false, key: row.key)
        }
    }
}

// MARK: - Ledger provenance

public extension AppModel {

    /// How many rows the persisted ledger is actually holding, for Activity's
    /// footnote. Read off the journal rather than counting `activity`, because
    /// the screen groups by day and the honest number is rows, not groups.
    var activityRowCount: Int { FeedsRuntime.shared.journal.count }

    /// The cap the journal rolls at (AppModelLive+Feeds.swift), surfaced so the
    /// footnote can say "newest 200" without hard-coding it twice.
    var activityRowLimit: Int { FeedsRuntime.journalLimit }
}

// MARK: - Pin

public extension AppModel {

    /// Pin / unpin with the plugin's own two beats.
    ///
    /// Desktop toasts optimistically at select time (plugin.js:4056-4066) and
    /// never reports the write, because its plugin-local store keeps the pin
    /// regardless. Talaria has no local store — `setBotPinned` reverts the row
    /// when the write fails (AppModelLive+Cosmetics.swift) — so the failure
    /// half exists here to explain a row that just slid back under the thumb.
    @discardableResult
    func pinBotWithFeedback(botID: String, pinned: Bool) async -> CosmeticsWrite {
        let name = botName(botID, theme.themeID)
        let key = "pin:\(botID)"
        feedback(pinned ? .pin : .unpin)
        toast(kind: .info,
              title: pinned ? theme.copy.toastPinned(name, theme.themeID)
                            : theme.copy.toastUnpinned(name, theme.themeID),
              botID: botID, key: key)

        let outcome = await setBotPinned(botID: botID, pinned: pinned)
        switch outcome {
        case .persisted:
            // The optimistic line was the whole truth; let it stand and settle
            // its ledger row. Re-toasting "pinned" a second time would be the
            // app congratulating itself.
            settleToast(key: key)
        case .unsupported:
            // An older gateway keeps no ui_meta, so the pin is this device's
            // alone — but it IS pinned here, which is what the card says.
            settleToast(key: key)
        case .failed:
            toast(kind: .failure,
                  title: theme.copy.toastPinFailed(name, theme.themeID),
                  message: theme.copy.toastPinFailedBody(theme.themeID),
                  botID: botID, key: key)
        }
        return outcome
    }
}

// MARK: - Duplicate

public extension AppModel {

    /// Duplicate, narrated: "Duplicating inbox…" → "Created inbox-2 — full
    /// copy of inbox" (plugin.js:4079-4085), or the failure in its place.
    ///
    /// - Returns: the new profile id, or nil when the clone did not happen.
    @discardableResult
    func duplicateBotWithFeedback(from sourceID: String) async -> String? {
        let name = botName(sourceID, theme.themeID)
        let newID = cloneID(for: sourceID)
        let key = "duplicate:\(sourceID)"
        toast(kind: .info, title: theme.copy.toastDuplicating(name, theme.themeID),
              botID: sourceID, key: key)

        guard await duplicateProfile(from: sourceID, to: newID) else {
            toast(kind: .failure, title: theme.copy.toastDuplicateFailed(theme.themeID),
                  message: theme.copy.toastDuplicateFailedBody(name, theme.themeID),
                  botID: sourceID, key: key)
            return nil
        }
        let newRosterID: String
        if let sourceRoute = profileRoute(for: sourceID),
           sourceRoute.gatewayID != LiveRuntime.shared.gatewayID {
            newRosterID = GatewayBotRoute(gatewayID: sourceRoute.gatewayID,
                                          profile: newID).qualifiedID
        } else {
            newRosterID = newID
        }
        // Filed under the CLONE, not the source: the act being reported is the
        // new profile existing. Primary clones are already in `bots`; remote
        // clones use the qualified id whose secondary-roster refresh just
        // completed, so neither can collide with the other gateway's row.
        toast(kind: .success,
              title: theme.copy.toastDuplicated(newID, from: name, theme.themeID),
              botID: newRosterID, key: key)
        return newRosterID
    }
}

// MARK: - Cosmetic save

public extension AppModel {

    /// A look save, with desktop's exact three-way ending: silence on a legacy
    /// gateway, "<name> updated" on a real write, and the local-only warning
    /// when the gateway speaks the contract and says the write did not apply.
    ///
    /// Live-verified: `applied.ui_meta` came back `true` for a stored block and
    /// `false` for a rejected one on gateway 0.20.3 — the two branches below
    /// are that answer, not an inference from the Python.
    @discardableResult
    func saveBotLookWithFeedback(botID: String, shape: AvatarShape, hue: AvatarHue,
                                 title: String?) async -> CosmeticsWrite {
        let key = "look:\(botID)"
        // The look is already on screen (`applyLookLocally`), so the optimistic
        // half reports the SAVE, not the change — the change needs no toast to
        // be believed.
        toast(kind: .info, title: theme.copy.toastSavingLook(theme.themeID),
              botID: botID, key: key)

        let outcome = await saveBotLook(botID: botID, shape: shape, hue: hue, title: title)
        // Resolved after the write: an edited title changes the name this
        // toast should use, and the roster row has it by now.
        let name = botName(botID, theme.themeID)
        switch outcome {
        case .persisted:
            toast(kind: .success, title: theme.copy.toastLookSaved(name, theme.themeID),
                  botID: botID, key: key)
        case .unsupported:
            // plugin.js:4999-5002 — this gateway cannot store ui_meta at all;
            // an error here would fire on every save on that setup forever.
            retractToast(key: key)
        case .failed:
            toast(kind: .failure, title: theme.copy.toastLookFailed(theme.themeID),
                  message: theme.copy.toastLookFailedBody(theme.themeID),
                  botID: botID, key: key)
        }
        return outcome
    }
}

// MARK: - Deletes

public extension AppModel {

    /// Delete a stored session, narrated. `deleteStoredSession` answers with
    /// nil on success or a themed reason (4023 "still live", an unreachable
    /// link); 4007 is already folded into success there, because a row that is
    /// gone is the outcome the user asked for.
    ///
    /// Returns that same `String?`, deliberately: this runs from inside a
    /// sheet, and a toast posted by the root host cannot be seen over one. The
    /// caller keeps its own inline banner for the failure a user is looking
    /// straight at, while the toast and its ledger row carry the outcome out
    /// past the sheet's dismissal.
    @discardableResult
    func deleteSessionWithFeedback(_ id: String, botID: String,
                                   title: String = "") async -> String? {
        let key = "session-delete:\(id)"
        let label = title.trimmingCharacters(in: .whitespacesAndNewlines)
        toast(kind: .info, title: theme.copy.toastDeleting(theme.themeID),
              message: label, botID: botID, key: key)

        if let reason = await deleteStoredSession(id, botID: botID) {
            toast(kind: .failure, title: theme.copy.toastDeleteFailed(theme.themeID),
                  message: reason, botID: botID, key: key)
            return reason
        }
        toast(kind: .success, title: theme.copy.toastSessionDeleted(theme.themeID),
              message: label, botID: botID, key: key)
        return nil
    }

    /// Delete a routine, narrated. `cron.manage` reports its own failures
    /// inside a successful RPC envelope (`{"success": false, "error": …}`,
    /// observed live) — GatewayClient+Cron.swift raises those as GatewayError,
    /// so the message the user reads is the gateway's own words.
    ///
    /// Returns nil on success or the themed reason, matching
    /// `deleteSessionWithFeedback`: a caller that keeps an inline error line
    /// beside the row must not lose the gateway's sentence to a toast the user
    /// may have already flicked away.
    @discardableResult
    func deleteRoutineWithFeedback(_ routine: Routine) async -> String? {
        let key = "routine-delete:\(routine.id)"
        toast(kind: .info, title: theme.copy.toastDeleting(theme.themeID),
              message: routine.name, botID: routine.botID, key: key)
        do {
            try await deleteRoutine(routine)
            toast(kind: .success, title: theme.copy.toastRoutineDeleted(theme.themeID),
                  message: routine.name, botID: routine.botID, key: key)
            return nil
        } catch {
            let reason = Self.reason(error)
            toast(kind: .failure, title: theme.copy.toastDeleteFailed(theme.themeID),
                  message: reason, botID: routine.botID, key: key)
            return reason
        }
    }
}

// MARK: - Routines

public extension AppModel {

    /// Schedule a routine, narrated — plugin.js:6500 `Cronjob "<title>"
    /// scheduled`. Until this existed a user got a toast when they DELETED a
    /// routine and silence when they made one, which is the wrong way round:
    /// the delete is confirmed by the row vanishing, and the create by a screen
    /// that pops back to a list the new row may not have reached yet.
    ///
    /// Rethrows, deliberately: the editor keeps the gateway's sentence on its
    /// own error line for the failure the user is looking straight at, and it
    /// stays on screen with the typing intact.
    func scheduleRoutineWithFeedback(botID: String, title: String, schedule: String,
                                     instruction: String, repeatForever: Bool = true,
                                     continuity: Bool = false, deliver: [String] = [],
                                     model: String? = nil, provider: String? = nil,
                                     reasoningEffort: String? = nil) async throws {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = "routine-add:\(botID):\(clean)"
        toast(kind: .info, title: theme.copy.toastSchedulingRoutine(clean, theme.themeID),
              botID: botID, key: key)
        do {
            try await scheduleRoutine(botID: botID, title: clean, schedule: schedule,
                                      instruction: instruction, repeatForever: repeatForever,
                                      continuity: continuity, deliver: deliver,
                                      model: model, provider: provider,
                                      reasoningEffort: reasoningEffort)
            toast(kind: .success, title: theme.copy.toastRoutineScheduled(clean, theme.themeID),
                  botID: botID, key: key)
        } catch {
            // `scheduleRoutine` raises -4 for the one half-landed case: the job
            // EXISTS and will fire, only its delivery route or model pin did
            // not take. Reporting that as a failure would tell the user to
            // schedule it again and give them two.
            let reason = Self.reason(error)
            let partial = (error as? GatewayError)?.code == -4
            toast(kind: partial ? .warning : .failure,
                  title: partial ? theme.copy.toastRoutineScheduled(clean, theme.themeID)
                                 : theme.copy.toastRoutineScheduleFailed(theme.themeID),
                  message: reason, botID: botID, key: key)
            throw error
        }
    }

    /// Save an edited routine — plugin.js:6177 `notifyError(err, 'Cronjob
    /// update failed')`, with the success half desktop leaves to its own
    /// re-render.
    func saveRoutineWithFeedback(_ job: CronJobDetail, routineID: String,
                                 botID: String, title: String,
                                 schedule: String, instruction: String, deliver: [String]?,
                                 model: String?, provider: String?,
                                 reasoningEffort: String? = nil,
                                 continuity: Bool?) async throws {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = "routine-save:\(routineID)"
        toast(kind: .info, title: theme.copy.toastSavingRoutine(clean, theme.themeID),
              botID: botID, key: key)
        do {
            try await saveRoutine(job, routineID: routineID, botID: botID,
                                  title: clean, schedule: schedule,
                                  instruction: instruction, deliver: deliver, model: model,
                                  provider: provider, reasoningEffort: reasoningEffort,
                                  continuity: continuity)
            toast(kind: .success, title: theme.copy.toastRoutineSaved(clean, theme.themeID),
                  botID: botID, key: key)
        } catch {
            toast(kind: .failure, title: theme.copy.toastRoutineUpdateFailed(theme.themeID),
                  message: Self.reason(error), botID: botID, key: key)
            throw error
        }
    }
}

// MARK: - Profiles

public extension AppModel {

    /// Create a profile, narrated — plugin.js:5426 `Agent "<name>" created`,
    /// plugin.js:5651 `Could not create the profile yet`.
    ///
    /// The create sheet keeps its own inline error (it must: the user's typing
    /// is on screen and they need it back), but a create that FAILS on a real
    /// gateway used to say nothing anywhere durable, and a create that SUCCEEDS
    /// dismissed the sheet onto a roster where the new row had not landed yet.
    @discardableResult
    func createBotProfileWithFeedback(id: String, job: String, soul: String,
                                      model: ModelChoice?, disabledSkills: [String],
                                      enabledToolsets: [String]?, uiMeta: JSONValue,
                                      gatewayID: String? = nil) async -> Bool {
        let key = "create:\(id)"
        toast(kind: .info, title: theme.copy.toastCreatingBot(id, theme.themeID), key: key)
        let result = await createBotProfile(id: id, job: job, soul: soul, model: model,
                                            disabledSkills: disabledSkills,
                                            enabledToolsets: enabledToolsets, uiMeta: uiMeta,
                                            gatewayID: gatewayID)
        guard result != .failed else {
            toast(kind: .failure, title: theme.copy.toastBotCreateFailed(theme.themeID),
                  key: key)
            return false
        }
        // Filed under the new profile now that it exists. Primary creation
        // appends its rich row; remote creation refreshes the qualified thin
        // row before returning.
        let rosterID: String
        if let gatewayID, gatewayID != LiveRuntime.shared.gatewayID {
            rosterID = GatewayBotRoute(gatewayID: gatewayID, profile: id).qualifiedID
        } else {
            rosterID = id
        }
        if result == .partial {
            toast(kind: .warning,
                  title: theme.copy.toastBotCreatedPartial(id, theme.themeID),
                  botID: rosterID, key: key)
        } else {
            toast(kind: .success,
                  title: theme.copy.toastBotCreated(botName(id, theme.themeID), theme.themeID),
                  botID: rosterID, key: key)
        }
        return true
    }

    /// Save a profile edit. `saveProfileEdit` answers with a bare Bool and
    /// every caller treated `false` as "keep the sheet open" — true, but on a
    /// gateway that refused the write the sheet showed no reason, and once it
    /// WAS closed there was nothing left anywhere saying the edit had not
    /// landed.
    @discardableResult
    func saveProfileEditWithFeedback(botID: String, edit: ProfileEdit) async -> Bool {
        let key = "profile-save:\(botID)"
        toast(kind: .info, title: theme.copy.toastSavingProfile(theme.themeID),
              botID: botID, key: key)
        guard await saveProfileEdit(botID: botID, edit: edit) else {
            toast(kind: .failure,
                  title: theme.copy.toastProfileSaveFailed(botName(botID, theme.themeID),
                                                           theme.themeID),
                  botID: botID, key: key)
            return false
        }
        // Resolved after the write: an edited title changes the name to use.
        toast(kind: .success,
              title: theme.copy.toastLookSaved(botName(botID, theme.themeID), theme.themeID),
              botID: botID, key: key)
        return true
    }
}

// MARK: - Sessions (rename)

public extension AppModel {

    /// Rename a stored session, narrated. Returns the same `String?` the
    /// unwrapped call does — the sheet keeps its inline banner, because a toast
    /// posted by the root host cannot be seen over a sheet.
    @discardableResult
    func renameSessionWithFeedback(_ id: String, botID: String, to title: String) async -> String? {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = "session-rename:\(id)"
        toast(kind: .info, title: theme.copy.toastRenaming(theme.themeID),
              message: clean, botID: botID, key: key)
        if let reason = await renameStoredSession(id, botID: botID, to: title) {
            toast(kind: .failure, title: theme.copy.toastRenameFailed(theme.themeID),
                  message: reason, botID: botID, key: key)
            return reason
        }
        toast(kind: .success, title: theme.copy.toastSessionRenamed(theme.themeID),
              message: clean, botID: botID, key: key)
        return nil
    }
}

// MARK: - Model switch

public extension AppModel {

    /// Switch the model, narrated. The gateway has four answers and they are
    /// genuinely different events, so each gets its own ending:
    ///
    ///  · applied, no warning   → success, naming the model that is now live
    ///  · applied, with warning → the same, in the warning voice, carrying the
    ///    gateway's own sentence (live-observed: an unlisted snapshot id comes
    ///    back applied WITH a caution, not rejected)
    ///  · deferred              → info: it lands when the running turn settles
    ///    (server.py:11776-11787 — a mid-turn swap would race the worker)
    ///  · confirm_required      → nothing said. The picker parks its own
    ///    confirmation dialog (`pendingConfirmation`), and a toast beside a
    ///    dialog asking the same question is noise.
    ///  · failed                → failure, in the gateway's words
    @discardableResult
    func switchModelWithFeedback(botID: String, provider: String,
                                 model: String) async -> ModelSelectionResult {
        let key = "model:\(botID)"
        let label = ModelLabels.displayName(model)
        toast(kind: .info, title: theme.copy.toastSwitchingModel(label, theme.themeID),
              botID: botID, key: key)

        let result = await selectModel(botID: botID, provider: provider, model: model)
        reportModelSwitch(result, botID: botID, key: key, fallbackLabel: label)
        return result
    }

    /// The collapsed-family picker owns variant-fast resolution and preset
    /// replay, so it needs its own narrated entry point rather than bypassing
    /// those rules through `switchModelWithFeedback`.
    @discardableResult
    func switchModelFamilyWithFeedback(botID: String, provider: ModelProviderRow,
                                       family: ModelFamily) async -> ModelSelectionResult {
        let key = "model:\(botID)"
        let requested = ModelLabels.displayName(family.id)
        toast(kind: .info, title: theme.copy.toastSwitchingModel(requested, theme.themeID),
              botID: botID, key: key)

        let result = await selectModelFamily(botID: botID, provider: provider, family: family)
        let selected = modelPicker(for: botID).catalog.model
        let resolved = selected.isEmpty ? requested : ModelLabels.displayName(selected)
        reportModelSwitch(result, botID: botID, key: key, fallbackLabel: resolved)
        return result
    }

    /// The same narration for the re-send that clears the expensive-model
    /// guard — the user has answered the dialog, so this one is allowed to
    /// have an ending.
    @discardableResult
    func confirmModelSwitchWithFeedback(botID: String) async -> ModelSelectionResult {
        let key = "model:\(botID)"
        let pending = modelPicker(for: botID).pendingConfirmation
        let label = ModelLabels.displayName(pending?.model ?? "")
        toast(kind: .info, title: theme.copy.toastSwitchingModel(label, theme.themeID),
              botID: botID, key: key)

        let result = await confirmPendingModel(botID: botID)
        reportModelSwitch(result, botID: botID, key: key, fallbackLabel: label)
        return result
    }

    private func reportModelSwitch(_ result: ModelSelectionResult, botID: String,
                                   key: String, fallbackLabel: String) {
        switch result {
        case .applied(let warning) where warning.isEmpty:
            toast(kind: .success,
                  title: theme.copy.toastModelSwitched(fallbackLabel, theme.themeID),
                  botID: botID, key: key)
        case .applied(let warning):
            toast(kind: .warning,
                  title: theme.copy.toastModelSwitched(fallbackLabel, theme.themeID),
                  message: warning, botID: botID, key: key)
        case .deferred(let model):
            toast(kind: .info,
                  title: theme.copy.toastModelDeferred(ModelLabels.displayName(model), theme.themeID),
                  message: theme.copy.toastModelDeferredBody(theme.themeID),
                  botID: botID, key: key)
            // An `.info` ending is still an ending: settle it so it leaves on
            // the short clock instead of sitting there like a half-told pair.
            settleToast(key: key)
        case .needsConfirmation:
            // The sheet is already asking; do not ask twice.
            retractToast(key: key)
        case .failed(let message):
            toast(kind: .failure, title: theme.copy.toastModelFailed(theme.themeID),
                  message: message, botID: botID, key: key)
        }
    }

    /// Reasoning effort is a session mutation just like a model switch. Keep
    /// the picker's inline warning, while also pairing the attempted value with
    /// its durable outcome for the user who closes the sheet immediately.
    @discardableResult
    func setReasoningEffortWithFeedback(botID: String, effort: String,
                                        provider: String = "", model: String = "") async -> String? {
        let key = "effort:\(botID)"
        let label = ModelLabels.effortLabel(effort)
        toast(kind: .info, title: theme.copy.toastEffortSet(label, theme.themeID),
              botID: botID, key: key)
        if let reason = await applyReasoningEffort(botID: botID, effort: effort,
                                                   provider: provider, model: model) {
            toast(kind: .failure, title: theme.copy.toastEffortFailed(theme.themeID),
                  message: reason, botID: botID, key: key)
            return reason
        }
        toast(kind: .success, title: theme.copy.toastEffortSet(label, theme.themeID),
              botID: botID, key: key)
        return nil
    }
}

// MARK: - Copy
//
// Nothing here is a string CopyPack already owns. Soft speaks the plugin's own
// sentences (they are already warm and plain); control reports them as a
// machine would; ink writes them into the ledger it thinks it is keeping.

public extension CopyPack {

    // Pin — plugin.js:4056-4066.
    
    func toastTranscriptActFailed(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Could not rewind that turn"
        case .control: "TRANSCRIPT ACT FAILED"
        case .ink: "the earlier hour would not return"
        }
    }

    func toastScratchFailed(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Couldn’t start a new chat"
        case .control: "SCRATCH SESSION FAILED"
        case .ink: "A throwaway conversation would not open"
        }
    }

func toastPinned(_ name: String, _ t: ThemeID) -> String {
        switch t {
        case .soft: "\(name) pinned to top"
        case .control: "\(name.uppercased()) PINNED"
        case .ink: "\(name) raised to the head of the page"
        }
    }

    func toastUnpinned(_ name: String, _ t: ThemeID) -> String {
        switch t {
        case .soft: "\(name) unpinned"
        case .control: "\(name.uppercased()) UNPINNED"
        case .ink: "\(name) returned to its place"
        }
    }

    func toastPinFailed(_ name: String, _ t: ThemeID) -> String {
        switch t {
        case .soft: "Couldn’t pin \(name)"
        case .control: "PIN REJECTED — \(name.uppercased())"
        case .ink: "\(name) would not stay raised"
        }
    }

    func toastPinFailedBody(_ t: ThemeID) -> String {
        switch t {
        case .soft: "The gateway refused the write, so the row moved back."
        case .control: "GATEWAY REFUSED THE WRITE · ROW REVERTED"
        case .ink: "The gateway would not take the mark; the row has gone back."
        }
    }

    // Duplicate — plugin.js:4079 / 4083 / 4085.
    func toastDuplicating(_ name: String, _ t: ThemeID) -> String {
        switch t {
        case .soft: "Duplicating \(name)…"
        case .control: "CLONING \(name.uppercased())…"
        case .ink: "Copying \(name)…"
        }
    }

    func toastDuplicated(_ newID: String, from name: String, _ t: ThemeID) -> String {
        switch t {
        case .soft: "Created \(newID) — full copy of \(name)"
        case .control: "CREATED \(newID.uppercased()) · FULL COPY"
        case .ink: "\(newID) written — a true copy of \(name)"
        }
    }

    func toastDuplicateFailed(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Duplicate failed"
        case .control: "CLONE FAILED"
        case .ink: "The copy was not made"
        }
    }

    func toastDuplicateFailedBody(_ name: String, _ t: ThemeID) -> String {
        switch t {
        case .soft: "\(name) is unchanged — nothing was created."
        case .control: "\(name.uppercased()) UNCHANGED · NOTHING CREATED"
        case .ink: "\(name) stands as it was; nothing was born."
        }
    }

    // Cosmetic save — plugin.js:5004 / 5038.
    func toastSavingLook(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Saving the look…"
        case .control: "WRITING APPEARANCE…"
        case .ink: "Setting down the likeness…"
        }
    }

    func toastLookSaved(_ name: String, _ t: ThemeID) -> String {
        switch t {
        case .soft: "\(name) updated"
        case .control: "\(name.uppercased()) UPDATED"
        case .ink: "\(name) is written anew"
        }
    }

    func toastLookFailed(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Saved on this phone only"
        case .control: "LOCAL ONLY"
        case .ink: "Kept here alone"
        }
    }

    func toastLookFailedBody(_ t: ThemeID) -> String {
        switch t {
        case .soft: "The gateway rejected the write, so your laptop won’t see this look."
        case .control: "GATEWAY REJECTED UI_META · OTHER CLIENTS UNCHANGED"
        case .ink: "The gateway refused the entry; other hands will not see it."
        }
    }

    // Deletes — plugin.js:7974 for the shape of the closing line.
    func toastDeleting(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Deleting…"
        case .control: "DELETING…"
        case .ink: "Striking it out…"
        }
    }

    func toastSessionDeleted(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Session deleted"
        case .control: "SESSION DELETED"
        case .ink: "The record is struck"
        }
    }

    func toastRoutineDeleted(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Routine deleted"
        case .control: "ROUTINE REMOVED"
        case .ink: "The rite is undone"
        }
    }

    func toastDeleteFailed(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Couldn’t delete that"
        case .control: "DELETE REFUSED"
        case .ink: "It would not be struck out"
        }
    }

    // Model switch.
    func toastSwitchingModel(_ model: String, _ t: ThemeID) -> String {
        switch t {
        case .soft: model.isEmpty ? "Switching model…" : "Switching to \(model)…"
        case .control: model.isEmpty ? "SWITCHING MODEL…" : "SWITCHING → \(model.uppercased())…"
        case .ink: model.isEmpty ? "Changing its mind…" : "Calling upon \(model)…"
        }
    }

    func toastModelSwitched(_ model: String, _ t: ThemeID) -> String {
        switch t {
        case .soft: model.isEmpty ? "Model switched" : "Now running \(model)"
        case .control: model.isEmpty ? "MODEL SET" : "RUNNING \(model.uppercased())"
        case .ink: model.isEmpty ? "Its mind is changed" : "It thinks now as \(model)"
        }
    }

    func toastModelDeferred(_ model: String, _ t: ThemeID) -> String {
        switch t {
        case .soft: model.isEmpty ? "Switching after this turn" : "\(model) takes over next turn"
        case .control: model.isEmpty ? "QUEUED FOR NEXT TURN" : "\(model.uppercased()) — NEXT TURN"
        case .ink: model.isEmpty ? "It shall change when this turn is done"
                                 : "\(model) shall take up the next turn"
        }
    }

    func toastModelDeferredBody(_ t: ThemeID) -> String {
        switch t {
        case .soft: "A turn is running — the gateway applies it when that settles."
        case .control: "TURN IN FLIGHT · APPLIED AT NEXT TURN START"
        case .ink: "A turn is in flight; the change waits upon its end."
        }
    }

    func toastModelFailed(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Model switch failed"
        case .control: "SWITCH REJECTED"
        case .ink: "It would not change its mind"
        }
    }

    /// Activity's footnote: what this ledger is and where it lives. The count
    /// is the honest one — rows held, not rows ever seen — and the cap is only
    /// mentioned once it is actually being enforced.
    func ledgerScopeNote(_ t: ThemeID, count: Int, cap: Int) -> String {
        let full = count >= cap
        switch t {
        case .soft:
            return full ? "\(count) entries · kept on this phone; the oldest roll off"
                        : "\(count) \(count == 1 ? "entry" : "entries") · kept on this phone"
        case .control:
            return full ? "\(count)/\(cap) ROWS · LOCAL JOURNAL · OLDEST DISCARDED"
                        : "\(count) ROWS · LOCAL JOURNAL"
        case .ink:
            if full { return "\(count) entries — the earliest have left the page" }
            return count == 1 ? "One entry, kept in this hand"
                              : "\(count) entries, kept in this hand"
        }
    }

    // ── notifyError contexts (plugin.js:2659 / 2878 / 6782) ─────────────────
    //
    // Upstream's `host.notifyError(err, context)` puts the CONTEXT in the title
    // and the error's own words underneath. That order is the point: "Could not
    // open inbox's chat" is what the user needs, and the transport's sentence is
    // detail. Every one of these carries the gateway's message as the body.

    /// plugin.js:2878. "try again" is the instruction, not politeness — the pin
    /// was just verified, so a failed open is transient and nothing is
    /// re-anchored on it.
    func toastOpenChatFailed(_ name: String, _ t: ThemeID) -> String {
        switch t {
        case .soft: BotModeStrings.couldNotOpenChat(name)
        case .control: "OPEN FAILED — \(name.uppercased()) · RETRY"
        case .ink: "\(name)’s chat would not open — try once more"
        }
    }

    /// plugin.js:6782.
    func toastOpenSessionFailed(_ t: ThemeID) -> String {
        switch t {
        case .soft: BotModeStrings.couldNotOpenSession
        case .control: "SESSION OPEN FAILED"
        case .ink: "That record would not open"
        }
    }

    /// plugin.js:2659, 3926, 7808.
    func toastCouldNotReach(_ label: String, _ t: ThemeID) -> String {
        switch t {
        case .soft: BotModeStrings.couldNotReach(label)
        case .control: "UNREACHABLE — \(label.uppercased())"
        case .ink: "\(label) could not be reached"
        }
    }

    // ── The remote-delivery trilogy (plugin.js:2637-2658) ───────────────────

    /// Sent. The promise being made is "will relay the reply here", which is the
    /// part a user cannot infer from a composer that just closed.
    func toastHandoffSent(_ handle: String, on label: String?, _ t: ThemeID) -> String {
        switch t {
        case .soft: BotModeStrings.messaged(handle, on: label)
        case .control: "SENT → @\(handle.uppercased()) · AWAITING REPLY"
        case .ink: "Word sent to @\(handle); the answer will be brought here"
        }
    }

    /// The answer came back.
    func toastHandoffReply(_ name: String, on label: String?, _ t: ThemeID) -> String {
        switch t {
        case .soft: BotModeStrings.replyFrom(name, on: label)
        case .control: label.map { "\(name.uppercased()) · \($0.uppercased())" }
                            ?? "\(name.uppercased()) REPLIED"
        case .ink: "\(name) has answered"
        }
    }

    /// The watch ran out. Deliberately not failure-shaped: the message is in
    /// their chat and the sweep will find the reply whenever it lands.
    func toastNoReplyYet(_ handle: String, on label: String?, _ t: ThemeID) -> String {
        switch t {
        case .soft: BotModeStrings.noReplyYet(handle, on: label)
        case .control: "NO REPLY YET — @\(handle.uppercased()) · CHECK ITS BOT CHAT"
        case .ink: "No word from @\(handle) yet — look in its own chat"
        }
    }

    // ── Routines (plugin.js:6177 / 6500) ────────────────────────────────────

    func toastSchedulingRoutine(_ title: String, _ t: ThemeID) -> String {
        switch t {
        case .soft: "Scheduling “\(title)”…"
        case .control: "SCHEDULING \(title.uppercased())…"
        case .ink: "Entering “\(title)” in the calendar…"
        }
    }

    /// plugin.js:6500.
    func toastRoutineScheduled(_ title: String, _ t: ThemeID) -> String {
        switch t {
        case .soft: BotModeStrings.cronjobScheduled(title)
        case .control: "SCHEDULED — \(title.uppercased())"
        case .ink: "“\(title)” is set down in the calendar"
        }
    }

    func toastRoutineScheduleFailed(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Couldn’t schedule that"
        case .control: "SCHEDULE REJECTED"
        case .ink: "It would not be entered"
        }
    }

    func toastSavingRoutine(_ title: String, _ t: ThemeID) -> String {
        switch t {
        case .soft: "Saving “\(title)”…"
        case .control: "SAVING \(title.uppercased())…"
        case .ink: "Rewriting “\(title)”…"
        }
    }

    /// plugin.js:6177 — the update path, which covers save, pause and resume.
    func toastRoutineUpdateFailed(_ t: ThemeID) -> String {
        switch t {
        case .soft: BotModeStrings.cronjobUpdateFailed
        case .control: "CRONJOB UPDATE FAILED"
        case .ink: "The rite would not be altered"
        }
    }

    func toastRoutineSaved(_ title: String, _ t: ThemeID) -> String {
        switch t {
        case .soft: "“\(title)” updated"
        case .control: "\(title.uppercased()) UPDATED"
        case .ink: "“\(title)” is rewritten"
        }
    }

    func toastRoutinePaused(_ title: String, on: Bool, _ t: ThemeID) -> String {
        switch t {
        case .soft: on ? "“\(title)” resumed" : "“\(title)” paused"
        case .control: on ? "\(title.uppercased()) ARMED" : "\(title.uppercased()) PAUSED"
        case .ink: on ? "“\(title)” shall keep its hours again" : "“\(title)” is stayed"
        }
    }

    // ── Profiles (plugin.js:5426 / 5651) ────────────────────────────────────

    func toastCreatingBot(_ name: String, _ t: ThemeID) -> String {
        switch t {
        case .soft: "Creating \(name)…"
        case .control: "CREATING \(name.uppercased())…"
        case .ink: "Writing \(name) into being…"
        }
    }

    /// plugin.js:5426.
    func toastBotCreated(_ name: String, _ t: ThemeID) -> String {
        switch t {
        case .soft: BotModeStrings.agentCreated(name)
        case .control: "AGENT \(name.uppercased()) CREATED"
        case .ink: "\(name) has been written into the roll"
        }
    }

    func toastBotCreatedPartial(_ name: String, _ t: ThemeID) -> String {
        switch t {
        case .soft: "Created (name), but some setup did not land — open the profile to review it"
        case .control: "(name.uppercased()) CREATED — SETUP PARTIAL; REVIEW PROFILE"
        case .ink: "(name) exists, though part of its inscription must be reviewed"
        }
    }

    /// plugin.js:5651.
    func toastBotCreateFailed(_ t: ThemeID) -> String {
        switch t {
        case .soft: BotModeStrings.couldNotCreateProfile
        case .control: "PROFILE CREATE REJECTED"
        case .ink: "The profile would not take"
        }
    }

    func toastSavingProfile(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Saving profile…"
        case .control: "SAVING PROFILE…"
        case .ink: "Amending the profile…"
        }
    }

    func toastProfileSaveFailed(_ name: String, _ t: ThemeID) -> String {
        switch t {
        case .soft: "Couldn’t save \(name)"
        case .control: "SAVE REJECTED — \(name.uppercased())"
        case .ink: "\(name)’s entry would not be altered"
        }
    }

    // ── Sessions ────────────────────────────────────────────────────────────

    func toastRenaming(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Renaming session…"
        case .control: "RENAMING SESSION…"
        case .ink: "Giving the record a new name…"
        }
    }

    func toastSessionRenamed(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Session renamed"
        case .control: "SESSION RENAMED"
        case .ink: "The record bears a new name"
        }
    }

    func toastRenameFailed(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Couldn’t rename that"
        case .control: "RENAME REFUSED"
        case .ink: "The name would not hold"
        }
    }

    // ── Reasoning effort ────────────────────────────────────────────────────

    func toastEffortSet(_ label: String, _ t: ThemeID) -> String {
        switch t {
        case .soft: "Thinking set to \(label)"
        case .control: "EFFORT → \(label.uppercased())"
        case .ink: "It will think \(label)"
        }
    }

    func toastEffortFailed(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Couldn’t change how hard it thinks"
        case .control: "EFFORT REJECTED"
        case .ink: "Its manner of thought would not change"
        }
    }

    // ── The forever chat (plugin.js:8232-8237) ──────────────────────────────
    //
    // The only entry in this file that is not narration: `/new` and `/reset` are
    // REWRITTEN before they run, and this says so.

    func toastNeverResetsTitle(_ t: ThemeID) -> String {
        switch t {
        case .soft: BotModeStrings.neverResetsTitle
        case .control: "THIS CHAT NEVER RESETS"
        case .ink: "This chat is never begun anew"
        }
    }

    func toastNeverResetsBody(_ t: ThemeID) -> String {
        switch t {
        case .soft: BotModeStrings.neverResetsBody
        case .control: "BOT CHATS ARE ONE CONTINUOUS SESSION · COMPACTING INSTEAD · "
                     + "USE SESSIONS MODE FOR A THROWAWAY"
        case .ink: "A bot’s chat is one long conversation — it will be compacted instead. "
                 + "For a passing session with this agent, use Sessions."
        }
    }

    func toastBackgroundComplete(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Background task finished"
        case .control: "BACKGROUND TASK COMPLETE"
        case .ink: "The distant work is done"
        }
    }

    // The toast card's own accessibility strings.
    func toastDismiss(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Dismiss"
        case .control: "DISMISS"
        case .ink: "Set aside"
        }
    }

    func toastDismissHint(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Tap or swipe up to dismiss"
        case .control: "TAP OR SWIPE UP TO CLEAR"
        case .ink: "Tap, or brush it upward, to set it aside"
        }
    }
}
