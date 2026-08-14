"""Starting up: the agent, the window, and the one screen for when neither."""

from __future__ import annotations

import json
from pathlib import Path

import pytest
from gi.repository import Adw, GLib, Gtk

from conftest import SCHEMA_TREE
from nano_settings import paths
from nano_settings.__main__ import Application, main
from nano_settings.window import Window


@pytest.fixture
def installed(tmp_path: Path, monkeypatch: pytest.MonkeyPatch, catalog_file: Path) -> Path:
    """A machine this application can read: a schema and a settings file."""
    schema = tmp_path / "schema.json"
    schema.write_text(json.dumps(SCHEMA_TREE))
    monkeypatch.setattr(paths, "SCHEMA", schema)

    settings = tmp_path / "nanoDesktop-settings.json"
    settings.write_text(json.dumps({"hostName": "kitchen"}))
    monkeypatch.setattr(paths, "SETTINGS", settings)
    return settings


def run_once(application: Application) -> None:
    """Start the application, let it settle, and quit — as a session does."""

    def on_activate(app: Application) -> None:
        GLib.idle_add(app.quit)

    application.connect("activate", on_activate)
    application.run([])


def test_a_session_start_opens_the_window(installed: Path) -> None:
    application = Application()

    run_once(application)

    assert isinstance(application.window, Window)
    assert application.window.settings.applied("hostName") == "kitchen"


def test_the_window_is_built_once_however_often_it_is_asked_for(installed: Path) -> None:
    application = Application()
    seen: list[Window | None] = []

    def on_activate(app: Application) -> None:
        # A handler connected here runs before the class closure, so this
        # reaches do_activate with no window; the default handler that comes
        # after it finds one, which is the other half of that branch.
        app.do_activate()
        seen.append(app.window)
        GLib.idle_add(app.quit)

    application.connect("activate", on_activate)
    application.run([])

    # Asked for twice, built once: the second activation presents what the
    # first one made rather than making another.
    assert seen[0] is application.window
    assert len(application.get_windows()) == 1


def test_the_agent_starts_with_the_application_and_stops_with_it(
    installed: Path, monkeypatch: pytest.MonkeyPatch, shell_script: object
) -> None:
    application = Application()
    started: list[str] = []
    stopped: list[str] = []
    monkeypatch.setattr(application.agent, "start", lambda: started.append("start"))
    monkeypatch.setattr(application.agent, "stop", lambda: stopped.append("stop"))

    run_once(application)

    # Started at startup rather than at the first privileged action, so that
    # by the time anyone clicks Apply it has long since registered.
    assert started == ["start"]
    assert stopped == ["stop"]


def test_settings_that_cannot_be_read_get_a_screen_of_their_own(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(paths, "SCHEMA", tmp_path / "no-schema-here.json")
    application = Application()

    run_once(application)

    assert application.window is None
    status = _status_page(application)
    assert status is not None
    assert status.get_title() == "Settings could not be read"
    assert "no-schema-here.json" in (status.get_description() or "")


def test_a_settings_file_that_is_not_json_gets_the_same_screen(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    schema = tmp_path / "schema.json"
    schema.write_text(json.dumps(SCHEMA_TREE))
    monkeypatch.setattr(paths, "SCHEMA", schema)
    settings = tmp_path / "nanoDesktop-settings.json"
    settings.write_text("{ not json")
    monkeypatch.setattr(paths, "SETTINGS", settings)
    application = Application()

    run_once(application)

    assert application.window is None
    status = _status_page(application)
    assert status is not None
    assert "could not be read" in (status.get_description() or "")


def _status_page(application: Adw.Application) -> Adw.StatusPage | None:
    for window in application.get_windows():
        found = _find_status(window)
        if found is not None:
            return found
    return None


def _find_status(widget: Gtk.Widget) -> Adw.StatusPage | None:
    if isinstance(widget, Adw.StatusPage):
        return widget
    if isinstance(widget, Adw.ApplicationWindow):
        content = widget.get_content()
        return None if content is None else _find_status(content)
    child = widget.get_first_child()
    while child is not None:
        found = _find_status(child)
        if found is not None:
            return found
        child = child.get_next_sibling()
    return None


def test_the_application_is_the_one_the_desktop_file_names() -> None:
    # The .desktop file, the polkit action and this have to agree, or the
    # window gets no icon and the single-instance check never matches.
    assert Application().get_application_id() == paths.APP_ID == "nu.avu.NanoSettings"


def test_main_runs_the_application_and_returns_its_status(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    seen: list[list[str]] = []

    def run(_self: Application, argv: list[str]) -> int:
        seen.append(argv)
        return 3

    monkeypatch.setattr(Application, "run", run)
    monkeypatch.setattr("sys.argv", ["nano-settings", "--help"])

    assert main() == 3
    assert seen == [["nano-settings", "--help"]]
