"""talaria_push_relay — core library for the Talaria APNs push relay.

This package is loaded in three different ways, all sharing the module
name ``talaria_push_relay`` in ``sys.modules`` so state and code are
never duplicated inside one process:

1. By the hermes plugin loader — the plugin's ``__init__.py``
   (``~/.hermes/plugins/talaria-push/__init__.py``) path-loads this
   package and registers lifecycle hooks.
2. By the dashboard web server — ``dashboard/plugin_api.py`` path-loads
   it to serve the device-registration REST routes at
   ``/api/plugins/talaria-push/``.
3. As a normal pip install (``pip install talaria-push-relay``) for the
   standalone sidecar mode (``talaria-push-sidecar`` console script /
   ``python -m talaria_push_relay.sidecar``).

Submodules:

- :mod:`.config`  — env-driven configuration (``TALARIA_APNS_*`` etc.)
- :mod:`.devices` — device registry persisted at
  ``~/.hermes/talaria-push/devices.json`` (0600)
- :mod:`.apns`    — pure-python APNs HTTP/2 client (httpx + ES256 JWT)
- :mod:`.push`    — fan-out dispatcher (payload builders, worker thread,
  410-prune, dedupe)
- :mod:`.events`  — hermes plugin hook handlers (in-process mode)
- :mod:`.sidecar` — standalone WS watcher (sidecar mode)
"""

from __future__ import annotations

__version__ = "0.1.0"

PLUGIN_NAME = "talaria-push"
