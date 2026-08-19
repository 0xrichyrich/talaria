import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "talaria-push"))

from talaria_push_relay.devices import DeviceStore, DeviceValidationError
from talaria_push_relay.apns import APNsResult
from talaria_push_relay.apns import APNsClient
from talaria_push_relay import events
from talaria_push_relay.push import (
    DEFAULT_TEST_KIND,
    PushDispatcher,
    PushEvent,
    payload_for_device,
    synthetic_test_event,
)


class _Store:
    def __init__(self):
        self.removed = []
        self.results = []

    def for_bot(self, _bot):
        return [{"device_token": "ab" * 32, "environment": "dev", "gateway_id": "gw"}]

    def remove(self, token):
        self.removed.append(token)

    def mark_result(self, token, ok):
        self.results.append((token, ok))


class _Client:
    def __init__(self, results):
        self.results = list(results)
        self.calls = []

    def send(self, token, payload, **kwargs):
        self.calls.append((token, payload, kwargs))
        return self.results.pop(0)


class _Dispatcher:
    def __init__(self):
        self.events = []

    def notify(self, event):
        self.events.append(event)


class SourceQualifiedPushTests(unittest.TestCase):
    def test_approval_hook_uses_durable_session_key_when_runtime_id_also_exists(self):
        dispatcher = _Dispatcher()
        with patch.object(events, "current_bot", return_value="worker"), \
             patch.object(events, "_approval_surfaces", return_value={"gateway"}), \
             patch.object(events.push_mod, "get_dispatcher", return_value=dispatcher):
            events.on_pre_approval_request(
                surface="gateway",
                session_key="durable-session-key",
                session_id="ephemeral-runtime-id",
                description="Approve command",
                command="echo safe",
                pattern_key="shell",
            )

        self.assertEqual(len(dispatcher.events), 1)
        event = dispatcher.events[0]
        self.assertEqual(event.kind, "approval")
        self.assertEqual(event.session_id, "durable-session-key")
        self.assertNotEqual(event.session_id, "ephemeral-runtime-id")

    def test_approval_hook_without_durable_key_is_non_actionable(self):
        dispatcher = _Dispatcher()
        with patch.object(events, "current_bot", return_value="worker"), \
             patch.object(events, "_approval_surfaces", return_value={"gateway"}), \
             patch.object(events.push_mod, "get_dispatcher", return_value=dispatcher):
            events.on_pre_approval_request(
                surface="gateway",
                session_key="   ",
                session_id="ephemeral-runtime-id",
                description="Approve command",
                command="echo unsafe",
                pattern_key="shell",
            )

        self.assertEqual(dispatcher.events, [])

    def test_synthetic_test_push_defaults_to_non_actionable_kind(self):
        self.assertEqual(DEFAULT_TEST_KIND, "mention")

    def test_even_approval_shaped_test_has_no_live_authority(self):
        payload = payload_for_device(
            synthetic_test_event("approval"), {"gateway_id": "gateway-a"})
        self.assertEqual(payload["kind"], "approval")
        self.assertEqual(payload["gateway_id"], "gateway-a")
        self.assertEqual(payload["session_id"], "")
        self.assertEqual(payload["approval_request_id"], "")

    def test_registration_persists_source_and_legacy_update_preserves_it(self):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / "devices.json"
            store = DeviceStore(path)
            token = "ab" * 32
            first = store.upsert(token, gateway_id="gateway-a", profile_filter=["default"])
            second = store.upsert(token, profile_filter=["default"])

            self.assertEqual(first["gateway_id"], "gateway-a")
            self.assertEqual(second["gateway_id"], "gateway-a")

    def test_gateway_id_is_bounded(self):
        with tempfile.TemporaryDirectory() as root:
            store = DeviceStore(Path(root) / "devices.json")
            with self.assertRaises(DeviceValidationError):
                store.upsert("cd" * 32, gateway_id="x" * 129)

    def test_payload_is_source_stamped_per_device_and_mutable(self):
        event = PushEvent(kind="approval", bot="default", title="Approve", body="Run it")
        a = payload_for_device(event, {"gateway_id": "gateway-a"})
        b = payload_for_device(event, {"gateway_id": "gateway-b"})

        self.assertEqual(a["gateway_id"], "gateway-a")
        self.assertEqual(b["gateway_id"], "gateway-b")
        self.assertEqual(a["aps"]["mutable-content"], 1)
        self.assertNotEqual(a["gateway_id"], b["gateway_id"])

    def test_every_event_has_a_bounded_expiration(self):
        with patch("talaria_push_relay.push.time.time", return_value=1_000):
            approval = PushEvent(kind="approval", bot="default", title="Approve", body="Run")
            mention = PushEvent(kind="mention", bot="default", title="Ping", body="Hello")
        self.assertEqual(approval.expiration, 1_300)
        self.assertEqual(mention.expiration, 4_600)

    def test_expired_provider_token_remints_and_retries_current_push_without_sleep(self):
        store = _Store()
        client = _Client([
            APNsResult(False, 403, "ExpiredProviderToken"),
            APNsResult(True, 200, "", "apns-id"),
        ])
        dispatcher = PushDispatcher()
        dispatcher._client = client
        event = PushEvent(kind="approval", bot="default", title="Approve", body="Run")

        with patch("talaria_push_relay.push.get_store", return_value=store), \
             patch("talaria_push_relay.push.time.sleep") as sleep:
            dispatcher._fan_out(event)

        self.assertEqual(len(client.calls), 2)
        sleep.assert_not_called()
        self.assertEqual(client.calls[0][2]["expiration"], event.expiration)
        self.assertEqual(client.calls[1][2]["expiration"], event.expiration)
        self.assertEqual(store.results[-1], ("ab" * 32, True))

    def test_retry_prunes_token_that_becomes_unregistered(self):
        store = _Store()
        client = _Client([
            APNsResult(False, 500, "InternalServerError"),
            APNsResult(False, 410, "Unregistered"),
        ])
        dispatcher = PushDispatcher()
        dispatcher._client = client
        event = PushEvent(kind="routine", bot="default", title="Done", body="Done")

        with patch("talaria_push_relay.push.get_store", return_value=store), \
             patch("talaria_push_relay.push.time.sleep"):
            dispatcher._fan_out(event)

        self.assertEqual(store.removed, ["ab" * 32])

    def test_apns_client_clears_expired_cached_jwt_and_remints(self):
        class _Settings:
            default_env = "dev"
            topic = "bot.talaria.test"

        class _Response:
            def __init__(self, status, reason):
                self.status_code = status
                self._reason = reason
                self.text = reason
                self.headers = {}

            def json(self):
                return {"reason": self._reason}

        class _HTTP:
            def __init__(self):
                self.responses = [
                    _Response(403, "ExpiredProviderToken"),
                    _Response(200, ""),
                ]
                self.authorizations = []

            def post(self, _path, json, headers):
                self.authorizations.append(headers["authorization"])
                return self.responses.pop(0)

        class _MintingClient(APNsClient):
            def __init__(self):
                super().__init__(_Settings())
                self.mints = 0

            def _mint_provider_token(self, now):
                self.mints += 1
                return f"jwt-{self.mints}"

        client = _MintingClient()
        http = _HTTP()
        client._clients["https://api.sandbox.push.apple.com"] = http
        token = "ab" * 32

        first = client.send(token, {"aps": {}})
        second = client.send(token, {"aps": {}})

        self.assertEqual(first.reason, "ExpiredProviderToken")
        self.assertTrue(second.ok)
        self.assertEqual(client.mints, 2)
        self.assertEqual(http.authorizations, ["bearer jwt-1", "bearer jwt-2"])


if __name__ == "__main__":
    unittest.main()
