"""Changing the account password.

This is the one privileged-looking thing here that needs no privilege at
all: passwd, run as the user, changing the user's own password. That is
worth preferring over a root helper writing through chpasswd, because it
means the current password is actually verified and PAM's own rules apply —
the same path a terminal would take.

users.mutableUsers is left at its default, so the change persists; the
initialPassword in the settings file only ever applied when the account was
first created.

passwd insists on a terminal for its prompts, so it gets one: a pty, driven
by answering each prompt in order. The work happens on a thread because the
child blocks, and the result comes back through GLib.idle_add.
"""

from __future__ import annotations

import os
import pty
import select
import subprocess
import threading
from typing import Final

from gi.repository import Adw, GLib, Gtk

from . import paths
from .settings import Settings

# Generous: PAM can be slow, and the failure delay after a wrong password is
# measured in seconds by design.
_PROMPT_TIMEOUT: Final = 30.0


def _drive_passwd(current: str, new: str) -> tuple[bool, str]:
    """Run passwd on a pty, answering its three prompts. Returns (ok, text)."""
    master, slave = pty.openpty()
    try:
        process = subprocess.Popen(
            [paths.PASSWD],
            stdin=slave,
            stdout=slave,
            stderr=slave,
            close_fds=True,
            start_new_session=True,
        )
    except OSError as error:
        os.close(master)
        os.close(slave)
        return False, f"Could not run passwd: {error}"

    os.close(slave)
    answers = [current, new, new]
    transcript = b""
    pending = b""

    try:
        while True:
            ready, _, _ = select.select([master], [], [], _PROMPT_TIMEOUT)
            if not ready:
                process.kill()
                return False, "passwd stopped responding."
            try:
                chunk = os.read(master, 4096)
            except OSError:
                break  # the child closed the pty: it is done talking
            if not chunk:
                break
            transcript += chunk
            pending += chunk
            # Prompts are the lines that end in a colon. Matching on that
            # rather than on their wording keeps this working across PAM
            # configurations, which word them differently.
            if pending.rstrip().endswith(b":"):
                if not answers:
                    # A fourth prompt means passwd rejected the new password
                    # and is asking again — PAM's quality rules, usually.
                    # Stop rather than wait out the timeout; the transcript
                    # already says why.
                    process.kill()
                    break
                os.write(master, answers.pop(0).encode("utf-8") + b"\n")
                # End the prompt's line ourselves. passwd does not: a prompt
                # carries no newline, and with echo off the answer does not
                # come back to supply one — so the whole conversation runs
                # together into a single line, and whatever PAM says at the
                # end of it arrives with three prompts stuck to the front.
                # This is the only point at which what is a prompt is known
                # rather than guessed: it is what was just answered.
                transcript += b"\n"
                pending = b""
    finally:
        os.close(master)

    status = process.wait()
    text = transcript.decode("utf-8", "replace")
    return status == 0, text


class AccountPage:
    def __init__(self, settings: Settings) -> None:
        self.settings = settings
        self.view = Adw.PreferencesPage()
        self.view.set_title("Account")
        self.view.set_icon_name("avatar-default-symbolic")

        group = Adw.PreferencesGroup()
        group.set_title("Password")
        group.set_description(
            f"Changes the password for {os.environ.get('USER', 'this account')}, "
            "the account you are signed in as."
        )

        self.current = Adw.PasswordEntryRow()
        self.current.set_title("Current password")
        self.new = Adw.PasswordEntryRow()
        self.new.set_title("New password")
        self.confirm = Adw.PasswordEntryRow()
        self.confirm.set_title("Confirm new password")
        for row in (self.current, self.new, self.confirm):
            row.connect("changed", lambda _row: self._revalidate())
            group.add(row)

        self.button = Gtk.Button.new_with_label("Change password")
        self.button.add_css_class("suggested-action")
        self.button.add_css_class("pill")
        self.button.set_halign(Gtk.Align.CENTER)
        self.button.set_margin_top(12)
        self.button.set_sensitive(False)
        self.button.connect("clicked", self._on_change)
        group.add(self.button)

        self.status = Gtk.Label()
        self.status.set_wrap(True)
        self.status.set_xalign(0.5)
        self.status.set_margin_top(8)
        self.status.add_css_class("dim-label")
        self.status.set_visible(False)
        group.add(self.status)
        self.view.add(group)

        self._build_note()

    def _build_note(self) -> None:
        group = Adw.PreferencesGroup()
        group.set_title("About the installed password")
        row = Adw.ActionRow()
        row.set_title("Set at installation")
        row.set_subtitle(
            "The settings file records the password this account was created with. "
            "It has no effect once the account exists — changing it there does "
            "nothing, and the box above is what changes the real password."
        )
        row.set_subtitle_lines(0)
        group.add(row)
        self.view.add(group)

    # ── validation ───────────────────────────────────────────────────

    def _revalidate(self) -> None:
        current = self.current.get_text()
        new = self.new.get_text()
        confirm = self.confirm.get_text()
        ok = bool(current and new and new == confirm)
        self.button.set_sensitive(ok)
        if new and confirm and new != confirm:
            self._say("The new passwords do not match.")
        else:
            self.status.set_visible(False)

    def _say(self, text: str) -> None:
        self.status.set_text(text)
        self.status.set_visible(True)

    # ── running ──────────────────────────────────────────────────────

    def _on_change(self, _button: Gtk.Button) -> None:
        current = self.current.get_text()
        new = self.new.get_text()
        self.button.set_sensitive(False)
        self._say("Changing password…")

        def work() -> None:
            ok, text = _drive_passwd(current, new)
            GLib.idle_add(self._done, ok, text)

        threading.Thread(target=work, daemon=True).start()

    def _done(self, ok: bool, text: str) -> bool:
        if ok:
            for row in (self.current, self.new, self.confirm):
                row.set_text("")
            self._say("Password changed.")
        else:
            self._say(_explain(text))
        self.button.set_sensitive(False)
        return GLib.SOURCE_REMOVE


def _explain(transcript: str) -> str:
    """Turn passwd's output into one line worth reading."""
    lowered = transcript.lower()
    # "Permission denied" is what shadow's passwd says here for a wrong
    # current password; the others are what other PAM stacks say.
    if any(
        phrase in lowered
        for phrase in ("permission denied", "authentication", "incorrect")
    ):
        return "The current password is not correct."
    for line in reversed(transcript.splitlines()):
        line = line.strip()
        # Skip the prompts themselves, which are echoed back on the pty.
        if line and not line.endswith(":"):
            return line
    return "The password was not changed."
