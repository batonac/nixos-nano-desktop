"""The window: the sidebar, the banner, and the Apply flow end to end."""

from __future__ import annotations

import json
from collections.abc import Callable
from pathlib import Path
from typing import Any

import pytest
from gi.repository import Adw, Gtk

from conftest import Pump, ScriptWriter
from nano_settings import paths, presentation
from nano_settings.settings import Schema, Settings
from nano_settings.window import Window

# What the window hands to network.check_online: the answer goes here.
OnAnswer = Callable[[bool], None]


@pytest.fixture
def application() -> Adw.Application:
    return Adw.Application(application_id="nu.avu.NanoSettings.Test")


@pytest.fixture
def window(
    application: Adw.Application, schema: Schema, settings: Settings, catalog_file: Path
) -> Window:
    return Window(application, schema, settings)


def visit(window: Window, ident: str) -> None:
    """Choose a page from the sidebar — which is what builds it."""
    window._goto(ident)


# ── what gets built ──────────────────────────────────────────────────


def test_only_the_first_page_is_built_to_begin_with(window: Window) -> None:
    built = [
        page.ident
        for page in presentation.PAGES
        if window.stack.get_child_by_name(page.ident) is not None
    ]
    assert built == [presentation.PAGES[0].ident]


def test_every_page_is_in_the_stack_once_it_has_been_visited(window: Window) -> None:
    for page in presentation.PAGES:
        visit(window, page.ident)
        assert window.stack.get_child_by_name(page.ident) is not None, page.ident


def test_a_page_is_built_once_however_often_it_is_visited(window: Window) -> None:
    visit(window, "hardware")
    child = window.stack.get_child_by_name("hardware")
    rows = len(window.option_rows)

    visit(window, "system")
    visit(window, "hardware")

    assert window.stack.get_child_by_name("hardware") is child
    assert len(window.option_rows) == rows


def test_the_three_hand_built_pages_are_wired_up_when_visited(window: Window) -> None:
    assert (window.software, window.account, window.maintenance) == (None, None, None)

    visit(window, "software")
    visit(window, "account")
    visit(window, "updates")

    assert window.software is not None
    assert window.software.view is window.stack.get_child_by_name("software")
    assert window.account is not None
    assert window.account.view is window.stack.get_child_by_name("account")
    assert window.maintenance is not None
    assert window.maintenance.view is window.stack.get_child_by_name("updates")


def test_the_generated_rows_are_kept_for_refreshing(window: Window) -> None:
    keys = {row.spec.key for row in window.option_rows}
    # System is open, Hardware has not been looked at.
    assert "hostName" in keys
    assert "features.printing" not in keys

    visit(window, "hardware")
    visit(window, "software")

    keys = {row.spec.key for row in window.option_rows}
    assert "features.printing" in keys
    # The custom pages bring their own rows; these are only the generated ones.
    assert "extraPackageNames" not in keys


def test_the_sidebar_lists_the_pages_in_order(window: Window) -> None:
    titles = []
    row = window.sidebar.get_row_at_index(0)
    index = 0
    while row is not None:
        assert isinstance(row, Adw.ActionRow)
        titles.append(row.get_title())
        index += 1
        row = window.sidebar.get_row_at_index(index)
    assert titles == [page.title for page in presentation.PAGES]


def test_the_window_opens_on_the_first_page(window: Window) -> None:
    assert window.stack.get_visible_child_name() == presentation.PAGES[0].ident
    assert window.content_page.get_title() == presentation.PAGES[0].title


def test_choosing_from_the_sidebar_moves_the_stack_and_the_title(window: Window) -> None:
    window.sidebar.select_row(window.sidebar.get_row_at_index(3))

    assert window.stack.get_visible_child_name() == presentation.PAGES[3].ident
    assert window.content_page.get_title() == presentation.PAGES[3].title


def test_unselecting_the_sidebar_changes_nothing(window: Window) -> None:
    window.sidebar.select_row(window.sidebar.get_row_at_index(2))
    window.sidebar.unselect_all()

    assert window.stack.get_visible_child_name() == presentation.PAGES[2].ident


# ── the banner ───────────────────────────────────────────────────────


def test_a_clean_window_offers_nothing_to_apply(window: Window) -> None:
    assert not window.banner.get_revealed()
    assert not window.apply_button.get_sensitive()


def test_one_edit_is_counted_in_the_singular(window: Window, settings: Settings) -> None:
    settings.set("hostName", "study")
    window._on_change()

    assert window.banner.get_revealed()
    assert window.banner.get_title() == "1 setting changed but not applied"
    assert window.apply_button.get_sensitive()


def test_more_than_one_edit_is_counted(window: Window, settings: Settings) -> None:
    settings.set("hostName", "study")
    settings.set("timeZone", "Europe/Paris")
    window._on_change()

    assert window.banner.get_title() == "2 settings changed but not applied"


def test_an_edit_made_in_a_page_reaches_the_banner(window: Window) -> None:
    row = next(row for row in window.option_rows if row.spec.key == "hostName")
    assert isinstance(row.widget, Adw.EntryRow)
    row.widget.set_text("study")

    assert window.banner.get_revealed()
    assert window.banner.get_title() == "1 setting changed but not applied"


def test_a_page_built_late_shows_what_is_pending_and_reports_nothing(
    window: Window, settings: Settings
) -> None:
    settings.set("features.printing", True)
    window._on_change()

    visit(window, "hardware")

    row = next(row for row in window.option_rows if row.spec.key == "features.printing")
    assert isinstance(row.widget, Adw.SwitchRow)
    assert row.widget.get_active()
    assert row.changed_icon.get_visible()
    # Building the page read the edit; it did not make a second one.
    assert settings.pending == {"features.printing": True}
    assert window.banner.get_title() == "1 setting changed but not applied"


def test_nothing_can_be_applied_while_root_is_already_working(
    window: Window, settings: Settings
) -> None:
    maintenance = window._updates()
    settings.set("hostName", "study")
    window._on_change()

    window._set_busy(True)
    assert not window.apply_button.get_sensitive()
    assert not any(button.get_sensitive() for button in maintenance.buttons)
    # The banner stays up: the edit is still pending, it just cannot be
    # started a second time.
    assert window.banner.get_revealed()

    window._set_busy(False)
    assert window.apply_button.get_sensitive()
    assert all(button.get_sensitive() for button in maintenance.buttons)


# ── applying ─────────────────────────────────────────────────────────


def test_applying_nothing_does_nothing(window: Window) -> None:
    window._on_apply(window.apply_button)
    assert not window.settings.dirty


def test_applying_while_busy_does_nothing(
    window: Window, settings: Settings, monkeypatch: pytest.MonkeyPatch
) -> None:
    started: list[str] = []
    monkeypatch.setattr(
        window._updates(), "start", lambda command, *a, **k: started.append(command)
    )
    settings.set("hostName", "study")
    window._set_busy(True)

    window._on_apply(window.apply_button)

    assert started == []


def test_the_review_dialog_names_every_change_in_words(
    window: Window, settings: Settings, monkeypatch: pytest.MonkeyPatch
) -> None:
    presented: list[Adw.AlertDialog] = []
    monkeypatch.setattr(
        Adw.AlertDialog, "present", lambda dialog, parent: presented.append(dialog)
    )
    settings.set("features.printing", True)
    settings.set("hostName", "study")
    window._on_change()

    window.banner.emit("button-clicked")

    body = presented[0].get_body()
    # The row's title, not the option name, and the values as the rows show
    # them rather than as JSON.
    assert "• Printing:  off  →  on" in body
    assert "• Computer name:  kitchen  →  study" in body
    assert "rebuilds the system" in body


def _presented(monkeypatch: pytest.MonkeyPatch) -> list[Adw.AlertDialog]:
    presented: list[Adw.AlertDialog] = []
    monkeypatch.setattr(
        Adw.AlertDialog, "present", lambda dialog, parent: presented.append(dialog)
    )
    return presented


def _network_says(monkeypatch: pytest.MonkeyPatch, online: bool) -> None:
    """A network that answers at once, which the real one never does."""
    monkeypatch.setattr(
        "nano_settings.window.network.check_online",
        lambda callback, **kwargs: callback(online),
    )


def _network_waits(monkeypatch: pytest.MonkeyPatch) -> list[OnAnswer]:
    """A network that is still thinking: the answer is whatever the test says."""
    pending: list[OnAnswer] = []
    monkeypatch.setattr(
        "nano_settings.window.network.check_online",
        lambda callback, **kwargs: pending.append(callback),
    )
    return pending


def test_a_download_is_refused_in_words_when_the_machine_is_offline(
    window: Window, settings: Settings, monkeypatch: pytest.MonkeyPatch
) -> None:
    presented = _presented(monkeypatch)
    _network_says(monkeypatch, False)
    # officeSuite is the option the install media bakes as "none"; anything
    # else is a download. Something unrelated changes alongside it, and is
    # held back with it — one Apply is one rebuild.
    settings.set("officeSuite", "gnome")
    settings.set("hostName", "study")
    window._on_change()

    window._on_apply(window.apply_button)

    dialog = presented[0]
    assert dialog.get_heading() == "Not connected to the internet"
    body = dialog.get_body()
    assert "• Office suite" in body
    assert "Computer name" not in body
    assert "not on the install media" in body
    # Nothing to apply from this dialog: the one response closes it.
    assert dialog.has_response("close")
    assert not dialog.has_response("apply")
    assert settings.dirty
    # And the button is back, for when the network is.
    assert not window.checking
    assert window.apply_button.get_sensitive()


def test_a_download_is_named_in_the_review_when_online(
    window: Window, settings: Settings, monkeypatch: pytest.MonkeyPatch
) -> None:
    presented = _presented(monkeypatch)
    asked: list[None] = []

    def check_online(callback: OnAnswer, **kwargs: object) -> None:
        asked.append(None)
        callback(True)

    monkeypatch.setattr("nano_settings.window.network.check_online", check_online)
    # "gnome", not "libreoffice": the fixture machine already defaults to
    # LibreOffice, so that would be no change at all.
    settings.set("officeSuite", "gnome")
    window._on_change()

    window._on_apply(window.apply_button)

    dialog = presented[0]
    assert dialog.get_heading() == "Apply these changes?"
    assert "Some of these download their programs — Office suite —" in dialog.get_body()
    assert dialog.has_response("apply")
    assert asked == [None]


def test_setting_an_option_back_to_the_media_value_asks_nothing_of_the_network(
    window: Window, settings: Settings, monkeypatch: pytest.MonkeyPatch
) -> None:
    presented = _presented(monkeypatch)
    monkeypatch.setattr(
        "nano_settings.window.network.check_online",
        lambda callback, **kwargs: pytest.fail(
            "the network was consulted for a change that needs none"
        ),
    )
    settings.set("officeSuite", "none")
    window._on_change()

    window._on_apply(window.apply_button)

    assert presented[0].get_heading() == "Apply these changes?"
    assert "download" not in presented[0].get_body()


def test_the_apply_button_waits_for_the_network_to_answer(
    window: Window, settings: Settings, monkeypatch: pytest.MonkeyPatch
) -> None:
    presented = _presented(monkeypatch)
    pending = _network_waits(monkeypatch)
    settings.set("officeSuite", "gnome")
    window._on_change()

    window._on_apply(window.apply_button)

    # The question is out and the answer is not back: nothing to click yet,
    # and no dialog either — the window is not frozen, only the button.
    # (Compared as a pair rather than asserted one by one: mypy would take
    # the first assertion as narrowing `checking` for good, and call the
    # opposite assertion below unreachable.)
    assert (window.checking, window.apply_button.get_sensitive()) == (True, False)
    assert window.banner.get_revealed()
    assert presented == []
    # A second click while waiting asks nothing more.
    window._on_apply(window.apply_button)
    assert len(pending) == 1

    pending[0](True)

    assert (window.checking, window.apply_button.get_sensitive()) == (False, True)
    assert presented[0].get_heading() == "Apply these changes?"


def test_a_download_set_back_while_the_network_was_asked_needs_no_network(
    window: Window, settings: Settings, monkeypatch: pytest.MonkeyPatch
) -> None:
    presented = _presented(monkeypatch)
    pending = _network_waits(monkeypatch)
    settings.set("officeSuite", "gnome")
    settings.set("hostName", "study")
    window._on_change()
    window._on_apply(window.apply_button)

    # The pages stayed live: back to what is applied, which is no download.
    settings.set("officeSuite", "libreoffice")
    pending[0](False)

    # Offline, and it no longer matters: the review goes ahead with what is
    # left, and says nothing about downloads.
    assert presented[0].get_heading() == "Apply these changes?"
    assert "Computer name" in presented[0].get_body()
    assert "download" not in presented[0].get_body()


def test_everything_set_back_while_the_network_was_asked_leaves_nothing_to_ask(
    window: Window, settings: Settings, monkeypatch: pytest.MonkeyPatch
) -> None:
    presented = _presented(monkeypatch)
    pending = _network_waits(monkeypatch)
    settings.set("officeSuite", "gnome")
    window._on_change()
    window._on_apply(window.apply_button)

    settings.set("officeSuite", "libreoffice")
    pending[0](True)

    assert presented == []
    assert not window.checking
    assert not settings.dirty


def test_an_option_with_no_row_of_its_own_is_named_by_its_key(window: Window) -> None:
    assert window._label("features.printing") == "Printing"
    assert window._label("features.autoUpgrade") == "autoUpgrade"
    assert window._label("extraPackageNames") == "extraPackageNames"


def test_cancelling_the_review_applies_nothing(
    window: Window, settings: Settings, monkeypatch: pytest.MonkeyPatch
) -> None:
    started: list[str] = []
    monkeypatch.setattr(
        window._updates(), "start", lambda command, *a, **k: started.append(command)
    )
    settings.set("hostName", "study")

    window._on_apply_response(Adw.AlertDialog(), "cancel")

    assert started == []
    assert settings.dirty


def test_applying_hands_the_whole_file_over_and_shows_the_log(
    window: Window, settings: Settings, monkeypatch: pytest.MonkeyPatch
) -> None:
    handed: dict[str, Any] = {}
    monkeypatch.setattr(
        window._updates(),
        "start",
        lambda command, title, **kwargs: handed.update(
            command=command, title=title, **kwargs
        ),
    )
    settings.set("hostName", "study")

    window._on_apply_response(Adw.AlertDialog(), "apply")

    assert handed["command"] == "apply"
    assert handed["title"] == "Applying settings"
    # The whole file, not a diff: the helper replaces it wholesale.
    assert json.loads(handed["stdin_text"]) == {
        "hostName": "study",
        "swapSizeGiB": 4,
        "compressionLevel": "balanced",
        "extraPackageNames": ["gimp", "htop"],
        "features": {"printing": False},
    }
    assert handed["on_success"] == window._on_applied
    # ...and the log is what the user is now looking at.
    assert window.stack.get_visible_child_name() == "updates"
    assert window.content_page.get_title() == "Updates"


def test_a_successful_apply_settles_the_window(window: Window, settings: Settings) -> None:
    visit(window, "software")
    visit(window, "updates")
    settings.set("hostName", "study")
    settings.set("extraPackageNames", ["gimp"])
    settings.set("features.autoUpgrade", False)
    window._on_change()

    window._on_applied()

    assert not settings.dirty
    assert settings.applied("hostName") == "study"
    assert not window.banner.get_revealed()
    # Every page is told, not just the one that was edited.
    row = next(row for row in window.option_rows if row.spec.key == "hostName")
    assert isinstance(row.widget, Adw.EntryRow)
    assert row.widget.get_text() == "study"
    assert not row.changed_icon.get_visible()
    assert window.software is not None
    assert window.software._rows["gimp"].get_active()
    assert window.maintenance is not None
    assert not window.maintenance.auto_row.get_active()


def test_a_successful_apply_needs_no_page_that_was_never_opened(
    window: Window, settings: Settings
) -> None:
    settings.set("extraPackageNames", ["gimp"])
    settings.set("features.autoUpgrade", False)
    window._on_change()

    window._on_applied()

    assert not settings.dirty
    assert (window.software, window.maintenance) == (None, None)
    # Built afterwards, the pages read what was applied.
    visit(window, "software")
    visit(window, "updates")
    assert window.software is not None
    assert window.software._rows["gimp"].get_active()
    assert not window.software._rows["inkscape"].get_active()
    assert window.maintenance is not None
    assert not window.maintenance.auto_row.get_active()


def test_going_to_a_page_that_is_not_there_leaves_the_window_alone(window: Window) -> None:
    window._goto("nonesuch")
    assert window.stack.get_visible_child_name() == presentation.PAGES[0].ident


# ── the whole way through ────────────────────────────────────────────


def test_apply_reaches_the_helper_and_comes_back(
    window: Window,
    settings: Settings,
    shell_script: ScriptWriter,
    passthrough_pkexec: Path,
    monkeypatch: pytest.MonkeyPatch,
    pump: Pump,
    tmp_path: Path,
) -> None:
    """Everything between the button and the toast, with a helper that works.

    The only thing standing in for the real system is the helper itself,
    which here writes what it was sent to a file instead of to /etc/nixos and
    rebuilding — the two things a test must not do.
    """
    written = tmp_path / "nanoDesktop-settings.json"
    helper = shell_script(
        "nano-settings-helper",
        f'echo "Settings written."\ncat > {written}\necho "Done."',
    )
    monkeypatch.setattr(paths, "HELPER", helper)

    settings.set("hostName", "study")
    settings.set("features.bluetooth", False)
    window._on_change()

    # Nobody has looked at the Updates page; applying is what builds it.
    assert window.maintenance is None
    window._on_apply_response(Adw.AlertDialog(), "apply")
    assert window.stack.get_visible_child_name() == "updates"
    pump(lambda: not window.busy)

    assert json.loads(written.read_text())["hostName"] == "study"
    assert json.loads(written.read_text())["features"] == {
        "printing": False,
        "bluetooth": False,
    }
    assert not settings.dirty
    assert not window.banner.get_revealed()
    assert window.apply_button.get_sensitive() is False


def _labels(widget: Gtk.Widget) -> list[str]:
    found: list[str] = []
    child = widget.get_first_child()
    while child is not None:
        if isinstance(child, Gtk.Label):
            found.append(child.get_label())
        found.extend(_labels(child))
        child = child.get_next_sibling()
    return found


def test_the_toast_says_it_was_applied(window: Window, settings: Settings) -> None:
    settings.set("hostName", "study")
    window._on_applied()
    assert "Settings applied." in _labels(window.toasts)


def test_the_window_is_usable_at_the_size_this_desktop_targets(window: Window) -> None:
    width, height = window.get_default_size()
    assert width <= 1366 and height <= 768
