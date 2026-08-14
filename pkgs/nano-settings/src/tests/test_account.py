"""Changing the password: a pty, three prompts, and one line of explanation.

passwd is stood in for by a script that talks the way passwd talks — prompts
that end in a colon, echo turned off, and an exit status that says whether it
believed you. That is the whole of the contract this code has with it, and
each of the ways the conversation can go wrong gets one here.
"""

from __future__ import annotations

import os
from collections.abc import Callable
from pathlib import Path

import pytest
from gi.repository import Gtk

from conftest import Pump, ScriptWriter
from nano_settings import account, paths
from nano_settings.account import AccountPage, _drive_passwd, _explain
from nano_settings.settings import Settings

# What every stand-in starts with: no echo, exactly as passwd sets it, so the
# answers do not come back down the pty and into the transcript.
PREAMBLE = """
import sys, termios

attributes = termios.tcgetattr(0)
attributes[3] &= ~termios.ECHO
termios.tcsetattr(0, termios.TCSANOW, attributes)


def ask(prompt):
    sys.stdout.write(prompt)
    sys.stdout.flush()
    return sys.stdin.readline().rstrip("\\n")


def say(line):
    sys.stdout.write(line + "\\n")
    sys.stdout.flush()
"""


@pytest.fixture
def fake_passwd(
    monkeypatch: pytest.MonkeyPatch, python_script: ScriptWriter
) -> Callable[[str], Path]:
    def install(body: str) -> Path:
        path = python_script("passwd", PREAMBLE + body)
        monkeypatch.setattr(paths, "PASSWD", str(path))
        return path

    return install


# ── the conversation ─────────────────────────────────────────────────


def test_the_three_answers_go_to_the_three_prompts(
    fake_passwd: Callable[[str], Path], tmp_path: Path
) -> None:
    heard = tmp_path / "heard"
    fake_passwd(
        f"""
answers = [
    ask("Current password: "),
    ask("New password: "),
    ask("Retype new password: "),
]
open({str(heard)!r}, "w").write("\\n".join(answers))
say("passwd: password updated successfully")
"""
    )

    ok, transcript = _drive_passwd("old-one", "new-one")

    assert ok
    assert heard.read_text().splitlines() == ["old-one", "new-one", "new-one"]
    # One prompt per line, which passwd itself does not do: its prompts carry
    # no newline, and with echo off the answers do not supply one either.
    assert transcript.splitlines() == [
        "Current password: ",
        "New password: ",
        "Retype new password: ",
        "passwd: password updated successfully",
    ]


def test_a_refused_current_password_is_a_failure(
    fake_passwd: Callable[[str], Path],
) -> None:
    fake_passwd(
        """
ask("Current password: ")
say("passwd: Authentication token manipulation error")
sys.exit(1)
"""
    )

    ok, transcript = _drive_passwd("wrong", "new-one")

    assert not ok
    assert _explain(transcript) == "The current password is not correct."


def test_a_fourth_prompt_means_the_new_password_was_refused(
    fake_passwd: Callable[[str], Path],
) -> None:
    # PAM asking again, rather than giving up. Waiting out the timeout would
    # cost thirty seconds to learn what the transcript already says.
    fake_passwd(
        """
ask("Current password: ")
ask("New password: ")
ask("Retype new password: ")
say("BAD PASSWORD: it is too short")
ask("New password: ")
import time; time.sleep(60)
"""
    )

    ok, transcript = _drive_passwd("old-one", "no")

    assert not ok
    # What PAM said, and not the three prompts it was said after.
    assert _explain(transcript) == "BAD PASSWORD: it is too short"
    assert transcript.splitlines()[-1] == "New password: "


def test_a_passwd_that_stops_answering_is_given_up_on(
    fake_passwd: Callable[[str], Path], monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(account, "_PROMPT_TIMEOUT", 0.3)
    fake_passwd(
        """
say("thinking about it")
import time; time.sleep(60)
"""
    )

    ok, message = _drive_passwd("old-one", "new-one")

    assert not ok
    assert message == "passwd stopped responding."


def test_a_pty_that_closes_cleanly_ends_the_conversation(
    fake_passwd: Callable[[str], Path], monkeypatch: pytest.MonkeyPatch
) -> None:
    """The other way a child can stop talking.

    Linux reports the far end going away as an error on the next read, which
    is the path every other test here takes. A pty that simply reaches end of
    file is the same conversation, ended differently.
    """
    fake_passwd('say("goodbye")\nsys.exit(3)')
    real_read = os.read
    served: list[int] = []

    def read_once(fd: int, size: int) -> bytes:
        # Only the pty read is answered with an end of file. subprocess reads
        # its own error pipe through this same function while starting the
        # child, and it asks for a different size — which is the only thing
        # separating the two at this level.
        if size != 4096:
            return real_read(fd, size)
        if served:
            return b""
        served.append(fd)
        return real_read(fd, size)

    monkeypatch.setattr(os, "read", read_once)

    ok, transcript = _drive_passwd("old-one", "new-one")

    assert not ok
    assert "goodbye" in transcript


def test_a_system_without_passwd_says_so(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    monkeypatch.setattr(paths, "PASSWD", str(tmp_path / "no-passwd"))

    ok, message = _drive_passwd("old-one", "new-one")

    assert not ok
    assert message.startswith("Could not run passwd:")


# ── the explanation ──────────────────────────────────────────────────


@pytest.mark.parametrize(
    "transcript",
    [
        "passwd: Permission denied",
        "Authentication failure",
        "passwd: Incorrect password",
    ],
)
def test_every_wording_for_a_wrong_password_reads_the_same(transcript: str) -> None:
    # Which one appears depends on the PAM stack, and none of them is worth
    # showing as-is.
    assert _explain(transcript) == "The current password is not correct."


def test_the_last_thing_passwd_said_is_what_is_shown() -> None:
    assert _explain("Current password:\nBAD PASSWORD: too simple\n") == "BAD PASSWORD: too simple"


def test_a_transcript_of_nothing_but_prompts_explains_nothing() -> None:
    assert _explain("Current password:\nNew password:\n") == "The password was not changed."
    assert _explain("") == "The password was not changed."


# ── the page ─────────────────────────────────────────────────────────


@pytest.fixture
def page(settings: Settings) -> AccountPage:
    return AccountPage(settings)


def test_the_button_waits_for_all_three_boxes(page: AccountPage) -> None:
    assert not page.button.get_sensitive()

    page.current.set_text("old-one")
    assert not page.button.get_sensitive()
    page.new.set_text("new-one")
    assert not page.button.get_sensitive()
    page.confirm.set_text("new-one")
    assert page.button.get_sensitive()


def test_two_new_passwords_that_differ_say_so_before_anything_is_run(
    page: AccountPage,
) -> None:
    page.current.set_text("old-one")
    page.new.set_text("new-one")
    page.confirm.set_text("new-two")

    assert not page.button.get_sensitive()
    assert page.status.get_visible()
    assert page.status.get_text() == "The new passwords do not match."


def test_correcting_the_mismatch_puts_the_complaint_away(page: AccountPage) -> None:
    page.current.set_text("old-one")
    page.new.set_text("new-one")
    page.confirm.set_text("new-two")
    page.confirm.set_text("new-one")

    assert not page.status.get_visible()
    assert page.button.get_sensitive()


def test_changing_the_password_empties_the_boxes(
    page: AccountPage, fake_passwd: Callable[[str], Path], pump: Pump
) -> None:
    fake_passwd(
        """
ask("Current password: ")
ask("New password: ")
ask("Retype new password: ")
say("passwd: password updated successfully")
"""
    )
    page.current.set_text("old-one")
    page.new.set_text("new-one")
    page.confirm.set_text("new-one")

    page.button.emit("clicked")
    pump(lambda: page.status.get_text() == "Password changed.")

    assert page.current.get_text() == ""
    assert page.new.get_text() == ""
    assert page.confirm.get_text() == ""
    # Nothing left to submit, so nothing to press.
    assert not page.button.get_sensitive()


def test_a_refusal_is_explained_and_the_boxes_are_left_alone(
    page: AccountPage, fake_passwd: Callable[[str], Path], pump: Pump
) -> None:
    fake_passwd(
        """
ask("Current password: ")
say("passwd: Permission denied")
sys.exit(1)
"""
    )
    page.current.set_text("wrong")
    page.new.set_text("new-one")
    page.confirm.set_text("new-one")

    page.button.emit("clicked")
    pump(lambda: page.status.get_text() != "Changing password…")

    assert page.status.get_text() == "The current password is not correct."
    assert page.current.get_text() == "wrong"


def test_the_page_says_whose_password_it_changes(
    settings: Settings, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv("USER", "batonac")
    assert "batonac" in _descriptions(AccountPage(settings))

    monkeypatch.delenv("USER")
    assert "this account" in _descriptions(AccountPage(settings))


def _descriptions(page: AccountPage) -> str:
    from gi.repository import Adw

    found: list[str] = []
    stack: list[Gtk.Widget] = [page.view]
    while stack:
        widget = stack.pop()
        if isinstance(widget, Adw.PreferencesGroup):
            found.append(widget.get_description() or "")
        child = widget.get_first_child()
        while child is not None:
            stack.append(child)
            child = child.get_next_sibling()
    return "\n".join(found)
