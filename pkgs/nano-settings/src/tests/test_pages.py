"""One widget per option type, and the two-way sync behind each of them."""

from __future__ import annotations

import pytest
from gi.repository import Adw, Gtk

from nano_settings import pages, presentation
from nano_settings.settings import Schema, Settings


def build(
    schema: Schema,
    settings: Settings,
    spec: presentation.Row,
    changes: list[None] | None = None,
) -> pages.OptionRow:
    record = changes if changes is not None else []
    return pages.OptionRow(spec, schema[spec.key], settings, lambda: record.append(None))


# ── which widget ─────────────────────────────────────────────────────


@pytest.mark.parametrize(
    ("key", "widget"),
    [
        ("features.printing", Adw.SwitchRow),
        ("compressionLevel", Adw.ComboRow),
        ("swapSizeGiB", Adw.SpinRow),
        ("hostName", Adw.EntryRow),
    ],
)
def test_the_widget_comes_from_the_schema_not_from_presentation(
    schema: Schema, settings: Settings, key: str, widget: type[Adw.PreferencesRow]
) -> None:
    row = build(schema, settings, presentation.Row(key, "Title", "Subtitle"))
    assert isinstance(row.widget, widget)


def test_a_frozen_option_is_shown_as_a_label(schema: Schema, settings: Settings) -> None:
    row = build(schema, settings, presentation.Row("diskDevice", "Disk", frozen="As installed."))
    assert isinstance(row.widget, Adw.ActionRow)
    assert row.value_label is not None
    assert row.value_label.get_label() == "/dev/sda"


def test_a_frozen_enum_is_shown_by_its_plainer_wording(
    schema: Schema, settings: Settings
) -> None:
    row = build(schema, settings, presentation.Row("diskType", "Disk type", frozen="As installed."))
    assert row.value_label is not None
    assert row.value_label.get_label() == "Solid state"


def test_a_switch_carries_its_subtitle_and_an_entry_carries_a_tooltip(
    schema: Schema, settings: Settings
) -> None:
    switch = build(schema, settings, presentation.Row("features.printing", "Printing", "CUPS."))
    assert isinstance(switch.widget, Adw.SwitchRow)
    assert switch.widget.get_subtitle() == "CUPS."

    # EntryRow has no subtitle; the guidance has to go somewhere it does not
    # read as content.
    entry = build(schema, settings, presentation.Row("hostName", "Name", "On the network."))
    assert entry.widget.get_tooltip_text() == "On the network."


def test_an_entry_without_a_subtitle_gets_no_tooltip(
    schema: Schema, settings: Settings
) -> None:
    row = build(schema, settings, presentation.Row("hostName", "Name"))
    assert row.widget.get_tooltip_text() is None


# ── the help button ──────────────────────────────────────────────────


def test_an_option_with_a_description_offers_it(
    schema: Schema, settings: Settings, host: Adw.Window
) -> None:
    row = build(schema, settings, presentation.Row("hostName", "Computer name"))
    buttons = [
        child
        for child in _suffixes(row.widget)
        if isinstance(child, Gtk.Button) and child.get_tooltip_text() == "Why this setting exists"
    ]
    assert len(buttons) == 1

    host.set_content(row.widget)
    buttons[0].emit("clicked")


def test_an_option_with_no_description_offers_no_button(
    schema: Schema, settings: Settings
) -> None:
    row = build(schema, settings, presentation.Row("disableLogging", "Logging"))
    assert not [
        child
        for child in _suffixes(row.widget)
        if isinstance(child, Gtk.Button) and child.get_tooltip_text() == "Why this setting exists"
    ]


def _suffixes(widget: Gtk.Widget) -> list[Gtk.Widget]:
    """Every widget under a row, suffix box and all."""
    found: list[Gtk.Widget] = []
    child = widget.get_first_child()
    while child is not None:
        found.append(child)
        found.extend(_suffixes(child))
        child = child.get_next_sibling()
    return found


# ── editing ──────────────────────────────────────────────────────────


def test_a_switch_writes_a_bool_and_reports_the_change(
    schema: Schema, settings: Settings
) -> None:
    changes: list[None] = []
    row = build(schema, settings, presentation.Row("features.bluetooth", "Bluetooth"), changes)
    assert isinstance(row.widget, Adw.SwitchRow)

    row.widget.set_active(False)
    assert settings.pending == {"features.bluetooth": False}
    assert changes == [None]
    assert row.changed_icon.get_visible()


def test_a_combo_writes_the_identifier_not_the_label(
    schema: Schema, settings: Settings
) -> None:
    row = build(schema, settings, presentation.Row("compressionLevel", "Compression"))
    assert isinstance(row.widget, Adw.ComboRow)

    model = row.widget.get_model()
    assert isinstance(model, Gtk.StringList)
    assert [model.get_string(i) for i in range(model.get_n_items())] == [
        "Fast (zstd 1)",
        "Balanced (zstd 6)",
        "Maximum (zstd 12)",
    ]

    row.widget.set_selected(2)
    assert settings.pending == {"compressionLevel": "max"}


def test_an_enum_with_no_members_offers_nothing_and_writes_nothing() -> None:
    # An enum whose members schema.nix could not read: the row is built, but
    # an empty list model reports its selection as a position past the end,
    # which is not an index into anything.
    schema = Schema({"mystery": {"type": "enum", "default": None}})
    settings = Settings(schema, {})
    row = pages.OptionRow(
        presentation.Row("mystery", "Mystery"), schema["mystery"], settings, lambda: None
    )
    assert isinstance(row.widget, Adw.ComboRow)
    assert row.values == []

    row._on_combo(row.widget, None)

    assert settings.pending == {}


def test_a_spin_writes_an_integer(schema: Schema, settings: Settings) -> None:
    row = build(schema, settings, presentation.Row("swapSizeGiB", "Swap"))
    assert isinstance(row.widget, Adw.SpinRow)

    row.widget.set_value(16.0)
    assert settings.pending == {"swapSizeGiB": 16}


def test_an_entry_writes_its_text(schema: Schema, settings: Settings) -> None:
    row = build(schema, settings, presentation.Row("hostName", "Computer name"))
    assert isinstance(row.widget, Adw.EntryRow)

    row.widget.set_text("study")
    assert settings.pending == {"hostName": "study"}


def test_an_edit_back_to_the_applied_value_puts_the_marker_away(
    schema: Schema, settings: Settings
) -> None:
    row = build(schema, settings, presentation.Row("hostName", "Computer name"))
    assert isinstance(row.widget, Adw.EntryRow)

    row.widget.set_text("study")
    assert row.changed_icon.get_visible()
    row.widget.set_text("kitchen")
    assert not row.changed_icon.get_visible()
    assert not settings.dirty


# ── refreshing ───────────────────────────────────────────────────────


def test_building_a_row_shows_what_is_stored_without_reporting_an_edit(
    schema: Schema, settings: Settings
) -> None:
    changes: list[None] = []
    row = build(schema, settings, presentation.Row("features.printing", "Printing"), changes)
    assert isinstance(row.widget, Adw.SwitchRow)

    # The stored value is False against a default of True, so this is the
    # case where building the row moves the switch.
    assert row.widget.get_active() is False
    assert changes == []
    assert settings.pending == {}


def test_refresh_pushes_a_changed_model_back_into_every_widget(
    schema: Schema, settings: Settings
) -> None:
    rows = [
        build(schema, settings, presentation.Row(key, key))
        for key in ("features.printing", "compressionLevel", "swapSizeGiB", "hostName")
    ]
    settings.set("features.printing", True)
    settings.set("compressionLevel", "max")
    settings.set("swapSizeGiB", 2)
    settings.set("hostName", "study")

    for row in rows:
        row.refresh()

    switch, combo, spin, entry = rows
    assert isinstance(switch.widget, Adw.SwitchRow) and switch.widget.get_active()
    assert isinstance(combo.widget, Adw.ComboRow) and combo.widget.get_selected() == 2
    assert isinstance(spin.widget, Adw.SpinRow) and spin.widget.get_value() == 2.0
    assert isinstance(entry.widget, Adw.EntryRow) and entry.widget.get_text() == "study"
    assert all(row.changed_icon.get_visible() for row in rows)


def test_refresh_does_not_report_the_edits_it_is_displaying(
    schema: Schema, settings: Settings
) -> None:
    changes: list[None] = []
    row = build(schema, settings, presentation.Row("features.printing", "Printing"), changes)
    settings.set("features.printing", True)
    changes.clear()

    row.refresh()
    assert changes == []


def test_a_frozen_row_ignores_refresh(schema: Schema, settings: Settings) -> None:
    row = build(schema, settings, presentation.Row("diskDevice", "Disk", frozen="As installed."))
    settings.set("diskDevice", "/dev/nvme0n1")
    row.refresh()

    assert row.value_label is not None
    assert row.value_label.get_label() == "/dev/sda"


def test_a_stored_value_outside_the_enum_leaves_the_combo_alone(
    schema: Schema, settings: Settings
) -> None:
    # Hand-edited /etc/nixos, or an enum member that went away in an update.
    settings.stored["compressionLevel"] = "extreme"
    row = build(schema, settings, presentation.Row("compressionLevel", "Compression"))
    assert isinstance(row.widget, Adw.ComboRow)
    assert row.widget.get_selected() == 0


def test_a_spin_given_something_that_is_not_a_number_shows_zero(
    schema: Schema, settings: Settings
) -> None:
    settings.stored["swapSizeGiB"] = None
    row = build(schema, settings, presentation.Row("swapSizeGiB", "Swap"))
    assert isinstance(row.widget, Adw.SpinRow)
    assert row.widget.get_value() == 0.0


def test_an_entry_given_null_shows_an_empty_box(schema: Schema, settings: Settings) -> None:
    settings.stored["hostName"] = None
    row = build(schema, settings, presentation.Row("hostName", "Computer name"))
    assert isinstance(row.widget, Adw.EntryRow)
    assert row.widget.get_text() == ""


def test_an_entry_already_showing_the_value_is_not_rewritten(
    schema: Schema, settings: Settings
) -> None:
    # Rewriting it would move the cursor to the end mid-typing.
    row = build(schema, settings, presentation.Row("hostName", "Computer name"))
    assert isinstance(row.widget, Adw.EntryRow)
    row.widget.set_position(2)
    row.refresh()
    assert row.widget.get_position() == 2


# ── labels ───────────────────────────────────────────────────────────


def test_enum_labels_are_by_the_last_part_of_the_key() -> None:
    assert pages.enum_label("compressionLevel", "fast") == "Fast (zstd 1)"
    assert pages.enum_label("nested.compressionLevel", "fast") == "Fast (zstd 1)"


def test_an_enum_member_with_no_plainer_wording_is_shown_as_it_is() -> None:
    assert pages.enum_label("compressionLevel", "extreme") == "extreme"
    assert pages.enum_label("hostName", "kitchen") == "kitchen"


# ── whole pages ──────────────────────────────────────────────────────


def test_build_page_makes_a_row_for_every_known_option(
    schema: Schema, settings: Settings
) -> None:
    page = presentation.Page(
        ident="test",
        title="Test",
        icon="preferences-system-symbolic",
        groups=[
            presentation.Group(
                title="Group",
                description="Why these are together.",
                rows=[
                    presentation.Row("hostName", "Computer name"),
                    presentation.Row("features.printing", "Printing"),
                ],
            )
        ],
    )
    view, rows = build_page_for(page, schema, settings)

    assert view.get_title() == "Test"
    assert [row.spec.key for row in rows] == ["hostName", "features.printing"]


def test_build_page_skips_options_this_system_does_not_have(
    schema: Schema, settings: Settings
) -> None:
    page = presentation.Page(
        ident="test",
        title="Test",
        icon="preferences-system-symbolic",
        groups=[
            presentation.Group(
                title="Half known",
                rows=[
                    presentation.Row("hostName", "Computer name"),
                    presentation.Row("optionFromTheFuture", "Not here yet"),
                ],
            ),
            presentation.Group(
                title="None known",
                rows=[presentation.Row("alsoNotHere", "Nor this")],
            ),
        ],
    )
    view, rows = build_page_for(page, schema, settings)

    assert [row.spec.key for row in rows] == ["hostName"]
    # A group with nothing left in it is not added at all, rather than shown
    # as an empty heading.
    assert _titles(view) == ["Half known"]


def build_page_for(
    page: presentation.Page, schema: Schema, settings: Settings
) -> tuple[Adw.PreferencesPage, list[pages.OptionRow]]:
    return pages.build_page(page, schema, settings, lambda: None)


def _titles(view: Adw.PreferencesPage) -> list[str]:
    return [
        child.get_title()
        for child in _suffixes(view)
        if isinstance(child, Adw.PreferencesGroup) and child.get_title()
    ]


def test_the_real_pages_all_build(schema: Schema, settings: Settings) -> None:
    for page in presentation.PAGES:
        if page.custom:
            continue
        view, rows = build_page_for(page, schema, settings)
        assert rows, page.ident
        assert view.get_icon_name() == page.icon
