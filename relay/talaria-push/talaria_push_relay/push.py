"""Fan-out dispatcher — turns relay events into APNs sends.

One process-wide :class:`PushDispatcher` owns:

- the :class:`~.apns.APNsClient` (HTTP/2 + cached provider JWT),
- the :class:`~.devices.DeviceStore` (``~/.hermes/talaria-push/devices.json``),
- a daemon worker thread draining a bounded queue, so hook callbacks on
  agent threads never block on network I/O,
- an in-memory dedupe window so the same logical event (e.g. one approval
  observed twice) never double-buzzes a phone.

Payload contract (shared with the Talaria iOS client — see HANDOFF spec):

.. code-block:: json

    {
      "aps": {
        "alert": {"title": "...", "body": "..."},
        "sound": "default",
        "thread-id": "<bot>",
        "category": "TALARIA_APPROVAL",
        "interruption-level": "time-sensitive"
      },
      "kind": "approval",
      "bot": "<profile name>",
      "session_id": "<hermes session id>",
      "approval_request_id": "<uuid hex or empty>",
      "title": "...",
      "body": "...",
      "deeplink": "talaria://approvals"
    }

``kind`` is one of ``approval | long_task | mention | routine | gateway``.
Deep-link routing follows the HANDOFF spec: approval -> Approvals screen,
gateway -> Connections screen, everything else -> that bot's chat.
"""

from __future__ import annotations

import hashlib
import logging
import queue
import threading
import time
import urllib.parse
from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional

from .apns import APNsClient
from .config import apns_settings, relay_settings
from .devices import get_store

logger = logging.getLogger("talaria_push")

_QUEUE_MAX = 256
_TITLE_MAX = 120
_BODY_MAX = 900  # APNs payload cap is 4 KB; keep well under it.

# APNs category per event kind (the iOS client registers matching
# UNNotificationCategory actions — TALARIA_APPROVAL carries the
# actionable Approve / Later buttons).
CATEGORIES = {
    "approval": "TALARIA_APPROVAL",
    "long_task": "TALARIA_TASK",
    "mention": "TALARIA_MENTION",
    "routine": "TALARIA_ROUTINE",
    "gateway": "TALARIA_GATEWAY",
}

# interruption-level per kind. "time-sensitive" needs the Time Sensitive
# Notifications capability on the app id ("critical" would need a special
# Apple entitlement, so the relay deliberately stops at time-sensitive).
INTERRUPTION_LEVELS = {
    "approval": "time-sensitive",
    "gateway": "time-sensitive",
    "mention": "active",
    "long_task": "active",
    "routine": "active",
}

_DEFAULT_DEDUPE_S = 20.0
DEFAULT_TEST_KIND = "mention"

# Never leave an actionable approval in APNs after Hermes' normal blocking
# timeout. Other notifications also receive finite relevance windows so a
# phone coming online days later does not present stale operational state.
_EXPIRATION_TTL_S = {
    "approval": 5 * 60,
    "gateway": 10 * 60,
    "mention": 60 * 60,
    "long_task": 24 * 60 * 60,
    "routine": 24 * 60 * 60,
}


def _truncate(text: str, limit: int) -> str:
    text = (text or "").strip()
    if len(text) <= limit:
        return text
    return text[: limit - 1].rstrip() + "…"


def build_deeplink(kind: str, bot: str, session_id: str = "") -> str:
    """Deep-link routing data per the HANDOFF spec.

    Route space matches the iOS client's DeepLink parser exactly:
    talaria://approvals, talaria://connections, talaria://bot/<id>.
    """
    if kind == "approval":
        return "talaria://approvals"
    if kind == "gateway":
        return "talaria://connections"
    base = f"talaria://bot/{urllib.parse.quote(bot or 'default', safe='')}"
    if session_id:
        return f"{base}?session_id={urllib.parse.quote(session_id, safe='')}"
    return base


@dataclass
class PushEvent:
    """One logical notification, before device fan-out."""

    kind: str                       # approval | long_task | mention | routine | gateway
    bot: str                        # hermes profile ("default" for the root profile)
    title: str
    body: str
    session_id: str = ""
    approval_request_id: str = ""
    collapse_id: Optional[str] = None
    dedupe_key: Optional[str] = None
    dedupe_window_s: float = _DEFAULT_DEDUPE_S
    extra: Dict[str, Any] = field(default_factory=dict)
    expiration: Optional[int] = None

    def __post_init__(self) -> None:
        if self.expiration is None:
            ttl = _EXPIRATION_TTL_S.get(self.kind, 60 * 60)
            self.expiration = int(time.time()) + ttl

    def apns_payload(self) -> Dict[str, Any]:
        aps: Dict[str, Any] = {
            "alert": {
                "title": _truncate(self.title, _TITLE_MAX),
                "body": _truncate(self.body, _BODY_MAX),
            },
            "sound": "default",
            "thread-id": self.bot or "hermes",
            "category": CATEGORIES.get(self.kind, "TALARIA_EVENT"),
            "interruption-level": INTERRUPTION_LEVELS.get(self.kind, "active"),
            "mutable-content": 1,
        }
        payload: Dict[str, Any] = {
            "aps": aps,
            "kind": self.kind,
            "bot": self.bot,
            "session_id": self.session_id,
            "approval_request_id": self.approval_request_id,
            "title": _truncate(self.title, _TITLE_MAX),
            "body": _truncate(self.body, _BODY_MAX),
            "deeplink": build_deeplink(self.kind, self.bot, self.session_id),
        }
        for key, value in self.extra.items():
            # Custom keys must not collide with the reserved contract keys.
            if key not in payload:
                payload[key] = value
        return payload


def payload_for_device(event: PushEvent, device: Dict[str, Any]) -> Dict[str, Any]:
    """Bind one logical event to one app registration's source identity."""
    payload = event.apns_payload()
    gateway_id = str(device.get("gateway_id") or "").strip()
    if gateway_id:
        payload["gateway_id"] = gateway_id
    return payload


def synthetic_test_event(kind: str) -> PushEvent:
    """Build a display-only test that can never authorize a live action."""
    return PushEvent(
        kind=kind,
        bot="talaria-test",
        title="Talaria test push",
        body=f"Relay is working — this is a {kind!r}-shaped test notification.",
        session_id="",
        approval_request_id="",
        collapse_id="talaria-test",
        dedupe_key=None,
    )


class PushDispatcher:
    """Queue + worker thread + dedupe around the APNs client."""

    def __init__(self) -> None:
        self._queue: "queue.Queue[PushEvent]" = queue.Queue(maxsize=_QUEUE_MAX)
        self._worker: Optional[threading.Thread] = None
        self._worker_lock = threading.Lock()
        self._client: Optional[APNsClient] = None
        self._dedupe: Dict[str, float] = {}
        self._dedupe_lock = threading.Lock()
        self._warned_unconfigured = False

    # -- public API ---------------------------------------------------------

    def notify(self, event: PushEvent) -> bool:
        """Enqueue one event for fan-out. Returns False when suppressed.

        Never raises and never blocks on network — safe to call from
        agent/gateway hook callbacks.
        """
        settings = relay_settings()
        if not settings.event_enabled(event.kind):
            logger.debug("talaria-push: kind %r disabled; dropping", event.kind)
            return False
        if not self._apns_ready():
            return False
        if self._is_duplicate(event):
            logger.debug(
                "talaria-push: dedupe suppressed %s (%s)",
                event.kind, event.dedupe_key,
            )
            return False
        try:
            self._queue.put_nowait(event)
        except queue.Full:
            # Shed oldest first: a stale push is worth less than a fresh one.
            try:
                self._queue.get_nowait()
                self._queue.put_nowait(event)
            except Exception:
                logger.warning("talaria-push: queue full; dropped %s", event.kind)
                return False
        self._ensure_worker()
        return True

    def clear_dedupe(self, dedupe_key: str) -> None:
        """Forget a dedupe entry (e.g. once an approval was answered)."""
        with self._dedupe_lock:
            self._dedupe.pop(dedupe_key, None)

    def flush_for_test(self, timeout: float = 15.0) -> None:
        """Block until the queue drains (used by /test endpoint + tests)."""
        deadline = time.time() + timeout
        while not self._queue.empty() and time.time() < deadline:
            time.sleep(0.05)

    # -- internals ----------------------------------------------------------

    def _apns_ready(self) -> bool:
        settings = apns_settings()
        if settings.configured:
            self._warned_unconfigured = False
            return True
        if not self._warned_unconfigured:
            logger.warning(
                "talaria-push: APNs not configured; missing %s — pushes disabled",
                ", ".join(settings.missing()),
            )
            self._warned_unconfigured = True
        return False

    def _is_duplicate(self, event: PushEvent) -> bool:
        key = event.dedupe_key
        if not key:
            return False
        now = time.time()
        with self._dedupe_lock:
            # opportunistic GC so the map can't grow unbounded
            if len(self._dedupe) > 512:
                self._dedupe = {
                    k: t for k, t in self._dedupe.items() if now - t < 3600
                }
            last = self._dedupe.get(key)
            if last is not None and now - last < event.dedupe_window_s:
                return True
            self._dedupe[key] = now
            return False

    def _ensure_worker(self) -> None:
        with self._worker_lock:
            if self._worker is not None and self._worker.is_alive():
                return
            self._worker = threading.Thread(
                target=self._run, name="talaria-push-worker", daemon=True
            )
            self._worker.start()

    def _get_client(self) -> APNsClient:
        if self._client is None:
            self._client = APNsClient(apns_settings())
        return self._client

    def _run(self) -> None:
        while True:
            event = self._queue.get()
            try:
                self._fan_out(event)
            except Exception as exc:  # never kill the worker
                logger.warning("talaria-push: fan-out failed: %s", exc)

    def _fan_out(self, event: PushEvent) -> None:
        store = get_store()
        devices = store.for_bot(event.bot)
        if not devices:
            logger.debug(
                "talaria-push: no registered device matches bot %r; dropping %s",
                event.bot, event.kind,
            )
            return
        client = self._get_client()
        for dev in devices:
            token = dev["device_token"]
            # Stamp the registration's source per device. Without it two
            # gateways that both expose `default` are indistinguishable on the
            # phone, and an actionable approval can reach the wrong machine.
            payload = payload_for_device(event, dev)
            result = client.send(
                token,
                payload,
                environment=dev.get("environment"),
                push_type="alert",
                priority=10,
                collapse_id=event.collapse_id,
                expiration=event.expiration,
            )
            if result.should_unregister:
                # 410 Unregistered / 400 BadDeviceToken — token is dead.
                logger.info(
                    "talaria-push: pruning dead device …%s (%s %s)",
                    token[-8:], result.status, result.reason,
                )
                store.remove(token)
                continue
            store.mark_result(token, result.ok)
            if result.ok:
                logger.info(
                    "talaria-push: sent %s to …%s (apns-id %s)",
                    event.kind, token[-8:], result.apns_id or "?",
                )
            elif result.retryable:
                # One bounded retry after a short pause; APNs hiccups are
                # usually transient, and approvals are time-boxed upstream.
                # ExpiredProviderToken cleared the JWT cache in APNsClient;
                # remint and retry immediately. Back-pressure/server failures
                # retain the one-second bound.
                if not (result.status == 403 and result.reason == "ExpiredProviderToken"):
                    time.sleep(1.0)
                retry = client.send(
                    token, payload,
                    environment=dev.get("environment"),
                    collapse_id=event.collapse_id,
                    expiration=event.expiration,
                )
                if retry.should_unregister:
                    store.remove(token)
                    continue
                store.mark_result(token, retry.ok)
                if not retry.ok:
                    logger.warning(
                        "talaria-push: retry failed for …%s (%s %s)",
                        token[-8:], retry.status, retry.reason,
                    )


_dispatcher: Optional[PushDispatcher] = None
_dispatcher_lock = threading.Lock()


def get_dispatcher() -> PushDispatcher:
    global _dispatcher
    if _dispatcher is None:
        with _dispatcher_lock:
            if _dispatcher is None:
                _dispatcher = PushDispatcher()
    return _dispatcher


def stable_hash(*parts: str) -> str:
    """Short stable hash for dedupe/collapse keys."""
    joined = "\x1f".join(p or "" for p in parts)
    return hashlib.sha256(joined.encode("utf-8", "replace")).hexdigest()[:16]


# -- payload/event builders (shared by hook mode and sidecar mode) ----------


def approval_event(
    *,
    bot: str,
    session_id: str,
    description: str = "",
    command: str = "",
    approval_request_id: str = "",
    pattern_key: str = "",
) -> PushEvent:
    body = description or command or "A command is waiting for your approval."
    if description and command and command not in description:
        body = f"{description}\n{command}"
    return PushEvent(
        kind="approval",
        bot=bot,
        title=f"{bot} needs approval",
        body=body,
        session_id=session_id,
        approval_request_id=approval_request_id,
        collapse_id=f"approval-{stable_hash(bot, session_id)}",
        dedupe_key=(
            f"approval:{approval_request_id}"
            if approval_request_id
            else f"approval:{stable_hash(bot, session_id, pattern_key, command)}"
        ),
        dedupe_window_s=relay_settings().approval_dedupe_window_s,
    )


def long_task_event(
    *, bot: str, session_id: str, duration_s: float,
    ok: bool = True, summary: str = "",
) -> PushEvent:
    minutes = max(1, int(duration_s // 60))
    verdict = "finished" if ok else "stopped"
    body = summary or f"A {minutes}-minute task just {verdict}."
    return PushEvent(
        kind="long_task",
        bot=bot,
        title=f"{bot}: long task {verdict}",
        body=body,
        session_id=session_id,
        collapse_id=f"task-{stable_hash(bot, session_id)}",
        dedupe_key=f"long_task:{stable_hash(bot, session_id, str(int(duration_s)))}",
    )


def mention_event(
    *, bot: str, platform: str, sender: str, text: str, session_id: str = "",
) -> PushEvent:
    who = sender or "someone"
    where = f" on {platform}" if platform else ""
    return PushEvent(
        kind="mention",
        bot=bot,
        title=f"{who} mentioned @{bot}{where}",
        body=text or "(no message text)",
        session_id=session_id,
        collapse_id=f"mention-{stable_hash(bot, platform, sender)}",
        dedupe_key=f"mention:{stable_hash(bot, platform, sender, text)}",
        extra={"platform": platform, "sender": who},
    )


def routine_event(
    *, bot: str, routine: str = "", session_id: str = "",
    ok: bool = True, detail: str = "",
) -> PushEvent:
    name = routine or "routine"
    verdict = "finished" if ok else "failed"
    return PushEvent(
        kind="routine",
        bot=bot,
        title=f"{bot}: {name} {verdict}",
        body=detail or f"The scheduled routine {verdict}.",
        session_id=session_id,
        collapse_id=f"routine-{stable_hash(bot, name)}",
        dedupe_key=f"routine:{stable_hash(bot, name, session_id, verdict)}",
        extra={"routine": name},
    )


def gateway_event(*, online: bool, base_url: str = "", detail: str = "") -> PushEvent:
    state = "recovered" if online else "offline"
    return PushEvent(
        kind="gateway",
        bot="hermes",
        title=f"Gateway {state}",
        body=detail or (
            "The Hermes gateway is reachable again."
            if online
            else "The Hermes gateway stopped responding."
        ),
        collapse_id="gateway-state",
        dedupe_key=f"gateway:{state}:{stable_hash(base_url)}",
        dedupe_window_s=120.0,
        extra={"gateway_url": base_url} if base_url else {},
    )
