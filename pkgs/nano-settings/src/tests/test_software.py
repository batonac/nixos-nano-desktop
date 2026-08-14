"""The Software page: the catalogue, the list it writes, and the name check.

The name check runs a real subprocess through Gio and reads what it says, so
what stands in for nix here is a script that answers the way nix answers —
including the two ways it says no, which are not the same and are not shown
the same.
"""

from __future__ import annotations

import json
from collections.abc import Callable
from pathlib import Path
from typing import cast

import pytest
from gi.repository import Gio, GLib, Gtk

from conftest import Pump, ScriptWriter
from nano_settings import paths, software
from nano_settings.settings import Settings
from nano_settings.software import KEY, SoftwarePage, load_catalog

# ── the catalogue file ───────────────────────────────────────────────


def test_the_catalogue_is_read_and_filled_in(catalog_file: Path) -> None:
    catalogue = load_catalog()
    assert [item["attr"] for item in catalogue] == ["gimp", "inkscape", "steam", "unrar"]
    assert catalogue[1]["category"] == "Other"
    assert catalogue[2]["unfree"] is True


def test_a_missing_catalogue_costs_the_suggestions_and_nothing_else(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(paths, "CATALOG", tmp_path / "absent.json")
    assert load_catalog() == []


@pytest.mark.parametrize("contents", ["{not json", '{"gimp": true}', '"a string"'])
def test_a_catalogue_that_is_not_a_list_of_entries_is_ignored(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, contents: str
) -> None:
    path = tmp_path / "catalog.json"
    path.write_text(contents)
    monkeypatch.setattr(paths, "CATALOG", path)
    assert load_catalog() == []


def test_one_bad_entry_does_not_take_the_others_with_it(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    path = tmp_path / "catalog.json"
    path.write_text(json.dumps([{"attr": "gimp", "name": "GIMP"}, {"nam": "typo"}, 7]))
    monkeypatch.setattr(paths, "CATALOG", path)
    assert [item["attr"] for item in load_catalog()] == ["gimp"]


# ── the page ─────────────────────────────────────────────────────────


@pytest.fixture
def page(settings: Settings, catalog_file: Path) -> SoftwarePage:
    return SoftwarePage(settings, lambda: None)


def test_the_catalogue_is_grouped_by_category(page: SoftwarePage) -> None:
    assert [group.get_title() for group in page.groups] == ["Games", "Graphics", "Other"]


def test_an_unfree_package_says_so_on_its_row(page: SoftwarePage) -> None:
    assert page._rows["steam"].get_subtitle() == "Games  ·  Unfree licence"
    # ...including when there is no summary to say it after.
    assert page._rows["unrar"].get_subtitle() == "Unfree licence"
    assert page._rows["gimp"].get_subtitle() == "Photo editor"


def test_what_is_installed_is_switched_on(page: SoftwarePage) -> None:
    assert page._rows["gimp"].get_active()
    assert not page._rows["steam"].get_active()


def test_turning_a_row_on_adds_it_sorted_and_deduplicated(
    page: SoftwarePage, settings: Settings
) -> None:
    page._rows["steam"].set_active(True)
    assert settings.pending[KEY] == ["gimp", "htop", "steam"]


def test_turning_a_row_off_removes_it(page: SoftwarePage, settings: Settings) -> None:
    page._rows["gimp"].set_active(False)
    assert settings.pending[KEY] == ["htop"]


def test_refresh_does_not_report_the_state_it_is_displaying(
    settings: Settings, catalog_file: Path
) -> None:
    changes: list[None] = []
    page = SoftwarePage(settings, lambda: changes.append(None))
    settings.set(KEY, ["steam"])
    changes.clear()

    page.refresh()

    assert changes == []
    assert page._rows["steam"].get_active()
    assert not page._rows["gimp"].get_active()


def test_packages_named_by_hand_get_a_row_of_their_own(page: SoftwarePage) -> None:
    # htop is in the settings file but not in the catalogue.
    assert [row.get_title() for row in page._extra_rows] == ["htop"]
    assert page.extra_group.get_visible()


def test_the_by_name_group_disappears_once_it_is_empty(
    page: SoftwarePage, settings: Settings
) -> None:
    page.remove("htop")
    page.refresh()
    assert page._extra_rows == []
    assert not page.extra_group.get_visible()


def test_a_by_name_row_can_be_removed_from_its_own_row(
    page: SoftwarePage, settings: Settings
) -> None:
    row = page._extra_rows[0]
    trash = next(
        child
        for child in _descendants(row)
        if isinstance(child, Gtk.Button) and child.get_tooltip_text() == "Remove"
    )
    trash.emit("clicked")

    assert settings.pending[KEY] == ["gimp"]


def _descendants(widget: Gtk.Widget) -> list[Gtk.Widget]:
    found: list[Gtk.Widget] = []
    child = widget.get_first_child()
    while child is not None:
        found.append(child)
        found.extend(_descendants(child))
        child = child.get_next_sibling()
    return found


def test_a_settings_file_whose_package_list_is_not_a_list(
    settings: Settings, catalog_file: Path
) -> None:
    settings.stored[KEY] = "gimp"
    page = SoftwarePage(settings, lambda: None)
    assert not any(row.get_active() for row in page._rows.values())


def test_entries_in_the_list_that_are_not_names_are_ignored(
    settings: Settings, catalog_file: Path
) -> None:
    settings.stored[KEY] = ["gimp", 7, None]
    page = SoftwarePage(settings, lambda: None)
    assert [row.get_title() for row in page._extra_rows] == []
    assert page._rows["gimp"].get_active()


# ── searching ────────────────────────────────────────────────────────


# A search entry does not report every keystroke; it waits to see whether
# more are coming. So these turn the loop rather than asserting straight
# after the text is set.


def test_searching_hides_the_rows_and_the_categories_that_empty(
    page: SoftwarePage, pump: Pump
) -> None:
    page.search.set_text("photo")
    pump(lambda: not page._rows["steam"].get_visible())

    assert page._rows["gimp"].get_visible()
    titles = [group.get_title() for group in page.groups if group.get_visible()]
    assert titles == ["Graphics"]


def test_searching_matches_the_attribute_as_well_as_the_name(
    page: SoftwarePage, pump: Pump
) -> None:
    page.search.set_text("inksc")
    pump(lambda: not page._rows["gimp"].get_visible())

    assert page._rows["inkscape"].get_visible()


def test_clearing_the_search_brings_everything_back(page: SoftwarePage, pump: Pump) -> None:
    page.search.set_text("photo")
    pump(lambda: not page._rows["steam"].get_visible())

    page.search.set_text("")
    pump(lambda: page._rows["steam"].get_visible())

    assert all(row.get_visible() for row in page._rows.values())
    assert all(group.get_visible() for group in page.groups)


# ── checking a name ──────────────────────────────────────────────────


@pytest.fixture
def fake_nix(monkeypatch: pytest.MonkeyPatch, shell_script: ScriptWriter) -> Callable[[str], Path]:
    def install(body: str) -> Path:
        path = shell_script("nix", body)
        monkeypatch.setattr(paths, "NIX", str(path))
        return path

    return install


def test_a_name_that_nixpkgs_has_is_added(
    page: SoftwarePage, settings: Settings, fake_nix: Callable[[str], Path], pump: Pump
) -> None:
    fake_nix('echo "hello-2.12"')
    page.manual_entry.set_text("hello")

    page.add_button.emit("clicked")
    pump(lambda: "Added" in page.manual_status.get_text())

    assert settings.pending[KEY] == ["gimp", "hello", "htop"]
    assert page.manual_status.get_text() == "Added hello (hello-2.12)."
    # The box empties, and the new name appears among the ones added by hand.
    assert page.manual_entry.get_text() == ""
    assert "hello" in [row.get_title() for row in page._extra_rows]


def test_pressing_return_in_the_box_checks_it_too(
    page: SoftwarePage, settings: Settings, fake_nix: Callable[[str], Path], pump: Pump
) -> None:
    fake_nix('echo "hello-2.12"')
    page.manual_entry.set_text("hello")

    page.manual_entry.emit("entry-activated")
    pump(lambda: "Added" in page.manual_status.get_text())

    assert "hello" in cast(list[str], settings.pending[KEY])


def test_a_name_nixpkgs_does_not_have_is_refused(
    page: SoftwarePage, settings: Settings, fake_nix: Callable[[str], Path], pump: Pump
) -> None:
    # The probe returns an empty string for an attribute that is simply not
    # there, and says nothing on stderr about it.
    fake_nix("true")
    page.manual_entry.set_text("nosuchthing")

    page.add_button.emit("clicked")
    pump(lambda: "Could not add" in page.manual_status.get_text())

    assert page.manual_status.get_text() == (
        "Could not add nosuchthing: there is no package by that name in nixpkgs"
    )
    assert not settings.dirty


def test_the_first_line_nix_marked_as_the_error_is_the_one_shown(
    page: SoftwarePage, fake_nix: Callable[[str], Path], pump: Pump
) -> None:
    fake_nix(
        "echo 'evaluating file ...' >&2\n"
        "echo 'error: Package ‘steam’ has an unfree license' >&2\n"
        "echo 'error: and a second one nobody needs to read' >&2\n"
        "exit 1"
    )
    page.manual_entry.set_text("steam")

    page.add_button.emit("clicked")
    pump(lambda: "Could not add" in page.manual_status.get_text())

    assert page.manual_status.get_text() == (
        "Could not add steam: Package ‘steam’ has an unfree license"
    )


def test_an_error_with_nothing_after_it_still_says_something(
    page: SoftwarePage, fake_nix: Callable[[str], Path], pump: Pump
) -> None:
    fake_nix("echo 'error:' >&2\nexit 1")
    page.manual_entry.set_text("broken")

    page.add_button.emit("clicked")
    pump(lambda: "Could not add" in page.manual_status.get_text())

    assert page.manual_status.get_text() == "Could not add broken: error:"


def test_a_failure_nix_did_not_label_falls_back_to_its_last_word(
    page: SoftwarePage, fake_nix: Callable[[str], Path], pump: Pump
) -> None:
    fake_nix("echo 'something went wrong' >&2\necho 'giving up' >&2\nexit 1")
    page.manual_entry.set_text("broken")

    page.add_button.emit("clicked")
    pump(lambda: "Could not add" in page.manual_status.get_text())

    assert page.manual_status.get_text() == "Could not add broken: giving up"


def test_the_check_ignores_this_session_s_unfree_settings(
    page: SoftwarePage,
    fake_nix: Callable[[str], Path],
    pump: Pump,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # A check that read them would pass things the rebuild — which runs as
    # root through pkexec, with none of this environment — would then refuse.
    monkeypatch.setenv("NIXPKGS_ALLOW_UNFREE", "1")
    monkeypatch.setenv("NIXPKGS_CONFIG", "/home/someone/nixpkgs-config.nix")
    fake_nix('echo "unfree=[$NIXPKGS_ALLOW_UNFREE] config=[$NIXPKGS_CONFIG]"')
    page.manual_entry.set_text("steam")

    page.add_button.emit("clicked")
    pump(lambda: "Added" in page.manual_status.get_text())

    assert page.manual_status.get_text() == "Added steam (unfree=[] config=[])."


def test_the_button_comes_back_whatever_the_answer_was(
    page: SoftwarePage, fake_nix: Callable[[str], Path], pump: Pump
) -> None:
    fake_nix("exit 1")
    page.manual_entry.set_text("broken")

    page.add_button.emit("clicked")
    assert not page.add_button.get_sensitive()

    pump(lambda: "Could not add" in page.manual_status.get_text())
    assert page.add_button.get_sensitive()


def test_a_nix_that_cannot_be_run_is_reported(
    page: SoftwarePage, monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    monkeypatch.setattr(paths, "NIX", str(tmp_path / "no-nix"))
    page.manual_entry.set_text("hello")

    page.add_button.emit("clicked")

    assert page.manual_status.get_text().startswith("Could not run nix:")
    assert page.add_button.get_sensitive()


class _CommunicateThatFails:
    """A Gio.Subprocess whose output could not be collected."""

    def communicate_utf8_finish(self, _result: Gio.AsyncResult) -> tuple[bool, str, str]:
        raise GLib.Error("the pipe went away")


def test_output_that_cannot_be_collected_is_reported(page: SoftwarePage) -> None:
    page._on_validated(
        cast(Gio.Subprocess, _CommunicateThatFails()),
        cast(Gio.AsyncResult, None),
        "hello",
    )
    assert page.manual_status.get_text().startswith("Could not check hello:")


# ── what is not even worth asking nix about ──────────────────────────


def test_an_empty_box_does_nothing(page: SoftwarePage) -> None:
    page.manual_entry.set_text("   ")
    page.add_button.emit("clicked")
    assert not page.manual_status.get_visible()


def test_a_name_already_in_the_list_is_not_checked_again(page: SoftwarePage) -> None:
    page.manual_entry.set_text("htop")
    page.add_button.emit("clicked")
    assert page.manual_status.get_text() == "htop is already in the list."


@pytest.mark.parametrize(
    "typed",
    [
        "gimp; rm -rf /",
        "(import <nixpkgs> {})",
        "gimp.",
        ".gimp",
        "-gimp",
        "gimp attr",
        'gimp"',
    ],
)
def test_anything_that_is_not_an_attribute_path_is_refused_before_nix_sees_it(
    page: SoftwarePage, typed: str, monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    # The name is spliced into a Nix expression, so this is the check that
    # keeps a typed package name from being typed Nix code. If it let one
    # through, the nix below would not exist to run it.
    monkeypatch.setattr(paths, "NIX", str(tmp_path / "there-is-no-nix"))
    page.manual_entry.set_text(typed)

    page.add_button.emit("clicked")

    assert page.manual_status.get_text().startswith("That is not an attribute name.")


@pytest.mark.parametrize(
    "typed",
    [
        "gimp",
        "hunspellDicts.en_US",
        "kdePackages.kdenlive",
        "transmission_4-gtk",
        "_1password",
    ],
)
def test_the_names_people_actually_type_are_accepted(typed: str) -> None:
    assert software.ATTR_RE.match(typed)


def test_the_probe_asks_about_one_attribute_of_the_pinned_nixpkgs(page: SoftwarePage) -> None:
    probe = page._probe("hunspellDicts.en_US")

    assert f'builtins.getFlake "{paths.FLAKE_DIR}"' in probe
    assert 'attrByPath [ "hunspellDicts" "en_US" ]' in probe
    # Forced through drvPath, because that is where nixpkgs decides whether
    # it will allow the package at all; .name answers happily either way.
    assert "builtins.seq found.drvPath found.name" in probe
    assert "config.allowUnfree = true;" in probe
