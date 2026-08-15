"""The accent palette: what survives being read, and what it turns into."""

from __future__ import annotations

import json
import os
from pathlib import Path

import pytest
from gi.repository import Gdk

from conftest import PALETTE, SCHEMA_TREE
from nano_settings import palette, paths
from nano_settings.settings import Schema


def write(tmp_path: Path, monkeypatch: pytest.MonkeyPatch, content: str) -> Path:
    path = tmp_path / "palette.json"
    path.write_text(content)
    monkeypatch.setattr(paths, "PALETTE", path)
    return path


# ── reading it ───────────────────────────────────────────────────────


def test_the_palette_is_the_file(palette_file: Path) -> None:
    assert palette.load() == PALETTE


def test_a_palette_that_is_not_there_is_no_palette(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    # Which costs the swatches and nothing else.
    monkeypatch.setattr(paths, "PALETTE", tmp_path / "absent.json")
    assert palette.load() == {}


def test_a_palette_that_is_not_json_is_no_palette(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    write(tmp_path, monkeypatch, "{not json")
    assert palette.load() == {}


def test_a_palette_that_is_not_an_object_is_no_palette(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    write(tmp_path, monkeypatch, '["blue", "teal"]')
    assert palette.load() == {}


@pytest.mark.parametrize(
    ("name", "value"),
    [
        # Neither of these can come out of pkgs/accent.nix. This is the one
        # place in the application that turns a file into CSS, and what it
        # will not write is worth stating.
        ("blue", 16),
        ("blue", "cornflower"),
        ("blue", "#12345"),
        ("blue; }", "#123456"),
        ("Blue", "#123456"),
    ],
)
def test_what_is_not_a_name_and_a_colour_does_not_reach_the_stylesheet(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, name: str, value: object
) -> None:
    write(tmp_path, monkeypatch, json.dumps({name: value, "teal": "#2190A4"}))

    # ...and the entry beside it still does, in the case it is written in.
    assert palette.load() == {"teal": "#2190a4"}


# ── filling the bar ──────────────────────────────────────────────────


def test_every_member_gets_its_colour(palette_file: Path) -> None:
    assert palette.swatch_colors(["red", "blue"]) == {"red": "#e62d42", "blue": "#3584e4"}


def test_one_member_without_a_colour_costs_the_whole_bar(palette_file: Path) -> None:
    assert palette.swatch_colors(["red", "chartreuse"]) == {}


def test_nothing_to_colour_is_not_a_bar(palette_file: Path) -> None:
    # An enum schema.nix could not read the members of. There is nothing to
    # draw, so the dropdown — which can at least say so — is what is drawn.
    assert palette.swatch_colors([]) == {}


# ── the stylesheet ───────────────────────────────────────────────────


def test_the_stylesheet_paints_every_colour_it_is_given() -> None:
    css = palette.stylesheet({"blue": "#3584e4", "red": "#e62d42"})

    assert ".accent-swatch-blue radio" in css
    assert css.count("#3584e4") == 2  # the disc, and the ring around it
    assert ".accent-swatch-red radio" in css
    assert "#e62d42" in css
    # The bar's own rules are there once, whatever is in the palette.
    assert css.count(f".{palette.BAR_CLASS} checkbutton radio {{") == 1


def test_the_stylesheet_beats_the_theme_at_its_own_selector() -> None:
    # libadwaita styles `checkbutton radio:checked` itself, and with the
    # accent it is already using. Stated less specifically than that, the bar
    # would show one colour nine times.
    css = palette.stylesheet({"blue": "#3584e4"})
    assert ".accent-swatch-blue radio:checked" in css


def test_the_stylesheet_is_installed_once(palette_file: Path) -> None:
    display = Gdk.Display.get_default()
    assert display is not None

    first = palette.install(display)
    assert first is palette.install(display)


# ── against the generated one ────────────────────────────────────────


def test_every_accent_the_module_offers_has_a_colour() -> None:
    """The one test that reads the real palette, when there is one.

    pkgs/accent.nix declares the names and the colours as two separate
    attributes, and modules/options.nix turns only the first into the enum.
    Nothing in Nix makes them agree; this is where a colour missing from one
    of them shows up, rather than as a settings app that quietly went back to
    a dropdown. It needs the files the dev shell builds, so outside it the
    test has nothing to compare against and says so.
    """
    generated = os.environ.get(paths.PALETTE_ENV)
    schema_path = os.environ.get(paths.SCHEMA_ENV)
    if not generated or not schema_path or not Path(generated).exists():
        pytest.skip("nothing generated — run this from `nix develop .#nano-settings`")

    with open(generated, encoding="utf-8") as handle:
        real = json.load(handle)
    with open(schema_path, encoding="utf-8") as handle:
        schema = Schema(json.load(handle))

    members = schema["accentColor"]["enum"] or []
    missing = [name for name in members if name not in real]
    assert not missing, f"accentColor offers accents pkgs/accent.nix has no colour for: {missing}"

    # And the suite's own copies are the same palette and the same nine, so
    # that everything else here is testing against what ships.
    assert real == PALETTE
    suite = SCHEMA_TREE["accentColor"]
    assert isinstance(suite, dict)
    assert members == suite["enum"]
