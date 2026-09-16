"""One question, asked once, right before it matters: can this machine reach
a binary cache?

The app has no other interest in the network. It exists for the Apply gate
in window.py: a change to an option whose other values are not on the
install media (datatypes.SchemaEntry.installMedia) is a download, and on a
machine with no route out that download is a rebuild that fails twenty
minutes in, after the password prompt. Better to say so before either.

The question is put to nix itself — `nix store info` against
cache.nixos.org — because that is what the rebuild is about to do: the same
fetcher, the same TLS and CA bundle, the same nix-cache-info file at the same
address. A generic reachability check answers a different question. A captive
portal answering 200 for everything is the false positive, and the rebuild's
own failure remains the backstop for that.

Asynchronous, through the main loop: this runs between a click and a dialog,
and the seconds it may take are not seconds the window should spend frozen.
One attempt, a connect timeout, and a backstop that kills the child if nix
has found some other way to wait.
"""

from __future__ import annotations

from collections.abc import Callable
from typing import Final

from gi.repository import Gio, GLib

from . import paths

CACHE_URL: Final = "https://cache.nixos.org"
TIMEOUT: Final = 3

type OnAnswer = Callable[[bool], None]


def check_online(callback: OnAnswer, timeout: int = TIMEOUT) -> None:
    """Ask, and hand the answer to callback from the main loop.

    False for every way of not getting a yes: nix could not be started, it
    said no, the backstop killed it, or asking how it ended failed.
    """
    argv = [
        paths.NIX,
        "store",
        "info",
        "--store",
        CACHE_URL,
        # nix's own retry and connect budget, in place of one written here.
        # Left alone it tries five times with backoff, which is right for a
        # rebuild and wrong for a question asked with a finger on the button.
        "--option",
        "download-attempts",
        "1",
        "--option",
        "connect-timeout",
        str(timeout),
    ]
    try:
        process = Gio.Subprocess.new(
            argv, Gio.SubprocessFlags.STDOUT_SILENCE | Gio.SubprocessFlags.STDERR_SILENCE
        )
    except GLib.Error:
        callback(False)
        return

    # connect-timeout bounds the connect, not a transfer that stalls after
    # it — so a second, looser bound on the whole conversation, after which
    # the answer is simply no. Remembered, so that on_wait does not remove a
    # source that has already removed itself.
    fired = False

    def give_up() -> bool:
        nonlocal fired
        fired = True
        process.force_exit()
        return GLib.SOURCE_REMOVE

    backstop = GLib.timeout_add((timeout + 1) * 1000, give_up)

    def on_wait(source: Gio.Subprocess, result: Gio.AsyncResult) -> None:
        if not fired:
            GLib.source_remove(backstop)
        try:
            source.wait_finish(result)
            online = source.get_successful()
        except GLib.Error:
            online = False
        callback(online)

    process.wait_async(None, on_wait)
