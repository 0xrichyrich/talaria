"""talaria-push — hermes plugin entry point.

Installed at ``~/.hermes/plugins/talaria-push/``. The hermes plugin
loader imports this file as ``hermes_plugins.<slug>`` and calls
:func:`register`.

The actual logic lives in the ``talaria_push_relay`` package next to
this file. It is loaded under its CANONICAL module name (not as a
relative submodule of the plugin namespace) so that the dashboard's
``plugin_api.py`` — imported separately by the web server — and a
pip-installed sidecar all share one ``sys.modules['talaria_push_relay']``
inside a given process: one dispatcher, one dedupe window, one APNs
client.
"""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path

_PKG = "talaria_push_relay"


def _load_relay_pkg():
    """Import talaria_push_relay, preferring an existing/pip install."""
    if _PKG in sys.modules:
        return sys.modules[_PKG]
    try:
        return importlib.import_module(_PKG)  # pip-installed copy
    except ImportError:
        pass
    # Fall back to loading the copy shipped inside this plugin directory.
    pkg_dir = Path(__file__).resolve().parent / _PKG
    spec = importlib.util.spec_from_file_location(
        _PKG,
        pkg_dir / "__init__.py",
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


def register(ctx) -> None:
    """Hermes plugin registration — wire the relay's lifecycle hooks."""
    _load_relay_pkg()
    from talaria_push_relay.config import relay_settings
    from talaria_push_relay.events import register_hooks

    if relay_settings().disabled:
        import logging

        logging.getLogger("talaria_push").info(
            "talaria-push: TALARIA_PUSH_DISABLE is set; hooks not registered"
        )
        return
    register_hooks(ctx)
