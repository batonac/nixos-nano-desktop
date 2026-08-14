"""The narrowing at the boundary: what each malformed shape turns into."""

from __future__ import annotations

import pytest

from nano_settings.datatypes import (
    MalformedError,
    narrow_catalog_item,
    narrow_schema_entry,
)


def test_schema_entry_keeps_every_field() -> None:
    entry = narrow_schema_entry(
        "hostName",
        {
            "type": "enum",
            "elemType": None,
            "enum": ["a", "b"],
            "default": "a",
            "description": "Which one.",
        },
    )
    assert entry["type"] == "enum"
    assert entry["enum"] == ["a", "b"]
    assert entry["default"] == "a"
    assert entry["description"] == "Which one."
    assert entry["elemType"] is None


def test_schema_entry_fills_in_a_missing_description() -> None:
    # Absent and non-string both mean "nothing to show behind the help
    # button", which the row renders by not offering one.
    assert narrow_schema_entry("k", {"type": "bool"})["description"] == ""
    assert narrow_schema_entry("k", {"type": "bool", "description": 7})["description"] == ""


def test_schema_entry_keeps_a_list_element_type() -> None:
    entry = narrow_schema_entry("k", {"type": "list", "elemType": "str"})
    assert entry["elemType"] == "str"


def test_schema_entry_defaults_to_null_when_options_nix_declared_none() -> None:
    assert narrow_schema_entry("k", {"type": "str"})["default"] is None


@pytest.mark.parametrize(
    ("raw", "complaint"),
    [
        ("not an object", "is not an object"),
        ({"default": 1}, "has no option type"),
        ({"type": 3}, "has no option type"),
        ({"type": "list", "elemType": 3}, "list element type"),
        ({"type": "enum", "enum": "fast"}, "enum values"),
        ({"type": "enum", "enum": ["fast", 2]}, "enum values"),
    ],
)
def test_schema_entry_says_which_option_is_wrong(raw: object, complaint: str) -> None:
    with pytest.raises(MalformedError) as caught:
        narrow_schema_entry("compressionLevel", raw)  # type: ignore[arg-type]
    assert "compressionLevel" in str(caught.value)
    assert complaint in str(caught.value)


def test_catalog_item_fills_in_what_the_file_leaves_out() -> None:
    item = narrow_catalog_item({"attr": "vlc", "name": "VLC"})
    assert item == {
        "attr": "vlc",
        "name": "VLC",
        "category": "Other",
        "summary": "",
        "unfree": False,
    }


def test_catalog_item_keeps_what_the_file_gives() -> None:
    item = narrow_catalog_item(
        {
            "attr": "steam",
            "name": "Steam",
            "category": "Games",
            "summary": "Valve's launcher",
            "unfree": True,
        }
    )
    assert item is not None
    assert item["category"] == "Games"
    assert item["unfree"] is True


def test_catalog_item_reads_unfree_as_a_flag_not_as_truthiness() -> None:
    # A string in that field is a mistake in the catalogue, and calling the
    # package unfree on the strength of it would be the worse guess.
    item = narrow_catalog_item({"attr": "a", "name": "A", "unfree": "yes"})
    assert item is not None
    assert item["unfree"] is False


@pytest.mark.parametrize(
    "raw",
    [
        "gimp",
        ["gimp"],
        {},
        {"attr": "gimp"},
        {"name": "GIMP"},
        {"attr": "", "name": "GIMP"},
        {"attr": "gimp", "name": ""},
        {"attr": 1, "name": "GIMP"},
        {"attr": "gimp", "name": 1},
    ],
)
def test_catalog_item_drops_what_it_cannot_read(raw: object) -> None:
    assert narrow_catalog_item(raw) is None  # type: ignore[arg-type]


def test_summary_that_is_not_a_string_is_dropped_rather_than_shown() -> None:
    item = narrow_catalog_item({"attr": "a", "name": "A", "summary": 12, "category": 12})
    assert item is not None
    assert item["summary"] == ""
    assert item["category"] == "Other"
