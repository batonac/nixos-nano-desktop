"""Where the application looks for things, and what may move it."""

from __future__ import annotations

import importlib
from pathlib import Path

import pytest

from nano_settings import paths


def test_the_data_files_sit_beside_the_package() -> None:
    assert paths.CATALOG.name == "catalog.json"
    assert paths.CATALOG.parent == Path(paths.__file__).resolve().parent.parent


def test_the_shipped_catalogue_is_there_and_is_a_catalogue() -> None:
    # It is installed by the derivation from this same directory, so a
    # checkout is as good a place to check it as the store.
    from nano_settings.software import load_catalog

    catalogue = load_catalog()
    assert len(catalogue) > 20
    assert all(item["attr"] and item["name"] for item in catalogue)
    assert len({item["attr"] for item in catalogue}) == len(catalogue)


def test_the_helper_is_named_through_the_system_profile() -> None:
    # Not a store path: the polkit action matches on this string, and a store
    # path there would stop matching whenever the helper's closure changed.
    assert str(paths.HELPER).startswith("/run/current-system/sw/bin/")


def test_the_polkit_agent_placeholder_is_left_for_the_derivation() -> None:
    # default.nix substitutes this with --replace-fail, which turns a rename
    # here into a build failure rather than an app that never asks for a
    # password. PolkitAgent.start() is what treats it as "no agent".
    assert paths.POLKIT_AGENT == "@polkitAgent@"


@pytest.mark.parametrize(
    ("variable", "attribute", "name"),
    [
        (paths.SCHEMA_ENV, "SCHEMA", "schema.json"),
        (paths.PALETTE_ENV, "PALETTE", "palette.json"),
    ],
)
def test_the_generated_files_are_found_beside_the_package_by_default(
    monkeypatch: pytest.MonkeyPatch, variable: str, attribute: str, name: str
) -> None:
    monkeypatch.delenv(variable, raising=False)
    reloaded = importlib.reload(paths)
    try:
        assert reloaded.CATALOG.parent / name == getattr(reloaded, attribute)
    finally:
        # Undone here rather than at teardown, because the module has to be
        # reloaded once more with the environment the rest of the suite is
        # expecting — reload is the only thing that re-reads it.
        monkeypatch.undo()
        importlib.reload(paths)


@pytest.mark.parametrize(
    ("variable", "attribute"),
    [(paths.SCHEMA_ENV, "SCHEMA"), (paths.PALETTE_ENV, "PALETTE")],
)
def test_the_dev_shell_may_point_the_generated_files_elsewhere(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path, variable: str, attribute: str
) -> None:
    monkeypatch.setenv(variable, str(tmp_path / "generated.json"))
    reloaded = importlib.reload(paths)
    try:
        assert tmp_path / "generated.json" == getattr(reloaded, attribute)
    finally:
        monkeypatch.undo()
        importlib.reload(paths)
