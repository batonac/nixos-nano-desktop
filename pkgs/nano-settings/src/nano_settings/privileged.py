"""Getting root, and watching what root does.

This desktop runs no polkit authentication agent. polkitd is there, and
pkexec works from a terminal because it falls back to a text agent on the
tty — but an application started from the menu has no tty, and its pkexec
would fail with nothing to show for it.

Rather than make the desktop carry a resident agent for the sake of one
application, the application brings its own: polkit-gnome is spawned as a
child at startup and dies with the window. If some other agent already owns
the session, polkit refuses the second registration and ours exits by itself,
which is why this never checks first — the failure mode is already the
behaviour we want.
"""

import ctypes
import os
import signal
import subprocess

from gi.repository import Gio, GLib

from . import paths

_PR_SET_PDEATHSIG = 1


def _die_with_parent():
    """Ask the kernel to kill this child when its parent goes away.

    Calling stop() from the application's shutdown handler is not enough on
    its own: that handler does not run when the process is killed, and an
    agent that outlives the window is precisely the resident daemon this
    design exists to avoid. Measured, not assumed — before this, SIGTERM to
    the app reliably left the agent reparented to init and still running.
    """
    try:
        ctypes.CDLL("libc.so.6", use_errno=True).prctl(_PR_SET_PDEATHSIG, signal.SIGTERM)
    except (OSError, AttributeError):
        pass


class PolkitAgent:
    def __init__(self):
        self._process = None

    def start(self):
        command = paths.POLKIT_AGENT
        if not command or command.startswith("@"):
            return
        try:
            self._process = subprocess.Popen(
                [command],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                preexec_fn=_die_with_parent,
            )
        except OSError:
            # No agent means the password dialog never appears and every
            # privileged action reports "not authorized". Worth surviving
            # rather than crashing over: the rest of the app still reads.
            self._process = None

    def stop(self):
        """The tidy path, for a window closed rather than a process killed."""
        if self._process is None:
            return
        self._process.terminate()
        try:
            self._process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            self._process.kill()
        self._process = None


class Runner:
    """Runs one privileged helper subcommand, streaming its output.

    Everything arrives on stdout because the helper merges its streams, so
    the log reads in the order things actually happened. Nothing here can
    cancel a run in progress: the child is root and we are not, so the
    honest interface is to disable the buttons until it finishes.
    """

    def __init__(self, on_line, on_done):
        self._on_line = on_line
        self._on_done = on_done
        self._process = None
        self._at_eof = False
        self._exited = False
        self._succeeded = False
        self._status = 0

    @property
    def busy(self):
        return self._process is not None and not (self._at_eof and self._exited)

    def run(self, subcommand, stdin_text=None):
        if not os.path.exists(paths.HELPER):
            self._on_line(f"{paths.HELPER} is missing.")
            self._on_done(False, "The settings helper is not installed on this system.")
            return

        argv = ["pkexec", paths.HELPER, subcommand]
        flags = Gio.SubprocessFlags.STDOUT_PIPE | Gio.SubprocessFlags.STDERR_MERGE
        if stdin_text is not None:
            flags |= Gio.SubprocessFlags.STDIN_PIPE

        try:
            self._process = Gio.Subprocess.new(argv, flags)
        except GLib.Error as error:
            self._on_done(False, f"Could not start the helper: {error.message}")
            return

        if stdin_text is not None:
            self._write_stdin(stdin_text.encode("utf-8"))

        self._stdout = Gio.DataInputStream.new(self._process.get_stdout_pipe())
        self._read_next()
        self._process.wait_async(None, self._on_wait)

    # ── stdin ────────────────────────────────────────────────────────

    def _write_stdin(self, payload):
        stream = self._process.get_stdin_pipe()

        def write_from(offset):
            stream.write_bytes_async(
                GLib.Bytes.new(payload[offset:]),
                GLib.PRIORITY_DEFAULT,
                None,
                on_written,
                offset,
            )

        def on_written(source, result, offset):
            try:
                written = source.write_bytes_finish(result)
            except GLib.Error:
                source.close_async(GLib.PRIORITY_DEFAULT, None, lambda *_: None)
                return
            offset += written
            if offset < len(payload):
                write_from(offset)
            else:
                # The helper reads to EOF, so this close is what tells it the
                # settings have all arrived.
                source.close_async(GLib.PRIORITY_DEFAULT, None, lambda *_: None)

        write_from(0)

    # ── stdout ───────────────────────────────────────────────────────

    def _read_next(self):
        self._stdout.read_line_async(GLib.PRIORITY_DEFAULT, None, self._on_line_read)

    def _on_line_read(self, source, result):
        try:
            line, _ = source.read_line_finish_utf8(result)
        except GLib.Error:
            line = None
        if line is None:
            self._at_eof = True
            self._finish()
            return
        self._on_line(line)
        self._read_next()

    def _on_wait(self, process, result):
        try:
            process.wait_finish(result)
            self._succeeded = process.get_successful()
            self._status = process.get_exit_status() if process.get_if_exited() else -1
        except GLib.Error:
            self._succeeded = False
            self._status = -1
        self._exited = True
        self._finish()

    def _finish(self):
        if not (self._at_eof and self._exited):
            return
        self._on_done(self._succeeded, self._explain())

    def _explain(self):
        if self._succeeded:
            return ""
        # pkexec's own exit codes, which mean the helper never ran at all.
        # Worth separating from a failed rebuild: nothing was attempted, so
        # there is nothing to undo and nothing in the log to read.
        if self._status == 126:
            return "Cancelled — the password prompt was dismissed."
        if self._status == 127:
            return "Not authorised. The password was wrong, or this account may not administer the system."
        return "The helper reported a failure. The log above has the detail."
