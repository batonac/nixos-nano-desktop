"""The one network question, put to a nix that is a shell script."""

from __future__ import annotations

import time
from collections.abc import Callable
from pathlib import Path

import pytest
from gi.repository import Gio, GLib

from conftest import Pump, ScriptWriter
from nano_settings import network, paths


@pytest.fixture
def fake_nix(monkeypatch: pytest.MonkeyPatch, shell_script: ScriptWriter) -> Callable[[str], Path]:
    def install(body: str) -> Path:
        path = shell_script("nix", body)
        monkeypatch.setattr(paths, "NIX", str(path))
        return path

    return install


def _ask(pump: Pump, timeout: int = network.TIMEOUT) -> bool:
    answers: list[bool] = []
    network.check_online(answers.append, timeout=timeout)
    pump(lambda: bool(answers))
    return answers[0]


def test_a_reachable_cache_means_online(
    fake_nix: Callable[[str], Path], pump: Pump, tmp_path: Path
) -> None:
    recorded = tmp_path / "argv"
    fake_nix(f'printf "%s\\n" "$@" > {recorded}')

    assert _ask(pump)

    # nix's own question, to the cache the rebuild would talk to, with one
    # attempt and the connect timeout given.
    assert recorded.read_text().splitlines() == [
        "store",
        "info",
        "--store",
        "https://cache.nixos.org",
        "--option",
        "download-attempts",
        "1",
        "--option",
        "connect-timeout",
        "3",
    ]


def test_a_cache_nix_cannot_reach_is_not_online(
    fake_nix: Callable[[str], Path], pump: Pump
) -> None:
    fake_nix("exit 1")
    assert not _ask(pump)


def test_a_nix_that_does_not_answer_is_not_online(
    fake_nix: Callable[[str], Path], pump: Pump
) -> None:
    """The backstop: nix bounds its connect, not everything it might wait on."""
    # exec, so that what the backstop kills is the sleep and not a shell
    # around it, which would leave the sleep behind for the full minute.
    fake_nix("exec sleep 60")
    started = time.monotonic()

    assert not _ask(pump, timeout=1)

    # One second of nix's budget and one more of ours — not the minute.
    assert time.monotonic() - started < 10


def test_a_nix_that_cannot_be_started_is_not_online(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    monkeypatch.setattr(paths, "NIX", str(tmp_path / "no-such-nix"))
    answers: list[bool] = []

    network.check_online(answers.append)

    # Answered on the spot: there is nothing to wait for.
    assert answers == [False]


def test_a_wait_that_cannot_be_finished_is_not_online(
    fake_nix: Callable[[str], Path], pump: Pump, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Only reachable through cancellation, which nothing here asks for; the
    branch exists so that a failure to reap never reads as a yes."""

    def wait_finish(_process: Gio.Subprocess, _result: Gio.AsyncResult) -> bool:
        raise GLib.Error("the wait was cancelled")

    monkeypatch.setattr(Gio.Subprocess, "wait_finish", wait_finish)
    fake_nix("exit 0")

    assert not _ask(pump)
