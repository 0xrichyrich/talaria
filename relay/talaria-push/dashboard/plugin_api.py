"""talaria-push dashboard plugin — device-registration REST routes.

Mounted by the hermes web server at ``/api/plugins/talaria-push/``
(``hermes_cli/web_server.py::_mount_plugin_api_routes``). Like every
``/api/plugins/...`` route, requests pass the dashboard's session-token
auth middleware first: callers must present ``X-Hermes-Session-Token``
(loopback mode) or an authenticated cookie/OAuth session (gated mode).
There is no additional per-route secret — whoever is authenticated to
the dashboard owns push registration, same trust model as the rest of
the dashboard API.

Routes (all relative to /api/plugins/talaria-push):

- ``POST   /devices``                register/refresh a device token
- ``GET    /devices``                list registrations
- ``DELETE /devices``                unregister (token in body or query)
- ``DELETE /devices/{device_token}`` unregister (path form)
- ``GET    /status``                 APNs config + registry health probe
- ``POST   /test``                   send a test push (setup validation)

The store lives at ``~/.hermes/talaria-push/devices.json`` (0600) under
the ROOT hermes home, shared by every profile/bot — registration is a
device-level concern, filtering is per-record via ``profile_filter``.
"""

from __future__ import annotations

import importlib
import importlib.util
import logging
import sys
from pathlib import Path
from typing import Any, List, Optional, Union

from fastapi import APIRouter, HTTPException, Query
from pydantic import BaseModel, Field

log = logging.getLogger("talaria_push.api")

# ---------------------------------------------------------------------------
# Load talaria_push_relay under its canonical module name (shared with the
# plugin-loader import and any pip install in this process — one dispatcher,
# one device store, one APNs client per process).
# ---------------------------------------------------------------------------

_PKG = "talaria_push_relay"


def _load_relay_pkg():
    if _PKG in sys.modules:
        return sys.modules[_PKG]
    try:
        return importlib.import_module(_PKG)
    except ImportError:
        pass
    pkg_dir = Path(__file__).resolve().parent.parent / _PKG
    spec = importlib.util.spec_from_file_location(
        _PKG, pkg_dir / "__init__.py",
        submodule_search_locations=[str(pkg_dir)],
    )
    if spec is None or spec.loader is None:  # pragma: no cover
        raise ImportError(f"cannot load {_PKG} from {pkg_dir}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[_PKG] = module
    try:
        spec.loader.exec_module(module)
    except BaseException:
        sys.modules.pop(_PKG, None)
        raise
    return module


_load_relay_pkg()

from talaria_push_relay import push as push_mod  # noqa: E402
from talaria_push_relay.config import (  # noqa: E402
    ALL_EVENT_KINDS,
    apns_settings,
    devices_path,
    relay_settings,
)
from talaria_push_relay.devices import (  # noqa: E402
    DeviceValidationError,
    get_store,
)

router = APIRouter()


# ---------------------------------------------------------------------------
# Models
# ---------------------------------------------------------------------------


class DeviceRegistration(BaseModel):
    device_token: str = Field(..., description="Hex APNs device token")
    platform: str = Field("ios")
    environment: str = Field("dev", description="'dev' (sandbox) or 'prod'")
    gateway_id: Optional[str] = Field(
        None,
        description="Talaria's stable saved-connection id for source-qualified routing",
    )
    profile_filter: Optional[Union[str, List[str]]] = Field(
        None,
        description=(
            "Bots (hermes profiles) this device wants pushes for; "
            "omit/empty = all bots"
        ),
    )


class DeviceRemoval(BaseModel):
    device_token: str


class TestPush(BaseModel):
    device_token: Optional[str] = Field(
        None, description="Limit the test to one registered token"
    )
    # A synthetic test has no authoritative Hermes session/request to approve.
    # Default to a non-actionable category; callers may still explicitly ask
    # for an approval-shaped display test, whose buttons intentionally fail closed.
    kind: str = Field(push_mod.DEFAULT_TEST_KIND, description=f"One of {ALL_EVENT_KINDS}")


# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------


@router.post("/devices", status_code=201)
async def register_device(body: DeviceRegistration):
    try:
        record = get_store().upsert(
            device_token=body.device_token,
            platform=body.platform,
            environment=body.environment,
            gateway_id=body.gateway_id,
            profile_filter=body.profile_filter,
        )
    except DeviceValidationError as exc:
        raise HTTPException(status_code=400, detail=str(exc))
    return {"device": record}


@router.get("/devices")
async def list_devices():
    return {"devices": get_store().list()}


def _remove(token: str) -> dict:
    if not token:
        raise HTTPException(status_code=400, detail="device_token required")
    removed = get_store().remove(token)
    if not removed:
        raise HTTPException(status_code=404, detail="device not registered")
    return {"removed": True}


@router.delete("/devices")
async def remove_device(
    body: Optional[DeviceRemoval] = None,
    device_token: str = Query("", description="Alternative to the JSON body"),
):
    return _remove((body.device_token if body else "") or device_token)


@router.delete("/devices/{device_token}")
async def remove_device_by_path(device_token: str):
    return _remove(device_token)


@router.get("/status")
async def status():
    settings = apns_settings(refresh=True)
    relay = relay_settings(refresh=True)
    store_path = devices_path()
    mode_bits: Optional[str] = None
    try:
        mode_bits = oct(store_path.stat().st_mode & 0o777)
    except OSError:
        pass
    return {
        "apns_configured": settings.configured,
        "apns_missing_env": settings.missing(),
        "apns_topic": settings.topic,
        "apns_default_env": settings.default_env,
        "relay_disabled": relay.disabled,
        "enabled_events": relay.enabled_events,
        "long_task_min_s": relay.long_task_min_s,
        "mention_handles": relay.mention_handles,
        "device_count": len(get_store().list()),
        "devices_path": str(store_path),
        "devices_mode": mode_bits,
    }


@router.post("/test")
async def send_test_push(body: TestPush):
    """Send a test notification through the real pipeline.

    Useful during setup: verifies the .p8 key, key/team id, topic, and
    the device token end to end. Bypasses the kind-enabled filter check
    only in the sense that it uses kind's payload shape; delivery still
    requires APNs config and a registered device.
    """
    settings = apns_settings(refresh=True)
    if not settings.configured:
        raise HTTPException(
            status_code=409,
            detail=f"APNs not configured; missing {', '.join(settings.missing())}",
        )
    kind = body.kind if body.kind in ALL_EVENT_KINDS else push_mod.DEFAULT_TEST_KIND
    store = get_store()
    devices = store.list()
    if body.device_token:
        devices = [
            d for d in devices
            if d["device_token"] == body.device_token.strip().lower()
        ]
    if not devices:
        raise HTTPException(status_code=404, detail="no matching registered device")

    event = push_mod.synthetic_test_event(kind)
    client = push_mod.get_dispatcher()._get_client()
    results = []
    for dev in devices:
        payload = push_mod.payload_for_device(event, dev)
        result = client.send(
            dev["device_token"], payload,
            environment=dev.get("environment"),
            collapse_id="talaria-test",
            expiration=event.expiration,
        )
        if result.should_unregister:
            store.remove(dev["device_token"])
        results.append({
            "device_token_suffix": dev["device_token"][-8:],
            "ok": result.ok,
            "status": result.status,
            "reason": result.reason,
            "pruned": result.should_unregister,
        })
    return {"results": results}
