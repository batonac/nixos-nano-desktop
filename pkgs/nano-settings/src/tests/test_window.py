"""The window: the sidebar, the banner, and the Apply flow end to end."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

import pytest
from gi.repository import Adw, Gtk

from conftest import Pump, ScriptWriter
from nano_settings import paths, presentation
from nano_settings.settings import Schema, Settings
from nano_settings.window import Window


@pytest.fixture
def application() -> Adw.Application:
    return Adw.Application(application_id="nu.avu.NanoSettings.Test")


@pytest.fixture
def window(
    application: Adw.Application, schema: Schema, settings: Settings, catalog_file: Path
) -> Window:
    return Window(application, schema, settings)


# ── what gets built ──────────────────────────────────────────────────


def test_every_page_in_the_presentation_is_in_the_stack(window: Window) -> None:
    for page in presentation.PAGES:
        assert window.stack.get_child_by_name(page.ident) is not None, page.ident


def test_the_three_hand_built_pages_are_wired_up(window: Window) -> None:
    assert window.software.view is window.stack.get_child_by_name("software")
    assert window.account.view is window.stack.get_child_by_name("account")
    assert window.maintenance.view is window.stack.get_child_by_name("updates")


def test_the_generated_rows_are_kept_for_refreshing(window: Window) -> None:
    keys = {row.spec.key for row in window.option_rows}
    assert "hostName" in keys
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


def test_nothing_can_be_applied_while_root_is_already_working(
    window: Window, settings: Settings
) -> None:
    settings.set("hostName", "study")
    window._on_change()

    window._set_busy(True)
    assert not window.apply_button.get_sensitive()
    assert not any(button.get_sensitive() for button in window.maintenance.buttons)
    # The banner stays up: the edit is still pending, it just cannot be
    # started a second time.
    assert window.banner.get_revealed()

    window._set_busy(False)
    assert window.apply_button.get_sensitive()
    assert all(button.get_sensitive() for button in window.maintenance.buttons)


# ── applying ─────────────────────────────────────────────────────────


def test_applying_nothing_does_nothing(window: Window) -> None:
    window._on_apply(window.apply_button)
    assert not window.settings.dirty


def test_applying_while_busy_does_nothing(
    window: Window, settings: Settings, monkeypatch: pytest.MonkeyPatch
) -> None:
    started: list[str] = []
    monkeypatch.setattr(
        window.maintenance, "start", lambda command, *a, **k: started.append(command)
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


def test_an_option_with_no_row_of_its_own_is_named_by_its_key(window: Window) -> None:
    assert window._label("features.printing") == "Printing"
    assert window._label("features.autoUpgrade") == "autoUpgrade"
    assert window._label("extraPackageNames") == "extraPackageNames"


def test_cancelling_the_review_applies_nothing(
    window: Window, settings: Settings, monkeypatch: pytest.MonkeyPatch
) -> None:
    started: list[str] = []
    monkeypatch.setattr(
        window.maintenance, "start", lambda command, *a, **k: started.append(command)
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
        window.maintenance,
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
    settings.set("hostName", "study")
    settings.set("extraPackageNames", ["gimp"])
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
    assert window.software._rows["gimp"].get_active()


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

    window._on_apply_response(Adw.AlertDialog(), "apply")
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
