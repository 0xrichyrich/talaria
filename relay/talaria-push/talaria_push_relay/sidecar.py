"""Standalone sidecar mode — watch a running ``hermes serve`` and push.

Why this exists
---------------
The in-process hook mode (``events.py``) covers everything the plugin hook
surface can see, but two things it structurally cannot:

* **gateway offline/recovered** — a dead process cannot self-report; and
* **approval request ids** — ``pre_approval_request`` does not carry the
  ``request_id`` the iOS client needs for targeted ``approval.respond``.

The sidecar is a separate long-running process (run it under systemd /
launchd, ideally on a *different* host over Tailscale for real offline
detection) that connects to the gateway the same way the served SPA does
(``ws://127.0.0.1:9119/api/ws?token=<session token>``, auth-flows.md §2)
and complements hook mode.

What it watches — and how (honest notes)
----------------------------------------
The WS server only delivers per-session events (``approval.request``,
``message.complete``, ...) to the transport *bound* to that session; a
fresh sidecar connection is only registered for **global broadcasts**
(``sessions.changed``, ``cron.changed``, ...). Rather than hijacking
session bindings away from real clients with ``session.resume``, the
sidecar POLLS read-only RPCs — coarser, but safe and side-effect free:

* ``approval`` — polls ``session.active_list`` then ``approval.pending``
  per active session (~2 s). Full fidelity: entry data carries the real
  ``request_id``, command, description.
* ``long_task`` — tracks idle→streaming→idle transitions per session_key
  in ``session.active_list``; pushes when a streaming stretch exceeded
  the threshold. (Resolution = poll interval; good enough for >10 min.)
* ``routine`` — on ``cron.changed`` broadcast (plus a slow backstop
  poll), diffs ``GET /api/cron/jobs?profile=all`` and pushes when a
  job's last-run fingerprint changes to a terminal state. Carries the
  job/routine *name*, which hook mode cannot see.
* ``gateway`` — ``GET /api/health`` heartbeat; N consecutive failures ⇒
  "gateway offline", first success afterwards ⇒ "gateway recovered".
* ``mention`` — NOT available here: messaging-gateway inbound traffic
  never crosses the WS surface. Hook mode covers it.

Deployment note: run hook mode and the sidecar together, split by
``TALARIA_PUSH_EVENTS`` so no kind is enabled in both (see .env.example)
— otherwise approvals and long tasks double-push.

Auth: loopback/static-token gateways only (``?token=``). For a gated
(non-loopback, OAuth) gateway the browser ticket flow needs an
interactive login, so run the sidecar on the gateway host against
``http://127.0.0.1:9119``. If ``TALARIA_GATEWAY_TOKEN`` is unset the
sidecar scrapes ``window.__HERMES_SESSION_TOKEN__`` from ``GET /`` —
the same token the served SPA embeds (auth-flows.md §2). That token
rotates on every server restart; the scrape re-runs on reconnect.
"""

from __future__ import annotations

import argparse
import asyncio
import itertools
import json
import logging
import os
import re
import signal
import sys
import time
from typing import Any, Dict, List, Optional

from . import push as push_mod
from .config import SidecarSettings, relay_settings

logger = logging.getLogger("talaria_push.sidecar")

_TOKEN_RE = re.compile(r"__HERMES_SESSION_TOKEN__\s*=\s*[\"']([^\"']+)[\"']")

POLL_INTERVAL_S = 2.0
ACTIVE_LIST_TIMEOUT_S = 20.0
CRON_BACKSTOP_S = 300.0


class GatewayWS:
    """Tiny JSON-RPC-over-WebSocket client for /api/ws.

    Responses may arrive out of order relative to requests (pooled
    handlers, ws-protocol.md §4) — correlate strictly by id.
    """

    def __init__(self, url: str):
        self._url = url
        self._ws: Any = None
        self._ids = itertools.count(1)
        self._pending: Dict[str, asyncio.Future] = {}
        self._events: "asyncio.Queue[dict]" = asyncio.Queue(maxsize=1024)
        self._reader: Optional[asyncio.Task] = None

    async def connect(self) -> None:
        import websockets

        self._ws = await websockets.connect(
            self._url, max_size=32 * 1024 * 1024, ping_interval=20
        )
        self._reader = asyncio.create_task(self._read_loop())

    async def close(self) -> None:
        if self._reader:
            self._reader.cancel()
        if self._ws is not None:
            try:
                await self._ws.close()
            except Exception:
                pass
        for fut in self._pending.values():
            if not fut.done():
                fut.set_exception(ConnectionError("websocket closed"))
        self._pending.clear()

    async def _read_loop(self) -> None:
        try:
            async for raw in self._ws:
                try:
                    frame = json.loads(raw)
                except Exception:
                    continue
                if not isinstance(frame, dict):
                    continue
                if frame.get("method") == "event":
                    try:
                        self._events.put_nowait(frame.get("params") or {})
                    except asyncio.QueueFull:
                        _ = self._events.get_nowait()  # shed oldest
                        self._events.put_nowait(frame.get("params") or {})
                    continue
                fid = frame.get("id")
                fut = self._pending.pop(str(fid), None)
                if fut is not None and not fut.done():
                    if "error" in frame:
                        fut.set_exception(
                            RuntimeError(str(frame["error"].get("message")))
                        )
                    else:
                        fut.set_result(frame.get("result"))
        except asyncio.CancelledError:
            raise
        except Exception as exc:
            logger.debug("ws read loop ended: %s", exc)
            for fut in self._pending.values():
                if not fut.done():
                    fut.set_exception(ConnectionError(str(exc)))
            self._pending.clear()

    async def rpc(
        self, method: str, params: Optional[dict] = None, timeout: float = 20.0
    ) -> Any:
        rid = str(next(self._ids))
        fut: asyncio.Future = asyncio.get_running_loop().create_future()
        self._pending[rid] = fut
        await self._ws.send(json.dumps({
            "jsonrpc": "2.0", "id": rid, "method": method,
            "params": params or {},
        }))
        return await asyncio.wait_for(fut, timeout)

    async def next_event(self, timeout: float) -> Optional[dict]:
        try:
            return await asyncio.wait_for(self._events.get(), timeout)
        except asyncio.TimeoutError:
            return None


class Sidecar:
    def __init__(self, settings: SidecarSettings):
        self.settings = settings
        self.token: str = settings.token
        self.dispatcher = push_mod.get_dispatcher()
        # long-task stopwatch: session_key -> wall-clock streaming start
        self._streaming_since: Dict[str, float] = {}
        self._session_titles: Dict[str, str] = {}
        # approvals already pushed, by request_id
        self._seen_approvals: Dict[str, float] = {}
        # cron job fingerprints: job key -> fingerprint
        self._cron_fp: Dict[str, str] = {}
        self._cron_baselined = False
        self._offline = False
        self._health_failures = 0
        self._stop = asyncio.Event()

    # -- auth ---------------------------------------------------------------

    def _http(self):
        import httpx

        headers = {}
        if self.token:
            headers["X-Hermes-Session-Token"] = self.token
        return httpx.AsyncClient(
            base_url=self.settings.base_url, headers=headers,
            timeout=httpx.Timeout(10.0, connect=5.0),
        )

    async def resolve_token(self) -> bool:
        """Env token, else scrape the served SPA for the session token."""
        if self.settings.token:
            self.token = self.settings.token
            return True
        import httpx

        try:
            async with httpx.AsyncClient(
                base_url=self.settings.base_url, timeout=10.0
            ) as client:
                resp = await client.get("/")
                match = _TOKEN_RE.search(resp.text or "")
                if match:
                    self.token = match.group(1)
                    logger.info("resolved session token from served SPA HTML")
                    return True
        except Exception as exc:
            logger.debug("token scrape failed: %s", exc)
        logger.warning(
            "no TALARIA_GATEWAY_TOKEN and could not scrape the SPA token; "
            "WS features disabled until the gateway is reachable"
        )
        return False

    # -- health / offline ---------------------------------------------------

    async def health_loop(self) -> None:
        interval = max(self.settings.health_interval_s, 3.0)
        while not self._stop.is_set():
            ok = False
            try:
                import httpx

                async with httpx.AsyncClient(
                    base_url=self.settings.base_url, timeout=5.0
                ) as client:
                    resp = await client.get("/api/health")
                    ok = resp.status_code == 200
            except Exception:
                ok = False

            if ok:
                self._health_failures = 0
                if self._offline:
                    self._offline = False
                    self.dispatcher.notify(push_mod.gateway_event(
                        online=True, base_url=self.settings.base_url,
                    ))
            else:
                self._health_failures += 1
                if (
                    not self._offline
                    and self._health_failures
                    >= self.settings.health_failures_for_offline
                ):
                    self._offline = True
                    self.dispatcher.notify(push_mod.gateway_event(
                        online=False, base_url=self.settings.base_url,
                        detail=(
                            f"{self._health_failures} health checks failed "
                            f"({self.settings.base_url})."
                        ),
                    ))
            try:
                await asyncio.wait_for(self._stop.wait(), interval)
            except asyncio.TimeoutError:
                pass

    # -- session / approval polling ----------------------------------------

    async def poll_sessions(self, ws: GatewayWS) -> None:
        try:
            result = await ws.rpc(
                "session.active_list", {}, timeout=ACTIVE_LIST_TIMEOUT_S
            )
        except Exception as exc:
            logger.debug("session.active_list failed: %s", exc)
            return
        sessions = (result or {}).get("sessions") or []
        now = time.time()
        seen_keys = set()
        settings = relay_settings()

        for row in sessions:
            if not isinstance(row, dict):
                continue
            sid = str(row.get("id") or "")
            key = str(row.get("session_key") or sid)
            status = str(row.get("status") or "")
            title = str(row.get("title") or row.get("preview") or "")
            seen_keys.add(key)
            if title:
                self._session_titles[key] = title

            # long-task stopwatch on idle<->streaming transitions
            if status == "streaming":
                self._streaming_since.setdefault(key, now)
            else:
                started = self._streaming_since.pop(key, None)
                if started is not None:
                    duration = now - started
                    if duration >= settings.long_task_min_s > 0:
                        self.dispatcher.notify(push_mod.long_task_event(
                            bot=self._bot_name(),
                            session_id=key,
                            duration_s=duration,
                            ok=True,
                            summary=(
                                f"“{self._session_titles.get(key, 'task')}” "
                                f"finished after {int(duration // 60)} min."
                            ),
                        ))

            # pending approvals (full request_id fidelity)
            if sid:
                await self._poll_approvals(ws, sid, key)

        # sessions that vanished while streaming: closed/errored — treat the
        # stopwatch as ended without a push (we can't tell success apart).
        for key in [k for k in self._streaming_since if k not in seen_keys]:
            self._streaming_since.pop(key, None)

    async def _poll_approvals(self, ws: GatewayWS, sid: str, key: str) -> None:
        try:
            result = await ws.rpc("approval.pending", {"session_id": sid}, timeout=10.0)
        except Exception as exc:
            logger.debug("approval.pending(%s) failed: %s", sid, exc)
            return
        approvals = (result or {}).get("approvals") or []
        now = time.time()
        # GC old seen entries (approval timeout upstream is 300 s)
        for rid, ts in list(self._seen_approvals.items()):
            if now - ts > 900:
                self._seen_approvals.pop(rid, None)
        for entry in approvals:
            if not isinstance(entry, dict):
                continue
            request_id = str(entry.get("request_id") or "")
            if request_id and request_id in self._seen_approvals:
                continue
            if request_id:
                self._seen_approvals[request_id] = now
            self.dispatcher.notify(push_mod.approval_event(
                bot=self._bot_name(),
                session_id=key,
                description=str(entry.get("description") or ""),
                command=str(entry.get("command") or ""),
                approval_request_id=request_id,
                pattern_key=str(entry.get("pattern_key") or ""),
            ))

    # -- cron / routines ----------------------------------------------------

    @staticmethod
    def _job_fingerprint(job: dict) -> str:
        parts = []
        for field in (
            "last_run_at", "last_run", "last_finished_at", "updated_at",
            "last_status", "status", "run_count", "runs",
        ):
            if field in job:
                parts.append(f"{field}={job[field]!r}")
        return "|".join(parts)

    async def scan_cron(self) -> None:
        if not self.token:
            return
        try:
            async with self._http() as client:
                resp = await client.get("/api/cron/jobs", params={"profile": "all"})
                if resp.status_code != 200:
                    logger.debug("cron jobs poll: HTTP %s", resp.status_code)
                    return
                data = resp.json()
        except Exception as exc:
            logger.debug("cron jobs poll failed: %s", exc)
            return

        jobs: List[dict] = []
        if isinstance(data, list):
            jobs = [j for j in data if isinstance(j, dict)]
        elif isinstance(data, dict):
            raw = data.get("jobs") or data.get("items") or []
            jobs = [j for j in raw if isinstance(j, dict)]

        for job in jobs:
            job_id = str(job.get("id") or job.get("job_id") or job.get("name") or "")
            if not job_id:
                continue
            name = str(job.get("name") or job.get("title") or job_id)
            fp = self._job_fingerprint(job)
            prev = self._cron_fp.get(job_id)
            self._cron_fp[job_id] = fp
            if not self._cron_baselined or prev is None or prev == fp:
                continue
            status = str(job.get("last_status") or job.get("status") or "").lower()
            if status in {"running", "scheduled", "queued", "pending", "paused"}:
                continue
            ok = status not in {"failed", "error", "unknown"}
            # Routines created by the Talaria app are namespaced
            # "[bot:<name>] <routine>" (see design/HANDOFF.md).
            bot = self._bot_name()
            routine = name
            match = re.match(r"^\[bot:([^\]]+)\]\s*(.*)$", name)
            if match:
                bot, routine = match.group(1), match.group(2) or name
            self.dispatcher.notify(push_mod.routine_event(
                bot=bot, routine=routine, ok=ok,
                detail="" if ok else f"last status: {status or 'failed'}",
            ))
        self._cron_baselined = True

    # -- main loops ---------------------------------------------------------

    def _bot_name(self) -> str:
        return os.environ.get("TALARIA_PUSH_BOT_NAME", "").strip() or "hermes"

    async def ws_loop(self) -> None:
        backoff = 1.0
        last_cron_scan = 0.0
        while not self._stop.is_set():
            if not await self.resolve_token():
                await asyncio.sleep(min(backoff, 30.0))
                backoff = min(backoff * 2, 30.0)
                continue
            url = f"{self.settings.ws_url}?token={self.token}"
            ws = GatewayWS(url)
            try:
                await ws.connect()
                logger.info("connected to %s", self.settings.ws_url)
                backoff = 1.0
                await self.scan_cron()
                last_cron_scan = time.time()
                next_poll = 0.0
                while not self._stop.is_set():
                    now = time.time()
                    if now >= next_poll:
                        await self.poll_sessions(ws)
                        next_poll = now + POLL_INTERVAL_S
                    # Drain broadcast events while waiting for the next poll.
                    params = await ws.next_event(
                        timeout=max(0.05, next_poll - time.time())
                    )
                    if params:
                        etype = str(params.get("type") or "")
                        if etype == "cron.changed":
                            if (
                                time.time() - last_cron_scan
                                >= self.settings.cron_poll_min_interval_s
                            ):
                                await self.scan_cron()
                                last_cron_scan = time.time()
                        elif etype == "sessions.changed":
                            next_poll = 0.0  # rescan promptly
                    if time.time() - last_cron_scan >= CRON_BACKSTOP_S:
                        await self.scan_cron()
                        last_cron_scan = time.time()
            except asyncio.CancelledError:
                raise
            except Exception as exc:
                logger.warning("ws loop error: %s (reconnecting)", exc)
            finally:
                await ws.close()
            # Token rotates on server restart — force a re-scrape unless
            # the operator pinned one via env.
            if not self.settings.token:
                self.token = ""
            try:
                await asyncio.wait_for(self._stop.wait(), min(backoff, 30.0))
            except asyncio.TimeoutError:
                pass
            backoff = min(backoff * 2, 30.0)

    async def run(self) -> None:
        loop = asyncio.get_running_loop()
        for sig in (signal.SIGINT, signal.SIGTERM):
            try:
                loop.add_signal_handler(sig, self._stop.set)
            except NotImplementedError:  # pragma: no cover (non-POSIX)
                pass
        tasks = [
            asyncio.create_task(self.health_loop(), name="health"),
            asyncio.create_task(self.ws_loop(), name="ws"),
        ]
        await self._stop.wait()
        for task in tasks:
            task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        prog="talaria-push-sidecar",
        description=(
            "Standalone Talaria push watcher for a running `hermes serve` "
            "(approvals with request ids, long tasks, routine completions, "
            "gateway offline/recovered)."
        ),
    )
    parser.add_argument(
        "--base-url",
        default=None,
        help="Gateway base URL (default: $TALARIA_GATEWAY_URL or http://127.0.0.1:9119)",
    )
    parser.add_argument(
        "--token",
        default=None,
        help="Dashboard session token (default: $TALARIA_GATEWAY_TOKEN, else scraped from GET /)",
    )
    parser.add_argument("-v", "--verbose", action="store_true")
    args = parser.parse_args(argv)

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s %(name)s %(levelname)s %(message)s",
    )

    settings = SidecarSettings.from_env()
    if args.base_url:
        settings.base_url = args.base_url.rstrip("/")
    if args.token:
        settings.token = args.token

    from .config import apns_settings

    if not apns_settings().configured:
        logger.error(
            "APNs is not configured; set %s. Refusing to start a watcher "
            "that can never deliver.",
            ", ".join(apns_settings().missing()),
        )
        return 2

    asyncio.run(Sidecar(settings).run())
    return 0


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main())
