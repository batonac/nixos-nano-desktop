"""Getting root, and watching what root does.

Nothing here runs pkexec. It runs a script called pkexec that execs its
arguments, which is the same shape — a child, a pipe, an exit status — with
the authorisation taken out. What is being tested is this side of it: that
every line arrives in order, that the two exit codes pkexec reserves for
itself are told apart from a helper that ran and failed, and that a helper
which never reads what it is sent does not leave the application waiting.
"""

from __future__ import annotations

import contextlib
import fcntl
import os
import signal
import subprocess
import sys
import time
from collections.abc import Callable
from pathlib import Path
from typing import cast

import gi
import pytest

# The unix-specific stream types moved to a namespace of their own; the one
# here is what a pipe with a size limit can be handed to Gio as. Ignored
# rather than typed because pygobject-stubs does not cover GioUnix yet — if
# a later version does, mypy will say so and this can come out.
gi.require_version("GioUnix", "2.0")

from gi.repository import Gio, GioUnix, GLib  # type: ignore[attr-defined]  # noqa: E402

from conftest import Pump, ScriptWriter  # noqa: E402
from nano_settings import paths  # noqa: E402
from nano_settings.privileged import PolkitAgent, Runner, _die_with_parent  # noqa: E402

# ── the agent ────────────────────────────────────────────────────────


def test_an_unpatched_placeholder_means_no_agent() -> None:
    # A source checkout, where the derivation has not substituted a store
    # path in. Starting "@polkitAgent@" would only raise.
    agent = PolkitAgent()
    agent.start()
    assert agent._process is None


def test_an_empty_agent_path_means_no_agent(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(paths, "POLKIT_AGENT", "")
    agent = PolkitAgent()
    agent.start()
    assert agent._process is None


def test_the_agent_runs_as_a_child_and_stops_with_the_window(
    monkeypatch: pytest.MonkeyPatch, shell_script: ScriptWriter
) -> None:
    monkeypatch.setattr(paths, "POLKIT_AGENT", str(shell_script("agent", "sleep 60")))
    agent = PolkitAgent()
    agent.start()

    assert agent._process is not None
    assert agent._process.poll() is None

    agent.stop()
    assert agent._process is None


def test_an_agent_that_will_not_go_is_killed(
    monkeypatch: pytest.MonkeyPatch, python_script: ScriptWriter, tmp_path: Path
) -> None:
    ready = tmp_path / "ignoring-sigterm"
    stubborn = python_script(
        "agent",
        "import pathlib, signal, time\n"
        "signal.signal(signal.SIGTERM, signal.SIG_IGN)\n"
        f"pathlib.Path({str(ready)!r}).touch()\n"
        "time.sleep(60)",
    )
    monkeypatch.setattr(paths, "POLKIT_AGENT", str(stubborn))
    agent = PolkitAgent()
    agent.start()
    assert agent._process is not None
    process = agent._process

    # Not before it is actually ignoring the signal, or this measures how
    # long an interpreter takes to start.
    deadline = time.monotonic() + 10.0
    while not ready.exists() and time.monotonic() < deadline:
        time.sleep(0.02)

    agent.stop()

    # Asked first, and only then killed — an agent given no chance to
    # deregister leaves polkit holding a session it cannot use.
    assert process.wait(timeout=10) == -signal.SIGKILL


def test_an_agent_that_will_not_start_is_survived(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    # The rest of the app still reads; only the password prompt is lost.
    monkeypatch.setattr(paths, "POLKIT_AGENT", str(tmp_path / "not-here"))
    agent = PolkitAgent()
    agent.start()
    assert agent._process is None


def test_stopping_an_agent_that_was_never_started_does_nothing() -> None:
    PolkitAgent().stop()


def test_the_child_asks_to_be_killed_with_its_parent() -> None:
    # Runs in the forked child in production, where coverage cannot see it
    # and a failure would be silent. prctl on this process is harmless: the
    # signal only arrives if the test runner's own parent goes away.
    _die_with_parent()


def test_a_libc_without_prctl_is_not_worth_crashing_over(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    def refuse(*_args: object, **_kwargs: object) -> object:
        raise OSError("no libc here")

    monkeypatch.setattr("ctypes.CDLL", refuse)
    _die_with_parent()


# ── the runner ───────────────────────────────────────────────────────


class Recorder:
    """Everything a Runner tells its caller."""

    def __init__(self) -> None:
        self.lines: list[str] = []
        self.done: list[tuple[bool, str]] = []

    @property
    def finished(self) -> bool:
        return bool(self.done)

    @property
    def ok(self) -> bool:
        return self.done[0][0]

    @property
    def message(self) -> str:
        return self.done[0][1]


@pytest.fixture
def helper(monkeypatch: pytest.MonkeyPatch, shell_script: ScriptWriter) -> Callable[[str], Path]:
    """Install a script where the privileged helper would be."""

    def install(body: str) -> Path:
        path = shell_script("nano-settings-helper", body)
        monkeypatch.setattr(paths, "HELPER", path)
        return path

    return install


def test_a_system_without_the_helper_says_so(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    monkeypatch.setattr(paths, "HELPER", tmp_path / "absent")
    record = Recorder()

    Runner(record.lines.append, lambda ok, message: record.done.append((ok, message))).run("apply")

    assert record.done == [(False, "The settings helper is not installed on this system.")]
    assert "is missing" in record.lines[0]


def test_every_line_arrives_in_the_order_it_was_written(
    helper: Callable[[str], Path], passthrough_pkexec: Path, pump: Pump
) -> None:
    helper('echo "one"\necho "two" >&2\necho "three"')
    record = Recorder()
    runner = Runner(record.lines.append, lambda ok, message: record.done.append((ok, message)))

    assert not runner.busy
    runner.run("rebuild")
    pump(lambda: record.finished)

    # stderr is merged into stdout by the helper, and this is what proves it
    # keeps its place rather than arriving in a second stream.
    assert record.lines == ["one", "two", "three"]
    assert record.done == [(True, "")]
    assert not runner.busy


def test_the_subcommand_reaches_the_helper(
    helper: Callable[[str], Path], passthrough_pkexec: Path, pump: Pump
) -> None:
    helper('echo "ran $1"')
    record = Recorder()

    Runner(record.lines.append, lambda ok, m: record.done.append((ok, m))).run("upgrade")
    pump(lambda: record.finished)

    assert record.lines == ["ran upgrade"]


def test_settings_are_handed_over_on_stdin(
    helper: Callable[[str], Path], passthrough_pkexec: Path, pump: Pump
) -> None:
    helper("cat")
    record = Recorder()

    Runner(record.lines.append, lambda ok, m: record.done.append((ok, m))).run(
        "apply", stdin_text='{\n  "hostName": "kitchen"\n}\n'
    )
    pump(lambda: record.finished)

    assert record.lines == ["{", '  "hostName": "kitchen"', "}"]
    assert record.ok


def test_a_payload_larger_than_a_pipe_buffer_is_written_in_full(
    helper: Callable[[str], Path], passthrough_pkexec: Path, pump: Pump
) -> None:
    # A settings file with a long package list is already past 64 KB, which
    # is what a pipe will hold before anyone reads from it.
    helper("wc -c")
    payload = "x" * (2 * 1024 * 1024)
    record = Recorder()

    Runner(record.lines.append, lambda ok, m: record.done.append((ok, m))).run(
        "apply", stdin_text=payload
    )
    pump(lambda: record.finished)

    assert record.lines[0].strip() == str(len(payload))


def test_a_write_the_pipe_would_not_take_in_one_go_is_finished_off(pump: Pump) -> None:
    """One write_bytes_async does not have to take the lot.

    How much it takes depends on the pipe, the reader and the kernel, so the
    test that goes through a helper cannot be made to guarantee a short write
    — and a settings file that arrived truncated would be a machine that
    cannot evaluate. Here the pipe is deliberately made too small to hold the
    payload, and nothing reads it until the second write is already waiting.
    """
    record = Recorder()
    runner = Runner(record.lines.append, lambda ok, m: record.done.append((ok, m)))

    read_fd, write_fd = os.pipe()
    fcntl.fcntl(write_fd, fcntl.F_SETPIPE_SZ, 4096)
    os.set_blocking(read_fd, False)
    # Both ends non-blocking, or the second write happens inside the main
    # loop iteration that was supposed to drain the pipe, and the two wait
    # for each other for as long as the test is given.
    os.set_blocking(write_fd, False)
    payload = b"x" * (16 * 1024)
    received = bytearray()

    runner._write_stdin(GioUnix.OutputStream.new(write_fd, True), payload)

    def drained() -> bool:
        # Nothing to read yet is the normal case here: the write is waiting
        # for room, and this loop is what makes room.
        with contextlib.suppress(BlockingIOError):
            received.extend(os.read(read_fd, 65536))
        return len(received) >= len(payload)

    pump(drained)
    os.close(read_fd)

    assert bytes(received) == payload


def test_a_helper_that_never_reads_its_stdin_still_finishes(
    helper: Callable[[str], Path], passthrough_pkexec: Path, pump: Pump
) -> None:
    """The write fails with EPIPE, and that is not the user's problem.

    Nothing can be done about it from here — the helper has already decided
    not to listen — so the write is abandoned and the run is reported on its
    exit status, which is the only thing that says whether anything happened.
    """
    helper("exit 0")
    record = Recorder()

    Runner(record.lines.append, lambda ok, m: record.done.append((ok, m))).run(
        "apply", stdin_text="y" * (2 * 1024 * 1024)
    )
    pump(lambda: record.finished)

    assert record.done == [(True, "")]


@pytest.mark.parametrize(
    ("status", "message"),
    [
        (1, "The helper reported a failure. The log above has the detail."),
        (126, "Cancelled — the password prompt was dismissed."),
        (
            127,
            "Not authorised. The password was wrong, or this account "
            "may not administer the system.",
        ),
    ],
)
def test_the_exit_status_decides_what_the_user_is_told(
    helper: Callable[[str], Path],
    passthrough_pkexec: Path,
    pump: Pump,
    status: int,
    message: str,
) -> None:
    helper(f'echo "trying"\nexit {status}')
    record = Recorder()

    Runner(record.lines.append, lambda ok, m: record.done.append((ok, m))).run("rebuild")
    pump(lambda: record.finished)

    assert record.done == [(False, message)]


def test_a_helper_killed_by_a_signal_is_a_failure_not_a_status(
    helper: Callable[[str], Path], passthrough_pkexec: Path, pump: Pump
) -> None:
    helper("kill -9 $$")
    record = Recorder()

    Runner(record.lines.append, lambda ok, m: record.done.append((ok, m))).run("rebuild")
    pump(lambda: record.finished)

    assert not record.ok
    assert "log above" in record.message


def test_output_that_is_not_text_ends_the_log_rather_than_the_application(
    helper: Callable[[str], Path], passthrough_pkexec: Path, pump: Pump
) -> None:
    helper("echo readable\nprintf '\\377\\376\\n'\necho unreachable")
    record = Recorder()

    Runner(record.lines.append, lambda ok, m: record.done.append((ok, m))).run("rebuild")
    pump(lambda: record.finished)

    assert record.lines == ["readable"]
    assert record.ok


def test_a_pkexec_that_cannot_be_started_is_reported(
    helper: Callable[[str], Path], monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    helper("true")
    monkeypatch.setattr(paths, "PKEXEC", str(tmp_path / "no-pkexec"))
    record = Recorder()

    Runner(record.lines.append, lambda ok, m: record.done.append((ok, m))).run("rebuild")

    assert not record.ok
    assert record.message.startswith("Could not start the helper:")


def test_the_runner_is_busy_until_both_the_output_and_the_process_end(
    helper: Callable[[str], Path], passthrough_pkexec: Path, pump: Pump
) -> None:
    helper("echo working\nsleep 0.4\necho done")
    record = Recorder()
    runner = Runner(record.lines.append, lambda ok, m: record.done.append((ok, m)))

    runner.run("rebuild")
    pump(lambda: bool(record.lines))
    assert runner.busy

    pump(lambda: record.finished)
    assert not runner.busy


class _WaitThatFails:
    """A Gio.Subprocess whose wait could not be finished.

    Only reachable through cancellation, which this application never asks
    for — it has no way to stop a root process it did not start. The branch
    exists so that a failure to reap does not report a success, and this is
    the only way to stand in front of it.
    """

    def wait_finish(self, _result: Gio.AsyncResult) -> bool:
        raise GLib.Error("the wait was cancelled")


def test_a_wait_that_cannot_be_finished_is_a_failure(pump: Pump) -> None:
    record = Recorder()
    runner = Runner(record.lines.append, lambda ok, m: record.done.append((ok, m)))
    runner._at_eof = True

    runner._on_wait(cast(Gio.Subprocess, _WaitThatFails()), cast(Gio.AsyncResult, None))

    assert record.done == [(False, "The helper reported a failure. The log above has the detail.")]


def test_a_write_to_a_stream_that_will_not_take_it_is_abandoned(pump: Pump) -> None:
    """The other half of the EPIPE case, without the timing.

    A stream that is already closed fails the write immediately, which is
    the branch a helper that exits early reaches by racing.
    """
    record = Recorder()
    runner = Runner(record.lines.append, lambda ok, m: record.done.append((ok, m)))
    stream = Gio.MemoryOutputStream.new_resizable()
    stream.close()

    runner._write_stdin(stream, b"never arrives")
    pump(lambda: stream.is_closed(), timeout=5.0)

    assert stream.steal_as_bytes().get_size() == 0


def test_the_helper_is_run_through_pkexec(
    helper: Callable[[str], Path], passthrough_pkexec: Path, pump: Pump, tmp_path: Path
) -> None:
    # The application never runs the helper directly: it is not root, and the
    # helper refuses to be anything else.
    marker = tmp_path / "argv"
    recording = tmp_path / "pkexec"
    recording.write_text(f'#!/bin/sh\nprintf "%s\\n" "$@" > {marker}\nexec "$@"\n')
    recording.chmod(0o755)
    installed = helper("true")
    record = Recorder()

    Runner(record.lines.append, lambda ok, m: record.done.append((ok, m))).run("rollback")
    pump(lambda: record.finished)

    assert marker.read_text().splitlines() == [str(installed), "rollback"]


CHILD = """
import sys, time
sys.path.insert(0, sys.argv[1])
from nano_settings import paths, privileged

paths.POLKIT_AGENT = sys.argv[2]
agent = privileged.PolkitAgent()
agent.start()
print(agent._process.pid, flush=True)
time.sleep(60)
"""


def test_the_polkit_agent_is_not_left_behind_by_a_killed_application(
    shell_script: ScriptWriter,
) -> None:
    """PR_SET_PDEATHSIG, measured rather than assumed.

    stop() covers the tidy path, but an application that is killed never
    reaches it, and an agent that outlives the window is exactly the resident
    daemon this design exists to avoid. So an agent is started by a parent
    that is then killed without a chance to clean up, and it has to go too.
    """
    package = Path(paths.__file__).resolve().parent.parent
    parent = subprocess.Popen(
        [sys.executable, "-c", CHILD, str(package), str(shell_script("agent", "sleep 60"))],
        stdout=subprocess.PIPE,
    )
    assert parent.stdout is not None
    agent_pid = int(parent.stdout.readline())

    parent.kill()
    parent.wait(timeout=10)

    deadline = time.monotonic() + 10.0
    while time.monotonic() < deadline:
        try:
            os.kill(agent_pid, 0)
        except ProcessLookupError:
            return
        time.sleep(0.02)
    raise AssertionError(f"the agent ({agent_pid}) outlived the application that started it")
