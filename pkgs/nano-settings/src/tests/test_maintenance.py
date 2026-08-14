"""Updates and maintenance: the log, the switch, and the four subcommands."""

from __future__ import annotations

from collections.abc import Callable
from pathlib import Path

import pytest
from gi.repository import Adw, Gtk

from conftest import Pump, ScriptWriter
from nano_settings import paths
from nano_settings.maintenance import ACTIONS, AUTO_UPGRADE_KEY, LogView, MaintenancePage
from nano_settings.settings import Settings

# ── the log ──────────────────────────────────────────────────────────


def contents(log: LogView) -> list[str]:
    text = log.buffer.get_text(log.buffer.get_start_iter(), log.buffer.get_end_iter(), False)
    return text.splitlines()


def test_the_log_keeps_what_it_is_given_in_order() -> None:
    log = LogView()
    log.append("first")
    log.append("second")
    assert contents(log) == ["first", "second"]


def test_clearing_the_log_empties_it() -> None:
    log = LogView()
    log.append("first")
    log.clear()
    assert contents(log) == []


def test_the_log_is_not_editable() -> None:
    # It is a transcript of what root did, not a text box.
    log = LogView()
    assert not log.text.get_editable()
    assert log.text.get_monospace()


# ── the page ─────────────────────────────────────────────────────────


class Page:
    """A MaintenancePage and everything it reports to the window."""

    def __init__(self, settings: Settings) -> None:
        self.log = LogView()
        self.changes = 0
        self.busy: list[bool] = []
        self.page = MaintenancePage(settings, self.log, self._changed, self.busy.append)

    def _changed(self) -> None:
        self.changes += 1

    def button(self, label: str) -> Gtk.Button:
        return next(b for b in self.page.buttons if b.get_label() == label)

    @property
    def lines(self) -> list[str]:
        return contents(self.log)


@pytest.fixture
def page(settings: Settings) -> Page:
    return Page(settings)


@pytest.fixture
def helper(monkeypatch: pytest.MonkeyPatch, shell_script: ScriptWriter) -> Callable[[str], Path]:
    def install(body: str) -> Path:
        path = shell_script("nano-settings-helper", body)
        monkeypatch.setattr(paths, "HELPER", path)
        return path

    return install


def test_the_daily_update_switch_shows_what_is_configured(
    settings: Settings, page: Page
) -> None:
    assert page.page.auto_row.get_active()
    assert page.changes == 0

    settings.set(AUTO_UPGRADE_KEY, False)
    page.page.refresh()
    assert not page.page.auto_row.get_active()
    # Refreshing is not editing.
    assert page.changes == 0


def test_turning_the_daily_update_off_is_an_edit_like_any_other(
    settings: Settings, page: Page
) -> None:
    page.page.auto_row.set_active(False)

    assert settings.pending == {AUTO_UPGRADE_KEY: False}
    assert page.changes == 1


def test_the_three_actions_are_offered(page: Page) -> None:
    assert [button.get_label() for button in page.page.buttons] == [
        "Update",
        "Rebuild",
        "Roll back",
    ]
    assert [action.command for action in ACTIONS] == ["upgrade", "rebuild", "rollback"]


def test_rolling_back_is_the_one_marked_destructive(page: Page) -> None:
    assert "destructive-action" in page.button("Roll back").get_css_classes()
    assert "suggested-action" in page.button("Rebuild").get_css_classes()


def test_running_an_action_logs_it_and_holds_the_window(
    page: Page, helper: Callable[[str], Path], passthrough_pkexec: Path, pump: Pump
) -> None:
    helper('echo "rebuilding $1"')

    page.button("Rebuild").emit("clicked")
    pump(lambda: page.busy[-1] is False)

    assert page.lines == ["── Rebuild ──", "rebuilding rebuild", "", "Finished."]
    # Busy while root works, and only then let go.
    assert page.busy == [True, False]


def test_a_failed_action_says_what_happened_instead_of_finished(
    page: Page, helper: Callable[[str], Path], passthrough_pkexec: Path, pump: Pump
) -> None:
    helper('echo "trying"\nexit 1')

    page.button("Update").emit("clicked")
    pump(lambda: page.busy[-1] is False)

    assert page.lines == [
        "── Update now ──",
        "trying",
        "",
        "The helper reported a failure. The log above has the detail.",
    ]


def test_each_run_starts_from_an_empty_log(
    page: Page, helper: Callable[[str], Path], passthrough_pkexec: Path, pump: Pump
) -> None:
    helper('echo "$1"')

    page.button("Rebuild").emit("clicked")
    pump(lambda: page.busy[-1] is False)
    page.button("Update").emit("clicked")
    pump(lambda: len(page.busy) == 4)

    assert page.lines[0] == "── Update now ──"
    assert "rebuild" not in page.lines


def test_what_is_applied_arrives_on_the_helper_s_stdin(
    page: Page, helper: Callable[[str], Path], passthrough_pkexec: Path, pump: Pump
) -> None:
    helper("cat")
    applied: list[None] = []

    page.page.start(
        "apply",
        "Applying settings",
        stdin_text='{"hostName": "kitchen"}',
        on_success=lambda: applied.append(None),
    )
    pump(lambda: page.busy[-1] is False)

    assert page.lines == ["── Applying settings ──", '{"hostName": "kitchen"}', "", "Finished."]
    assert applied == [None]


def test_nothing_follows_a_run_that_failed(
    page: Page, helper: Callable[[str], Path], passthrough_pkexec: Path, pump: Pump
) -> None:
    helper("exit 1")
    applied: list[None] = []

    page.page.start("apply", "Applying settings", on_success=lambda: applied.append(None))
    pump(lambda: page.busy[-1] is False)

    assert applied == []


def test_a_failure_with_nothing_to_say_still_lets_the_window_go(
    page: Page, monkeypatch: pytest.MonkeyPatch
) -> None:
    """The one report the Runner does not produce, and the log still has to
    be left in a state somebody can read.

    Every failure it does produce carries a sentence — that is what _explain
    is for — so this comes in through a stand-in rather than through a
    helper that could not be made to behave this way.
    """
    handlers: dict[str, Callable[..., None]] = {}

    class Stub:
        def __init__(self, on_line: Callable[[str], None], on_done: Callable[..., None]) -> None:
            handlers["line"] = on_line
            handlers["done"] = on_done

        def run(self, command: str, stdin_text: str | None = None) -> None:
            handlers["command"] = lambda: None

    monkeypatch.setattr("nano_settings.maintenance.Runner", Stub)
    page.page.start("rebuild", "Rebuild")

    handlers["done"](False, "")

    assert page.lines == ["── Rebuild ──"]
    assert page.busy == [True, False]


def test_the_buttons_go_away_while_root_is_working(page: Page) -> None:
    page.page.set_sensitive(False)
    assert not any(button.get_sensitive() for button in page.page.buttons)

    page.page.set_sensitive(True)
    assert all(button.get_sensitive() for button in page.page.buttons)


# ── rolling back ─────────────────────────────────────────────────────


def test_rolling_back_asks_first(
    page: Page, host: Adw.Window, helper: Callable[[str], Path], passthrough_pkexec: Path
) -> None:
    helper('echo "rolled back"')
    host.set_content(page.page.view)

    page.button("Roll back").emit("clicked")

    # Nothing has run: the dialog is up and the log is untouched.
    assert page.lines == []
    assert page.busy == []


@pytest.mark.parametrize(("response", "ran"), [("rollback", True), ("cancel", False)])
def test_the_answer_to_that_question_is_obeyed(
    page: Page,
    helper: Callable[[str], Path],
    passthrough_pkexec: Path,
    pump: Pump,
    response: str,
    ran: bool,
) -> None:
    helper('echo "rolled back"')
    rollback = next(action for action in ACTIONS if action.command == "rollback")

    page.page._on_rollback_response(Adw.AlertDialog(), response, rollback)

    if ran:
        pump(lambda: page.busy[-1] is False)
        assert page.lines == ["── Roll back ──", "rolled back", "", "Finished."]
    else:
        assert page.lines == []
        assert page.busy == []
