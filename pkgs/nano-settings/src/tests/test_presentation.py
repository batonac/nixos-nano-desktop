"""The curated half, and whether it still matches the generated half."""

from __future__ import annotations

import json
import os
from pathlib import Path

import pytest

from conftest import SCHEMA_TREE
from nano_settings import presentation
from nano_settings.settings import Schema


def test_every_page_is_either_generated_or_custom() -> None:
    for page in presentation.PAGES:
        assert bool(page.groups) != bool(page.custom), page.ident


def test_page_identifiers_are_unique() -> None:
    idents = [page.ident for page in presentation.PAGES]
    assert len(idents) == len(set(idents))


def test_custom_pages_are_the_ones_the_window_knows_how_to_build() -> None:
    # window.py dispatches on this string; a new one added here without the
    # matching branch there would silently produce an empty page.
    customs = {page.custom for page in presentation.PAGES if page.custom}
    assert customs == {"software", "account", "updates"}


def test_no_option_is_offered_on_two_pages() -> None:
    keys = [row.key for page in presentation.PAGES for group in page.groups for row in group.rows]
    assert len(keys) == len(set(keys))


def test_rows_by_key_finds_every_row() -> None:
    rows = presentation.rows_by_key()
    assert rows["features.printing"].title == "Printing"
    assert rows["hostName"].subtitle
    assert len(rows) == sum(len(group.rows) for page in presentation.PAGES for group in page.groups)


def test_frozen_rows_say_why_they_are_frozen() -> None:
    frozen = [
        row
        for page in presentation.PAGES
        for group in page.groups
        for row in group.rows
        if row.frozen
    ]
    assert {row.key for row in frozen} == {
        "username",
        "stateVersion",
        "diskDevice",
        "diskType",
        "swapSizeGiB",
        "bootMode",
    }
    assert all(row.frozen.strip() for row in frozen)


def test_every_row_names_an_option_the_test_schema_has() -> None:
    # The suite's own schema stands in for the generated one everywhere else,
    # so it is worth knowing that it covers what the pages actually ask for.
    schema = Schema(json.loads(json.dumps(SCHEMA_TREE)))
    for key in presentation.rows_by_key():
        assert key in schema, key


def test_every_row_names_an_option_the_module_declares() -> None:
    """The one test that reads the real schema, when there is one.

    presentation.py names options by string, and nothing in Python fails if
    modules/options.nix renames one — the row is simply skipped, which is
    right for a checkout mid-edit and wrong for a release. This is where that
    shows up. It needs the schema the dev shell builds, so outside it the
    test has nothing to compare against and says so.
    """
    generated = os.environ.get("NANO_SETTINGS_SCHEMA")
    if not generated or not Path(generated).exists():
        pytest.skip("no generated schema.json — run this from `nix develop .#nano-settings`")

    with open(generated, encoding="utf-8") as handle:
        schema = Schema(json.load(handle))

    missing = [key for key in presentation.rows_by_key() if key not in schema]
    assert not missing, f"presentation.py names options modules/options.nix does not: {missing}"
