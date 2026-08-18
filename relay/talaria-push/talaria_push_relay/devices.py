"""Device registry — ``~/.hermes/talaria-push/devices.json`` (0600).

Both the web server process (REST registration) and agent/gateway
processes (hook-driven fan-out) read and write this file, so every
mutation re-reads from disk under an advisory ``fcntl`` lock and writes
atomically (tmp file + ``os.replace``). Last-writer-wins per mutation;
the record granularity (one entry per device token) keeps races
harmless in practice.

Schema (version 1)::

    {
      "version": 1,
      "devices": {
        "<device_token>": {
          "device_token": str,        # APNs token, lowercase hex
          "platform": "ios",
          "environment": "dev"|"prod",  # APNs sandbox vs production
          "profile_filter": [str],    # [] = all bots
          "created_at": float,        # unix epoch
          "updated_at": float,
          "last_push_at": float|null,
          "failures": int             # consecutive send failures
        }, ...
      }
    }
"""

from __future__ import annotations

import json
import logging
import os
import re
import tempfile
import threading
import time
from contextlib import contextmanager
from pathlib import Path
from typing import Any, Dict, List, Optional

from .config import devices_path

logger = logging.getLogger("talaria_push")

_SCHEMA_VERSION = 1
_TOKEN_RE = re.compile(r"^[0-9a-fA-F]{32,512}$")

_local_lock = threading.Lock()


class DeviceValidationError(ValueError):
    """Raised when a registration payload is malformed."""


def normalize_token(token: str) -> str:
    token = (token or "").strip().lower()
    if not _TOKEN_RE.match(token):
        raise DeviceValidationError(
            "device_token must be the hex-encoded APNs token (32-512 hex chars)"
        )
    return token


def _normalize_profile_filter(value: Any) -> List[str]:
    """Accept ``None`` / ``"bot"`` / ``"a,b"`` / ``["a","b"]`` → list."""
    if value is None or value == "":
        return []
    if isinstance(value, str):
        parts = [p.strip() for p in value.split(",")]
    elif isinstance(value, (list, tuple)):
        parts = [str(p).strip() for p in value]
    else:
        raise DeviceValidationError("profile_filter must be a string or list of strings")
    out = [p for p in parts if p]
    if len(out) > 64:
        raise DeviceValidationError("profile_filter: too many entries")
    for p in out:
        if len(p) > 128:
            raise DeviceValidationError("profile_filter: entry too long")
    return out


@contextmanager
def _file_lock(path: Path):
    """Best-effort cross-process advisory lock next to the store."""
    lock_path = path.with_suffix(".lock")
    fd: Optional[int] = None
    try:
        fd = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o600)
        try:
            import fcntl

            fcntl.flock(fd, fcntl.LOCK_EX)
        except Exception:
            pass  # non-POSIX or locked-out: fall back to in-process lock only
        yield
    finally:
        if fd is not None:
            try:
                import fcntl

                fcntl.flock(fd, fcntl.LOCK_UN)
            except Exception:
                pass
            os.close(fd)


def _read_store(path: Path) -> Dict[str, Any]:
    if not path.exists():
        return {"version": _SCHEMA_VERSION, "devices": {}}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        if not isinstance(data, dict) or not isinstance(data.get("devices"), dict):
            raise ValueError("bad shape")
        return data
    except Exception as exc:
        # Never let a corrupt store break approvals; start fresh but keep
        # the corrupt file for post-mortem.
        logger.warning("talaria-push: devices.json unreadable (%s); resetting", exc)
        try:
            path.replace(path.with_suffix(".corrupt"))
        except OSError:
            pass
        return {"version": _SCHEMA_VERSION, "devices": {}}


def _write_store(path: Path, data: Dict[str, Any]) -> None:
    payload = json.dumps(data, indent=2, sort_keys=True)
    fd, tmp = tempfile.mkstemp(dir=str(path.parent), prefix=".devices-", suffix=".tmp")
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(payload)
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, path)
        os.chmod(path, 0o600)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


class DeviceStore:
    """Thin, always-reload-from-disk device registry."""

    def __init__(self, path: Optional[Path] = None):
        self._path = path or devices_path()

    # -- queries -----------------------------------------------------------

    def list(self) -> List[Dict[str, Any]]:
        with _local_lock:
            store = _read_store(self._path)
        return sorted(store["devices"].values(), key=lambda d: d.get("created_at", 0))

    def for_bot(self, bot: str) -> List[Dict[str, Any]]:
        """Devices whose profile_filter is empty or contains ``bot``."""
        out = []
        for dev in self.list():
            flt = dev.get("profile_filter") or []
            if not flt or bot in flt:
                out.append(dev)
        return out

    # -- mutations ---------------------------------------------------------

    def upsert(
        self,
        device_token: str,
        platform: str = "ios",
        environment: str = "dev",
        profile_filter: Any = None,
    ) -> Dict[str, Any]:
        token = normalize_token(device_token)
        platform = (platform or "ios").strip().lower()
        if platform != "ios":
            raise DeviceValidationError("platform must be 'ios'")
        environment = (environment or "dev").strip().lower()
        if environment not in ("dev", "prod"):
            raise DeviceValidationError("environment must be 'dev' or 'prod'")
        flt = _normalize_profile_filter(profile_filter)

        now = time.time()
        with _local_lock, _file_lock(self._path):
            store = _read_store(self._path)
            existing = store["devices"].get(token, {})
            record = {
                "device_token": token,
                "platform": platform,
                "environment": environment,
                "profile_filter": flt,
                "created_at": existing.get("created_at", now),
                "updated_at": now,
                "last_push_at": existing.get("last_push_at"),
                "failures": 0,
            }
            store["devices"][token] = record
            _write_store(self._path, store)
        logger.info(
            "talaria-push: registered device …%s (%s, filter=%s)",
            token[-8:], environment, flt or "all",
        )
        return record

    def remove(self, device_token: str) -> bool:
        try:
            token = normalize_token(device_token)
        except DeviceValidationError:
            return False
        with _local_lock, _file_lock(self._path):
            store = _read_store(self._path)
            removed = store["devices"].pop(token, None) is not None
            if removed:
                _write_store(self._path, store)
        if removed:
            logger.info("talaria-push: removed device …%s", token[-8:])
        return removed

    def mark_result(self, device_token: str, ok: bool) -> None:
        """Record a send outcome (resets/increments the failure counter)."""
        try:
            token = normalize_token(device_token)
        except DeviceValidationError:
            return
        with _local_lock, _file_lock(self._path):
            store = _read_store(self._path)
            dev = store["devices"].get(token)
            if dev is None:
                return
            if ok:
                dev["failures"] = 0
                dev["last_push_at"] = time.time()
            else:
                dev["failures"] = int(dev.get("failures", 0)) + 1
            _write_store(self._path, store)


_store: Optional[DeviceStore] = None


def get_store() -> DeviceStore:
    global _store
    if _store is None:
        _store = DeviceStore()
    return _store
