"""The model: what the schema says, what the file says, and what wins."""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from nano_settings import paths
from nano_settings.datatypes import MalformedError
from nano_settings.settings import (
    MISSING,
    Schema,
    Settings,
    SettingsError,
    format_value,
)

# ── the schema ───────────────────────────────────────────────────────


def test_schema_flattens_groups_to_dotted_keys(schema: Schema) -> None:
    assert "hostName" in schema
    assert "features.printing" in schema
    # The group itself is not an option, and must not be offered as one.
    assert "features" not in schema
    assert "features.nonesuch" not in schema


def test_schema_exposes_types_defaults_and_enum_members(schema: Schema) -> None:
    assert schema["hostName"]["type"] == "str"
    assert schema.default("hostName") == "nano-desktop"
    assert schema["compressionLevel"]["enum"] == ["fast", "balanced", "max"]
    assert set(schema.keys()) >= {"hostName", "features.autoUpgrade"}


def test_schema_loads_the_file_paths_names(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    path = tmp_path / "schema.json"
    path.write_text(json.dumps({"hostName": {"type": "str", "default": "box"}}))
    monkeypatch.setattr(paths, "SCHEMA", path)

    loaded = Schema.load()
    assert loaded.default("hostName") == "box"


def test_a_schema_that_is_not_an_object_is_refused(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    path = tmp_path / "schema.json"
    path.write_text("[]")
    monkeypatch.setattr(paths, "SCHEMA", path)

    with pytest.raises(MalformedError, match="does not contain a JSON object"):
        Schema.load()


def test_a_schema_node_that_is_neither_option_nor_group_is_refused() -> None:
    with pytest.raises(MalformedError, match=r"features\.printing"):
        Schema({"features": {"printing": "yes"}})


# ── reading ──────────────────────────────────────────────────────────


def test_stored_beats_default(settings: Settings) -> None:
    assert settings.applied("hostName") == "kitchen"
    assert settings.applied("timeZone") == "America/New_York"


def test_a_nested_key_is_read_through_the_group(settings: Settings) -> None:
    assert settings.applied("features.printing") is False
    assert settings.applied("features.scanning") is True


def test_missing_is_not_the_same_as_null(schema: Schema) -> None:
    stored = Settings(schema, {"hostName": None})
    assert stored.stored_value("hostName") is None
    assert stored.stored_value("timeZone") is MISSING
    assert stored.is_stored("hostName")
    assert not stored.is_stored("timeZone")


def test_a_key_whose_parent_is_not_a_group_is_simply_not_stored(schema: Schema) -> None:
    # /etc/nixos is editable by hand, so "features" can be anything at all.
    stored = Settings(schema, {"features": "everything"})
    assert stored.stored_value("features.printing") is MISSING
    assert stored.applied("features.printing") is True


def test_pending_beats_stored(settings: Settings) -> None:
    settings.set("hostName", "study")
    assert settings.effective("hostName") == "study"
    # ...but only in the GUI. Nothing has been applied.
    assert settings.applied("hostName") == "kitchen"


# ── writing ──────────────────────────────────────────────────────────


def test_setting_a_value_back_to_what_is_applied_clears_the_edit(settings: Settings) -> None:
    settings.set("hostName", "study")
    assert settings.pending == {"hostName": "study"}
    settings.set("hostName", "kitchen")
    assert not settings.dirty
    assert settings.pending == {}


def test_setting_a_value_back_to_the_default_of_an_unstored_key(settings: Settings) -> None:
    settings.set("timeZone", "Europe/Paris")
    settings.set("timeZone", "America/New_York")
    assert not settings.dirty


def test_diff_is_sorted_and_pairs_old_with_new(settings: Settings) -> None:
    settings.set("timeZone", "Europe/Paris")
    settings.set("hostName", "study")
    assert settings.diff() == [
        ("hostName", "kitchen", "study"),
        ("timeZone", "America/New_York", "Europe/Paris"),
    ]


def test_applying_an_edit_writes_it_into_the_nested_shape(settings: Settings) -> None:
    settings.set("features.bluetooth", False)
    assert settings.to_json()["features"] == {"printing": False, "bluetooth": False}


def test_a_group_that_is_not_an_object_is_replaced_rather_than_indexed(schema: Schema) -> None:
    stored = Settings(schema, {"features": "everything"})
    stored.set("features.printing", False)
    assert stored.to_json()["features"] == {"printing": False}


def test_a_missing_group_is_created(schema: Schema) -> None:
    stored = Settings(schema, {})
    stored.set("features.printing", False)
    assert stored.to_json() == {"features": {"printing": False}}


def test_keys_this_app_does_not_know_about_survive_a_round_trip(schema: Schema) -> None:
    stored = Settings(schema, {"somethingNewer": [1, 2], "features": {"unknown": True}})
    stored.set("features.printing", False)
    result = stored.to_json()
    assert result["somethingNewer"] == [1, 2]
    assert result["features"] == {"unknown": True, "printing": False}


def test_editing_does_not_touch_what_was_loaded(settings: Settings) -> None:
    settings.set("features.bluetooth", False)
    settings.to_json()
    assert settings.stored["features"] == {"printing": False}


def test_serialize_is_sorted_indented_and_newline_terminated(settings: Settings) -> None:
    settings.set("timeZone", "Europe/Paris")
    text = settings.serialize()
    assert text.endswith("\n")
    assert json.loads(text)["timeZone"] == "Europe/Paris"
    assert text.index('"features"') < text.index('"hostName"')


def test_mark_applied_folds_the_edits_into_the_file(settings: Settings) -> None:
    settings.set("hostName", "study")
    settings.mark_applied()
    assert not settings.dirty
    assert settings.applied("hostName") == "study"
    assert settings.stored["hostName"] == "study"


# ── loading ──────────────────────────────────────────────────────────


def test_load_reads_the_settings_file(
    schema: Schema, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    path = tmp_path / "nanoDesktop-settings.json"
    path.write_text(json.dumps({"hostName": "loaded"}))
    monkeypatch.setattr(paths, "SETTINGS", path)

    assert Settings.load(schema).applied("hostName") == "loaded"


def test_a_machine_with_no_settings_file_is_a_machine_on_defaults(
    schema: Schema, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(paths, "SETTINGS", tmp_path / "nothing.json")

    loaded = Settings.load(schema)
    assert loaded.stored == {}
    assert loaded.applied("hostName") == "nano-desktop"


def test_a_settings_file_that_is_not_json_says_so(
    schema: Schema, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    path = tmp_path / "settings.json"
    path.write_text("{not json")
    monkeypatch.setattr(paths, "SETTINGS", path)

    with pytest.raises(SettingsError, match="could not be read"):
        Settings.load(schema)


def test_a_settings_file_that_cannot_be_opened_says_so(
    schema: Schema, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    # A directory where the file should be: OSError rather than
    # FileNotFoundError, which is the branch that must not be swallowed.
    monkeypatch.setattr(paths, "SETTINGS", tmp_path)

    with pytest.raises(SettingsError, match="could not be read"):
        Settings.load(schema)


def test_a_settings_file_holding_a_list_says_so(
    schema: Schema, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    path = tmp_path / "settings.json"
    path.write_text("[]")
    monkeypatch.setattr(paths, "SETTINGS", path)

    with pytest.raises(SettingsError, match="does not contain a JSON object"):
        Settings.load(schema)


# ── display ──────────────────────────────────────────────────────────


@pytest.mark.parametrize(
    ("value", "shown"),
    [
        (True, "on"),
        (False, "off"),
        (None, "(unset)"),
        ([], "(none)"),
        (["gimp", "htop"], "gimp, htop"),
        ([1, 2], "1, 2"),
        ("en_US.UTF-8", "en_US.UTF-8"),
        (8, "8"),
    ],
)
def test_format_value(value: object, shown: str) -> None:
    assert format_value(value) == shown  # type: ignore[arg-type]
