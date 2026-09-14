"""The one network question, answered without a network."""

from __future__ import annotations

import urllib.error
from typing import Any

import pytest

from nano_settings import network


class _Response:
    def __init__(self, status: int) -> None:
        self.status = status

    def __enter__(self) -> _Response:
        return self

    def __exit__(self, *_exc: object) -> None:
        return None


def test_a_reachable_cache_means_online(monkeypatch: pytest.MonkeyPatch) -> None:
    seen: list[Any] = []

    def urlopen(request: Any, timeout: float) -> _Response:
        seen.append((request.full_url, request.get_method(), timeout))
        return _Response(200)

    monkeypatch.setattr(network, "urlopen", urlopen)
    assert network.is_online(timeout=1.5)
    # HEAD, at the cache the rebuild would talk to, with the timeout given.
    assert seen == [(network.CACHE_URL, "HEAD", 1.5)]


def test_a_server_error_is_not_online(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(network, "urlopen", lambda r, timeout: _Response(503))
    assert not network.is_online()


@pytest.mark.parametrize(
    "error",
    [urllib.error.URLError("no route to host"), TimeoutError(), OSError("network down")],
)
def test_any_failure_to_ask_is_offline(monkeypatch: pytest.MonkeyPatch, error: Exception) -> None:
    def urlopen(request: Any, timeout: float) -> _Response:
        raise error

    monkeypatch.setattr(network, "urlopen", urlopen)
    assert not network.is_online()
