#!/usr/bin/env python3

"""Capacity-aware OpenAI-compatible gateway for VoltronBench."""

from __future__ import annotations

import argparse
import asyncio
import hmac
import json
import os
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Awaitable, Callable
from urllib.parse import urlparse

import httpx
import yaml


RETRYABLE_STATUS_CODES = {429, 502, 503, 504}
FORWARDED_RESPONSE_HEADERS = {
    "content-type",
    "retry-after",
    "x-request-id",
}
IGNORED_REQUEST_HEADERS = {
    "authorization",
    "connection",
    "content-length",
    "host",
    "proxy-authorization",
    "transfer-encoding",
}


class ConfigError(ValueError):
    """Raised when the gateway configuration is invalid."""


class QueueFullError(RuntimeError):
    """Raised when the bounded gateway queue has no free position."""


class QueueTimeoutError(TimeoutError):
    """Raised when no upstream capacity becomes available in time."""


@dataclass(frozen=True)
class GatewaySettings:
    host: str = "0.0.0.0"
    port: int = 8000
    queue_size: int = 256
    queue_timeout_seconds: float = 30.0
    upstream_timeout_seconds: float = 120.0
    max_attempts: int = 2
    rate_limit_cooldown_seconds: float = 5.0
    failure_threshold: int = 3
    circuit_cooldown_seconds: float = 30.0
    max_body_bytes: int = 10 * 1024 * 1024
    default_max_concurrency: int = 1
    access_token: str = ""


@dataclass(frozen=True)
class Profile:
    name: str
    base_url: str
    api_key: str
    model: str
    max_concurrency: int
    enabled: bool = True


@dataclass
class ProfileState:
    profile: Profile
    inflight: int = 0
    cooldown_until: float = 0.0
    disabled_reason: str | None = None
    consecutive_failures: int = 0
    requests: int = 0
    successes: int = 0
    failures: int = 0
    rate_limits: int = 0
    latency_ewma_seconds: float | None = None

    def available(self, now: float) -> bool:
        return (
            self.profile.enabled
            and self.disabled_reason is None
            and now >= self.cooldown_until
            and self.inflight < self.profile.max_concurrency
        )


def _mapping(value: Any, label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ConfigError(f"{label} must be a mapping")
    return value


def _positive_int(mapping: dict[str, Any], key: str, default: int) -> int:
    value = mapping.get(key, default)
    if isinstance(value, bool) or not isinstance(value, int) or value <= 0:
        raise ConfigError(f"{key} must be a positive integer")
    return value


def _positive_float(mapping: dict[str, Any], key: str, default: float) -> float:
    value = mapping.get(key, default)
    if isinstance(value, bool) or not isinstance(value, (int, float)) or value <= 0:
        raise ConfigError(f"{key} must be greater than zero")
    return float(value)


def load_gateway_config(path: Path) -> tuple[GatewaySettings, list[Profile]]:
    try:
        document = yaml.safe_load(path.read_text(encoding="utf-8"))
    except OSError as error:
        raise ConfigError(f"cannot read {path}: {error}") from error
    except yaml.YAMLError as error:
        raise ConfigError(f"cannot parse {path}: {error}") from error

    root = _mapping(document, "document root")
    raw_gateway = root.get("gateway", {})
    gateway = _mapping(raw_gateway, "gateway")

    default_limit = _positive_int(
        gateway,
        "default_max_concurrency",
        int(os.environ.get("VOLTRON_GATEWAY_DEFAULT_MAX_CONCURRENCY", "1")),
    )
    token = os.environ.get(
        "VOLTRON_GATEWAY_TOKEN",
        str(gateway.get("access_token", "voltronbench-internal")),
    )
    settings = GatewaySettings(
        host=str(gateway.get("listen", "0.0.0.0")),
        port=_positive_int(gateway, "port", 8000),
        queue_size=_positive_int(gateway, "queue_size", 256),
        queue_timeout_seconds=_positive_float(
            gateway, "queue_timeout_seconds", 30.0
        ),
        upstream_timeout_seconds=_positive_float(
            gateway, "upstream_timeout_seconds", 120.0
        ),
        max_attempts=_positive_int(gateway, "max_attempts", 2),
        rate_limit_cooldown_seconds=_positive_float(
            gateway, "rate_limit_cooldown_seconds", 5.0
        ),
        failure_threshold=_positive_int(gateway, "failure_threshold", 3),
        circuit_cooldown_seconds=_positive_float(
            gateway, "circuit_cooldown_seconds", 30.0
        ),
        max_body_bytes=_positive_int(
            gateway, "max_body_bytes", 10 * 1024 * 1024
        ),
        default_max_concurrency=default_limit,
        access_token=token,
    )

    raw_profiles = root.get("profiles")
    if not isinstance(raw_profiles, list) or not raw_profiles:
        raise ConfigError("profiles must be a non-empty list")

    profiles = []
    names = set()
    for index, raw_profile in enumerate(raw_profiles, start=1):
        profile_data = _mapping(raw_profile, f"profiles[{index}]")
        name = str(profile_data.get("name", f"profile-{index}")).strip()
        if not name:
            raise ConfigError(f"profiles[{index}].name cannot be empty")
        if name in names:
            raise ConfigError(f"duplicate profile name: {name}")
        names.add(name)

        values = {}
        for key in ("base_url", "api_key", "model"):
            value = profile_data.get(key)
            if not isinstance(value, str) or not value.strip():
                raise ConfigError(
                    f"profiles[{index}].{key} must be a non-empty string"
                )
            if "\0" in value:
                raise ConfigError(f"profiles[{index}].{key} contains a NUL byte")
            values[key] = value.strip()

        parsed_url = urlparse(values["base_url"])
        if parsed_url.scheme not in {"http", "https"} or not parsed_url.netloc:
            raise ConfigError(
                f"profiles[{index}].base_url must be an HTTP(S) URL"
            )

        enabled = profile_data.get("enabled", True)
        if not isinstance(enabled, bool):
            raise ConfigError(f"profiles[{index}].enabled must be a boolean")
        profiles.append(
            Profile(
                name=name,
                base_url=values["base_url"],
                api_key=values["api_key"],
                model=values["model"],
                max_concurrency=_positive_int(
                    profile_data, "max_concurrency", default_limit
                ),
                enabled=enabled,
            )
        )

    if not any(profile.enabled for profile in profiles):
        raise ConfigError("at least one profile must be enabled")
    return settings, profiles


class CapacityScheduler:
    def __init__(
        self,
        profiles: list[Profile],
        settings: GatewaySettings,
        *,
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        self.states = [ProfileState(profile=profile) for profile in profiles]
        self.settings = settings
        self.clock = clock
        self.condition = asyncio.Condition()
        self.waiting = 0
        self.round_robin_cursor = 0

    def _choose(self, excluded: set[str]) -> ProfileState | None:
        now = self.clock()
        candidates = [
            state
            for state in self.states
            if state.profile.name not in excluded and state.available(now)
        ]
        if not candidates:
            return None
        minimum = min(
            state.inflight / state.profile.max_concurrency
            for state in candidates
        )
        tied = [
            state
            for state in candidates
            if state.inflight / state.profile.max_concurrency == minimum
        ]
        selected = tied[self.round_robin_cursor % len(tied)]
        self.round_robin_cursor += 1
        return selected

    async def acquire(
        self,
        excluded: set[str] | None = None,
        timeout: float | None = None,
    ) -> ProfileState:
        excluded = excluded or set()
        timeout = (
            self.settings.queue_timeout_seconds if timeout is None else timeout
        )
        deadline = self.clock() + timeout

        async with self.condition:
            selected = self._choose(excluded)
            if selected is not None:
                selected.inflight += 1
                selected.requests += 1
                return selected
            if self.waiting >= self.settings.queue_size:
                raise QueueFullError("gateway queue is full")

            self.waiting += 1
            try:
                while True:
                    remaining = deadline - self.clock()
                    if remaining <= 0:
                        raise QueueTimeoutError("upstream capacity wait timed out")
                    now = self.clock()
                    cooldown_delays = [
                        state.cooldown_until - now
                        for state in self.states
                        if state.profile.name not in excluded
                        and state.profile.enabled
                        and state.disabled_reason is None
                        and state.cooldown_until > now
                    ]
                    wait_timeout = remaining
                    if cooldown_delays:
                        wait_timeout = min(wait_timeout, min(cooldown_delays))
                    try:
                        await asyncio.wait_for(
                            self.condition.wait(), timeout=wait_timeout
                        )
                    except asyncio.TimeoutError:
                        if self.clock() >= deadline:
                            raise QueueTimeoutError(
                                "upstream capacity wait timed out"
                            )
                    selected = self._choose(excluded)
                    if selected is not None:
                        selected.inflight += 1
                        selected.requests += 1
                        return selected
            finally:
                self.waiting -= 1

    async def release(
        self,
        state: ProfileState,
        outcome: str,
        latency_seconds: float,
    ) -> None:
        async with self.condition:
            state.inflight = max(0, state.inflight - 1)
            if latency_seconds >= 0:
                if state.latency_ewma_seconds is None:
                    state.latency_ewma_seconds = latency_seconds
                else:
                    state.latency_ewma_seconds = (
                        state.latency_ewma_seconds * 0.8
                        + latency_seconds * 0.2
                    )

            now = self.clock()
            if outcome == "success":
                state.successes += 1
                state.consecutive_failures = 0
            elif outcome == "rate_limit":
                state.failures += 1
                state.rate_limits += 1
                state.consecutive_failures += 1
                state.cooldown_until = max(
                    state.cooldown_until,
                    now + self.settings.rate_limit_cooldown_seconds,
                )
            elif outcome == "auth_failure":
                state.failures += 1
                state.consecutive_failures += 1
                state.disabled_reason = "authentication_failed"
            elif outcome in {"connect_failure", "upstream_failure"}:
                state.failures += 1
                state.consecutive_failures += 1
                if (
                    state.consecutive_failures
                    >= self.settings.failure_threshold
                ):
                    state.cooldown_until = max(
                        state.cooldown_until,
                        now + self.settings.circuit_cooldown_seconds,
                    )
                    state.consecutive_failures = 0
            elif outcome == "client_error":
                state.failures += 1
            self.condition.notify_all()

    async def snapshot(self) -> dict[str, Any]:
        async with self.condition:
            now = self.clock()
            return {
                "waiting": self.waiting,
                "profiles": [
                    {
                        "name": state.profile.name,
                        "model": state.profile.model,
                        "enabled": state.profile.enabled,
                        "available": state.available(now),
                        "disabled_reason": state.disabled_reason,
                        "inflight": state.inflight,
                        "max_concurrency": state.profile.max_concurrency,
                        "cooldown_remaining_seconds": round(
                            max(0.0, state.cooldown_until - now), 3
                        ),
                        "requests": state.requests,
                        "successes": state.successes,
                        "failures": state.failures,
                        "rate_limits": state.rate_limits,
                        "latency_ewma_seconds": (
                            round(state.latency_ewma_seconds, 6)
                            if state.latency_ewma_seconds is not None
                            else None
                        ),
                    }
                    for state in self.states
                ],
            }


class GatewayApplication:
    def __init__(
        self,
        settings: GatewaySettings,
        profiles: list[Profile],
        *,
        client: httpx.AsyncClient | None = None,
    ) -> None:
        self.settings = settings
        self.scheduler = CapacityScheduler(profiles, settings)
        self.client = client or httpx.AsyncClient(
            timeout=httpx.Timeout(settings.upstream_timeout_seconds)
        )
        self.owns_client = client is None

    async def close(self) -> None:
        if self.owns_client:
            await self.client.aclose()

    async def __call__(
        self,
        scope: dict[str, Any],
        receive: Callable[[], Awaitable[dict[str, Any]]],
        send: Callable[[dict[str, Any]], Awaitable[None]],
    ) -> None:
        if scope["type"] == "lifespan":
            await self._lifespan(receive, send)
            return
        if scope["type"] != "http":
            return

        path = scope.get("path", "")
        method = scope.get("method", "GET").upper()
        if method == "GET" and path == "/healthz":
            await self._json_response(send, 200, {"status": "ok"})
            return
        if method == "GET" and path == "/readyz":
            snapshot = await self.scheduler.snapshot()
            ready = any(
                profile["enabled"] and profile["disabled_reason"] is None
                for profile in snapshot["profiles"]
            )
            await self._json_response(
                send, 200 if ready else 503, {"ready": ready}
            )
            return
        if method == "GET" and path == "/admin/status":
            if not self._authorized(scope):
                await self._error(send, 401, "unauthorized")
                return
            await self._json_response(send, 200, await self.scheduler.snapshot())
            return
        if method != "POST" or path != "/v1/chat/completions":
            await self._error(send, 404, "not_found")
            return
        if not self._authorized(scope):
            await self._error(send, 401, "unauthorized")
            return

        try:
            body = await self._read_body(receive)
        except ValueError as error:
            await self._error(send, 413, str(error))
            return
        try:
            payload = json.loads(body)
        except (UnicodeDecodeError, json.JSONDecodeError):
            await self._error(send, 400, "request body must be valid JSON")
            return
        if not isinstance(payload, dict):
            await self._error(send, 400, "request body must be a JSON object")
            return

        await self._proxy(scope, send, payload)

    async def _lifespan(
        self,
        receive: Callable[[], Awaitable[dict[str, Any]]],
        send: Callable[[dict[str, Any]], Awaitable[None]],
    ) -> None:
        while True:
            message = await receive()
            if message["type"] == "lifespan.startup":
                await send({"type": "lifespan.startup.complete"})
            elif message["type"] == "lifespan.shutdown":
                await self.close()
                await send({"type": "lifespan.shutdown.complete"})
                return

    def _authorized(self, scope: dict[str, Any]) -> bool:
        if not self.settings.access_token:
            return True
        headers = {
            key.decode("latin-1").lower(): value.decode("latin-1")
            for key, value in scope.get("headers", [])
        }
        authorization = headers.get("authorization", "")
        expected = f"Bearer {self.settings.access_token}"
        return hmac.compare_digest(authorization, expected)

    async def _read_body(
        self,
        receive: Callable[[], Awaitable[dict[str, Any]]],
    ) -> bytes:
        chunks = []
        size = 0
        more_body = True
        while more_body:
            message = await receive()
            if message["type"] == "http.disconnect":
                raise ValueError("client disconnected")
            chunk = message.get("body", b"")
            size += len(chunk)
            if size > self.settings.max_body_bytes:
                raise ValueError("request body is too large")
            chunks.append(chunk)
            more_body = message.get("more_body", False)
        return b"".join(chunks)

    def _upstream_headers(
        self,
        scope: dict[str, Any],
        profile: Profile,
    ) -> dict[str, str]:
        headers = {
            key.decode("latin-1"): value.decode("latin-1")
            for key, value in scope.get("headers", [])
            if key.decode("latin-1").lower() not in IGNORED_REQUEST_HEADERS
        }
        headers["Authorization"] = f"Bearer {profile.api_key}"
        headers["Content-Type"] = "application/json"
        return headers

    async def _proxy(
        self,
        scope: dict[str, Any],
        send: Callable[[dict[str, Any]], Awaitable[None]],
        payload: dict[str, Any],
    ) -> None:
        excluded: set[str] = set()
        last_status = 503
        last_body = b'{"error":{"message":"no upstream API is available"}}'
        last_headers = [(b"content-type", b"application/json")]

        for _attempt in range(self.settings.max_attempts):
            if all(
                state.profile.name in excluded
                for state in self.scheduler.states
            ):
                break
            try:
                state = await self.scheduler.acquire(excluded)
            except QueueFullError:
                await self._error(
                    send,
                    429,
                    "gateway queue is full",
                    headers=[(b"retry-after", b"1")],
                )
                return
            except QueueTimeoutError:
                await self._error(
                    send,
                    503,
                    "timed out waiting for upstream capacity",
                    headers=[(b"retry-after", b"1")],
                )
                return

            profile = state.profile
            excluded.add(profile.name)
            upstream_payload = dict(payload)
            upstream_payload["model"] = profile.model
            url = (
                f"{profile.base_url.rstrip('/')}/chat/completions"
            )
            request = self.client.build_request(
                "POST",
                url,
                headers=self._upstream_headers(scope, profile),
                json=upstream_payload,
            )
            started = time.monotonic()
            released = False
            response_started = False
            response: httpx.Response | None = None
            try:
                response = await self.client.send(request, stream=True)
                response_headers = self._response_headers(response)
                status = response.status_code

                if status in RETRYABLE_STATUS_CODES:
                    last_status = status
                    last_body = await response.aread()
                    last_headers = response_headers
                    outcome = "rate_limit" if status == 429 else "upstream_failure"
                    await self.scheduler.release(
                        state, outcome, time.monotonic() - started
                    )
                    released = True
                    await response.aclose()
                    continue
                if status in {401, 403}:
                    last_status = status
                    last_body = await response.aread()
                    last_headers = response_headers
                    await self.scheduler.release(
                        state, "auth_failure", time.monotonic() - started
                    )
                    released = True
                    await response.aclose()
                    continue

                if payload.get("stream") is not True:
                    response_body = await response.aread()
                    await send(
                        {
                            "type": "http.response.start",
                            "status": status,
                            "headers": response_headers,
                        }
                    )
                    await send(
                        {
                            "type": "http.response.body",
                            "body": response_body,
                            "more_body": False,
                        }
                    )
                    outcome = (
                        "success"
                        if 200 <= status < 300
                        else "client_error"
                    )
                    await self.scheduler.release(
                        state, outcome, time.monotonic() - started
                    )
                    released = True
                    await response.aclose()
                    return

                await send(
                    {
                        "type": "http.response.start",
                        "status": status,
                        "headers": response_headers,
                    }
                )
                response_started = True
                async for chunk in response.aiter_bytes():
                    await send(
                        {
                            "type": "http.response.body",
                            "body": chunk,
                            "more_body": True,
                        }
                    )
                await send(
                    {
                        "type": "http.response.body",
                        "body": b"",
                        "more_body": False,
                    }
                )
                outcome = "success" if 200 <= status < 300 else "client_error"
                await self.scheduler.release(
                    state, outcome, time.monotonic() - started
                )
                released = True
                await response.aclose()
                return
            except (httpx.ConnectError, httpx.ConnectTimeout):
                last_status = 502
                last_body = (
                    b'{"error":{"message":"failed to connect to upstream API"}}'
                )
                await self.scheduler.release(
                    state, "connect_failure", time.monotonic() - started
                )
                released = True
                continue
            except httpx.TimeoutException:
                await self.scheduler.release(
                    state, "upstream_failure", time.monotonic() - started
                )
                released = True
                if response_started:
                    await send(
                        {
                            "type": "http.response.body",
                            "body": b"",
                            "more_body": False,
                        }
                    )
                else:
                    await self._error(send, 504, "upstream request timed out")
                return
            except httpx.TransportError:
                last_status = 502
                last_body = (
                    b'{"error":{"message":"failed to read upstream response"}}'
                )
                await self.scheduler.release(
                    state, "upstream_failure", time.monotonic() - started
                )
                released = True
                if response_started:
                    await send(
                        {
                            "type": "http.response.body",
                            "body": b"",
                            "more_body": False,
                        }
                    )
                    return
                continue
            finally:
                if response is not None and not response.is_closed:
                    await response.aclose()
                if not released:
                    await self.scheduler.release(
                        state, "upstream_failure", time.monotonic() - started
                    )

        await send(
            {
                "type": "http.response.start",
                "status": last_status,
                "headers": last_headers,
            }
        )
        await send(
            {
                "type": "http.response.body",
                "body": last_body,
                "more_body": False,
            }
        )

    @staticmethod
    def _response_headers(response: httpx.Response) -> list[tuple[bytes, bytes]]:
        headers = [
            (key.encode("latin-1"), value.encode("latin-1"))
            for key, value in response.headers.items()
            if key.lower() in FORWARDED_RESPONSE_HEADERS
        ]
        if not any(key.lower() == b"content-type" for key, _value in headers):
            headers.append((b"content-type", b"application/json"))
        return headers

    @staticmethod
    async def _json_response(
        send: Callable[[dict[str, Any]], Awaitable[None]],
        status: int,
        payload: dict[str, Any],
        headers: list[tuple[bytes, bytes]] | None = None,
    ) -> None:
        body = json.dumps(payload, separators=(",", ":")).encode("utf-8")
        response_headers = [(b"content-type", b"application/json")]
        if headers:
            response_headers.extend(headers)
        await send(
            {
                "type": "http.response.start",
                "status": status,
                "headers": response_headers,
            }
        )
        await send(
            {
                "type": "http.response.body",
                "body": body,
                "more_body": False,
            }
        )

    @classmethod
    async def _error(
        cls,
        send: Callable[[dict[str, Any]], Awaitable[None]],
        status: int,
        message: str,
        headers: list[tuple[bytes, bytes]] | None = None,
    ) -> None:
        await cls._json_response(
            send,
            status,
            {"error": {"message": message, "type": "gateway_error"}},
            headers=headers,
        )


def create_application(config_path: Path) -> GatewayApplication:
    settings, profiles = load_gateway_config(config_path)
    return GatewayApplication(settings, profiles)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Run the VoltronBench capacity-aware API gateway."
    )
    parser.add_argument(
        "--config",
        type=Path,
        default=Path(
            os.environ.get(
                "VOLTRON_GATEWAY_CONFIG",
                "config/voltron-llm.yaml",
            )
        ),
    )
    parser.add_argument("--host")
    parser.add_argument("--port", type=int)
    args = parser.parse_args()

    try:
        settings, profiles = load_gateway_config(args.config)
    except ConfigError as error:
        print(f"API gateway configuration error: {error}", file=sys.stderr)
        return 2

    try:
        import uvicorn
    except ImportError:
        print(
            "uvicorn is required (install requirements-gateway.txt)",
            file=sys.stderr,
        )
        return 1

    application = GatewayApplication(settings, profiles)
    uvicorn.run(
        application,
        host=args.host or settings.host,
        port=args.port or settings.port,
        workers=1,
        access_log=False,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
