import asyncio
import json
import tempfile
import unittest
from pathlib import Path
from typing import Any

import httpx

from api_gateway import (
    CapacityScheduler,
    ConfigError,
    GatewayApplication,
    GatewaySettings,
    Profile,
    QueueTimeoutError,
    load_gateway_config,
)


async def call_asgi(
    app: GatewayApplication,
    *,
    method: str = "POST",
    path: str = "/v1/chat/completions",
    payload: dict[str, Any] | None = None,
    token: str = "test-token",
) -> tuple[int, dict[str, str], bytes]:
    body = json.dumps(payload or {}).encode("utf-8")
    received = False
    sent = []

    async def receive() -> dict[str, Any]:
        nonlocal received
        if received:
            return {"type": "http.disconnect"}
        received = True
        return {"type": "http.request", "body": body, "more_body": False}

    async def send(message: dict[str, Any]) -> None:
        sent.append(message)

    headers = [(b"content-type", b"application/json")]
    if token:
        headers.append((b"authorization", f"Bearer {token}".encode()))
    await app(
        {
            "type": "http",
            "method": method,
            "path": path,
            "headers": headers,
        },
        receive,
        send,
    )

    start = next(message for message in sent if message["type"] == "http.response.start")
    response_headers = {
        key.decode().lower(): value.decode()
        for key, value in start.get("headers", [])
    }
    response_body = b"".join(
        message.get("body", b"")
        for message in sent
        if message["type"] == "http.response.body"
    )
    return start["status"], response_headers, response_body


def profiles() -> list[Profile]:
    return [
        Profile("api-1", "https://one.example/v1", "key-1", "model-1", 1),
        Profile("api-2", "https://two.example/v1", "key-2", "model-2", 2),
    ]


class ConfigTests(unittest.TestCase):
    def test_loads_gateway_limits_without_exposing_keys(self) -> None:
        config = """
gateway:
  queue_size: 12
  default_max_concurrency: 3
profiles:
  - name: first
    base_url: https://example.invalid/v1
    api_key: secret
    model: model-a
    max_concurrency: 7
  - base_url: https://example.invalid/v1
    api_key: secret-2
    model: model-b
"""
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "gateway.yaml"
            path.write_text(config, encoding="utf-8")
            settings, loaded_profiles = load_gateway_config(path)

        self.assertEqual(settings.queue_size, 12)
        self.assertEqual(
            [profile.max_concurrency for profile in loaded_profiles],
            [7, 3],
        )
        self.assertEqual(loaded_profiles[1].name, "profile-2")

    def test_rejects_duplicate_profile_names(self) -> None:
        config = """
profiles:
  - {name: duplicate, base_url: https://one.invalid, api_key: a, model: m}
  - {name: duplicate, base_url: https://two.invalid, api_key: b, model: m}
"""
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "gateway.yaml"
            path.write_text(config, encoding="utf-8")
            with self.assertRaisesRegex(ConfigError, "duplicate profile"):
                load_gateway_config(path)


class SchedulerTests(unittest.IsolatedAsyncioTestCase):
    async def test_capacity_weighted_selection_and_hard_limits(self) -> None:
        scheduler = CapacityScheduler(profiles(), GatewaySettings())
        first = await scheduler.acquire()
        second = await scheduler.acquire()
        third = await scheduler.acquire()

        self.assertEqual(
            [first.profile.name, second.profile.name, third.profile.name],
            ["api-1", "api-2", "api-2"],
        )
        self.assertEqual(first.inflight, 1)
        self.assertEqual(second.inflight, 2)

        await scheduler.release(first, "success", 0.1)
        await scheduler.release(second, "success", 0.1)
        await scheduler.release(third, "success", 0.1)

    async def test_waiting_request_times_out_when_capacity_is_full(self) -> None:
        settings = GatewaySettings(queue_timeout_seconds=0.01)
        scheduler = CapacityScheduler([profiles()[0]], settings)
        state = await scheduler.acquire()
        with self.assertRaises(QueueTimeoutError):
            await scheduler.acquire()
        await scheduler.release(state, "success", 0.1)


class GatewayTests(unittest.IsolatedAsyncioTestCase):
    async def test_chatafl_chat_completion_payload_is_compatible(
        self,
    ) -> None:
        forwarded_payload = {}

        async def handler(request: httpx.Request) -> httpx.Response:
            forwarded_payload.update(json.loads(request.content))
            return httpx.Response(
                200,
                json={
                    "choices": [
                        {
                            "message": {
                                "role": "assistant",
                                "content": "ChatAFL-compatible response",
                            }
                        }
                    ]
                },
            )

        client = httpx.AsyncClient(transport=httpx.MockTransport(handler))
        app = GatewayApplication(
            GatewaySettings(access_token="test-token"),
            [profiles()[0]],
            client=client,
        )
        status, _headers, body = await call_asgi(
            app,
            payload={
                "model": "voltron-default",
                "messages": [
                    {"role": "system", "content": "You are a helpful assistant."},
                    {"role": "user", "content": "Generate a protocol message."},
                ],
                "max_tokens": 4096,
                "temperature": 0.5,
            },
        )
        await client.aclose()

        self.assertEqual(status, 200)
        self.assertEqual(forwarded_payload["model"], "model-1")
        self.assertEqual(forwarded_payload["max_tokens"], 4096)
        self.assertEqual(forwarded_payload["temperature"], 0.5)
        self.assertEqual(
            json.loads(body)["choices"][0]["message"]["content"],
            "ChatAFL-compatible response",
        )

    async def test_concurrent_proxy_never_exceeds_profile_limits(self) -> None:
        active = {"key-1": 0, "key-2": 0}
        maximum = {"key-1": 0, "key-2": 0}
        models = {"key-1": set(), "key-2": set()}
        lock = asyncio.Lock()

        async def handler(request: httpx.Request) -> httpx.Response:
            key = request.headers["authorization"].removeprefix("Bearer ")
            request_payload = json.loads(request.content)
            async with lock:
                active[key] += 1
                maximum[key] = max(maximum[key], active[key])
                models[key].add(request_payload["model"])
            await asyncio.sleep(0.02)
            async with lock:
                active[key] -= 1
            return httpx.Response(
                200,
                json={
                    "choices": [
                        {"message": {"role": "assistant", "content": "OK"}}
                    ]
                },
            )

        client = httpx.AsyncClient(transport=httpx.MockTransport(handler))
        app = GatewayApplication(
            GatewaySettings(access_token="test-token"),
            profiles(),
            client=client,
        )
        results = await asyncio.gather(
            *[
                call_asgi(
                    app,
                    payload={
                        "model": "logical-model",
                        "messages": [{"role": "user", "content": "hello"}],
                    },
                )
                for _ in range(12)
            ]
        )
        await client.aclose()

        self.assertTrue(all(status == 200 for status, _headers, _body in results))
        self.assertLessEqual(maximum["key-1"], 1)
        self.assertLessEqual(maximum["key-2"], 2)
        self.assertEqual(models["key-1"], {"model-1"})
        self.assertEqual(models["key-2"], {"model-2"})

    async def test_429_cools_profile_and_fails_over(self) -> None:
        keys = []

        async def handler(request: httpx.Request) -> httpx.Response:
            key = request.headers["authorization"].removeprefix("Bearer ")
            keys.append(key)
            if key == "key-1":
                return httpx.Response(
                    429,
                    headers={"retry-after": "1"},
                    json={"error": {"message": "limited"}},
                )
            return httpx.Response(
                200,
                json={"choices": [{"message": {"content": "OK"}}]},
            )

        client = httpx.AsyncClient(transport=httpx.MockTransport(handler))
        app = GatewayApplication(
            GatewaySettings(access_token="test-token", max_attempts=2),
            profiles(),
            client=client,
        )
        status, _headers, body = await call_asgi(
            app,
            payload={"model": "logical", "messages": []},
        )
        snapshot = await app.scheduler.snapshot()
        await client.aclose()

        self.assertEqual(status, 200)
        self.assertIn(b"choices", body)
        self.assertEqual(keys, ["key-1", "key-2"])
        self.assertEqual(snapshot["profiles"][0]["rate_limits"], 1)
        self.assertGreater(
            snapshot["profiles"][0]["cooldown_remaining_seconds"], 0
        )

    async def test_streaming_response_is_forwarded(self) -> None:
        async def handler(request: httpx.Request) -> httpx.Response:
            self.assertTrue(json.loads(request.content)["stream"])
            return httpx.Response(
                200,
                headers={"content-type": "text/event-stream"},
                content=b'data: {"choices":[{"delta":{"content":"OK"}}]}\n\n',
            )

        client = httpx.AsyncClient(transport=httpx.MockTransport(handler))
        app = GatewayApplication(
            GatewaySettings(access_token="test-token"),
            profiles(),
            client=client,
        )
        status, headers, body = await call_asgi(
            app,
            payload={"model": "logical", "messages": [], "stream": True},
        )
        await client.aclose()

        self.assertEqual(status, 200)
        self.assertEqual(headers["content-type"], "text/event-stream")
        self.assertIn(b'"content":"OK"', body)

    async def test_status_requires_token_and_contains_no_key(self) -> None:
        client = httpx.AsyncClient(transport=httpx.MockTransport(lambda _request: None))
        app = GatewayApplication(
            GatewaySettings(access_token="test-token"),
            profiles(),
            client=client,
        )
        unauthorized = await call_asgi(
            app,
            method="GET",
            path="/admin/status",
            token="wrong",
        )
        authorized = await call_asgi(
            app,
            method="GET",
            path="/admin/status",
        )
        await client.aclose()

        self.assertEqual(unauthorized[0], 401)
        self.assertEqual(authorized[0], 200)
        self.assertNotIn(b"key-1", authorized[2])
        self.assertNotIn(b"key-2", authorized[2])


if __name__ == "__main__":
    unittest.main()
