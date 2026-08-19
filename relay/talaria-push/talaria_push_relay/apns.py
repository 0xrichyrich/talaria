"""Minimal APNs client — HTTP/2 over httpx, ES256 (p8) token auth.

No ``pyapns2``/``aioapns`` dependency: the whole protocol is one
authenticated HTTP/2 POST per notification.

- JWT provider tokens are minted with ``cryptography`` (ES256 over the
  ``.p8`` key) and cached for ~50 minutes — Apple requires refresh
  between 20 and 60 minutes.
- ``httpx.Client(http2=True)`` speaks HTTP/2 for sync callers (hook
  mode runs on agent threads); the sidecar calls the same client via
  ``asyncio.to_thread`` so there is exactly one code path.
- ``410 Unregistered`` (and ``400 BadDeviceToken``) are surfaced as
  ``should_unregister`` so the dispatcher can prune the device.

Wire reference: Apple "Sending notification requests to APNs".
"""

from __future__ import annotations

import base64
import json
import logging
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, Optional

from .config import APNS_HOSTS, APNsSettings

logger = logging.getLogger("talaria_push")

# Refresh the provider JWT after this many seconds (Apple: 20-60 min).
_JWT_TTL_S = 50 * 60


def _b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


@dataclass
class APNsResult:
    ok: bool
    status: int
    reason: str = ""
    apns_id: str = ""

    @property
    def should_unregister(self) -> bool:
        """Device token is dead — prune it from the registry."""
        return (self.status == 410 and self.reason == "Unregistered") or (
            self.status == 400 and self.reason == "BadDeviceToken"
        )

    @property
    def retryable(self) -> bool:
        return (
            self.status in (429, 500, 502, 503)
            or self.status == 0
            or (self.status == 403 and self.reason == "ExpiredProviderToken")
        )


class APNsClient:
    def __init__(self, settings: APNsSettings):
        self._settings = settings
        self._lock = threading.Lock()
        self._jwt: str = ""
        self._jwt_minted_at: float = 0.0
        self._signing_key = None  # lazily loaded EC private key
        self._clients: Dict[str, Any] = {}  # base_url -> httpx.Client

    # -- JWT ---------------------------------------------------------------

    def _load_key(self):
        if self._signing_key is not None:
            return self._signing_key
        from cryptography.hazmat.primitives import serialization

        pem = Path(self._settings.key_p8_path).expanduser().read_bytes()
        self._signing_key = serialization.load_pem_private_key(pem, password=None)
        return self._signing_key

    def _provider_token(self) -> str:
        """Return a cached ES256 provider JWT, re-minting after ~50 min."""
        with self._lock:
            now = time.time()
            if self._jwt and now - self._jwt_minted_at < _JWT_TTL_S:
                return self._jwt

            self._jwt = self._mint_provider_token(now)
            self._jwt_minted_at = now
            return self._jwt

    def _mint_provider_token(self, now: float) -> str:
        """Mint one ES256 provider token. Split for deterministic transport
        tests; production still reaches the same signer through the cache."""

        from cryptography.hazmat.primitives import hashes
        from cryptography.hazmat.primitives.asymmetric import ec, utils

        header = {"alg": "ES256", "kid": self._settings.key_id, "typ": "JWT"}
        claims = {"iss": self._settings.team_id, "iat": int(now)}
        signing_input = (
            _b64url(json.dumps(header, separators=(",", ":")).encode())
            + "."
            + _b64url(json.dumps(claims, separators=(",", ":")).encode())
        ).encode("ascii")

        key = self._load_key()
        der_sig = key.sign(signing_input, ec.ECDSA(hashes.SHA256()))
        # JOSE wants the raw r||s pair (2x32 bytes), not the DER envelope.
        r, s = utils.decode_dss_signature(der_sig)
        raw = r.to_bytes(32, "big") + s.to_bytes(32, "big")

        return signing_input.decode("ascii") + "." + _b64url(raw)

    # -- transport ---------------------------------------------------------

    def _client(self, base_url: str):
        client = self._clients.get(base_url)
        if client is None:
            import httpx

            client = httpx.Client(
                base_url=base_url,
                http2=True,
                timeout=httpx.Timeout(10.0, connect=5.0),
            )
            self._clients[base_url] = client
        return client

    def close(self) -> None:
        for client in self._clients.values():
            try:
                client.close()
            except Exception:
                pass
        self._clients.clear()

    # -- send --------------------------------------------------------------

    def send(
        self,
        device_token: str,
        payload: Dict[str, Any],
        *,
        environment: Optional[str] = None,
        push_type: str = "alert",
        priority: int = 10,
        collapse_id: Optional[str] = None,
        expiration: Optional[int] = None,
    ) -> APNsResult:
        """POST one notification. Returns an :class:`APNsResult`, never raises
        for delivery errors (network failures come back as ``status=0``)."""
        env = environment or self._settings.default_env
        base_url = APNS_HOSTS.get(env, APNS_HOSTS["dev"])

        headers = {
            "authorization": f"bearer {self._provider_token()}",
            "apns-topic": self._settings.topic,
            "apns-push-type": push_type,
            "apns-priority": str(priority),
        }
        if collapse_id:
            headers["apns-collapse-id"] = collapse_id[:64]
        if expiration is not None:
            headers["apns-expiration"] = str(int(expiration))

        try:
            resp = self._client(base_url).post(
                f"/3/device/{device_token}", json=payload, headers=headers
            )
        except Exception as exc:
            logger.warning("talaria-push: APNs POST failed (%s): %s", env, exc)
            return APNsResult(ok=False, status=0, reason=str(exc))

        reason = ""
        if resp.status_code != 200:
            try:
                reason = resp.json().get("reason", "")
            except Exception:
                reason = resp.text[:120]
            # A 403 ExpiredProviderToken can happen if our clock drifted;
            # drop the cache so the next send re-mints.
            if resp.status_code == 403 and reason == "ExpiredProviderToken":
                with self._lock:
                    self._jwt = ""
            logger.warning(
                "talaria-push: APNs %s for …%s: %s",
                resp.status_code, device_token[-8:], reason,
            )
        return APNsResult(
            ok=resp.status_code == 200,
            status=resp.status_code,
            reason=reason,
            apns_id=resp.headers.get("apns-id", ""),
        )
