"""One widget per option type, and the two-way sync behind each of them."""

from __future__ import annotations

from typing import cast

import pytest
from gi.repository import Adw, Gdk, Gio, GLib, Gtk

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


# ── colours ──────────────────────────────────────────────────────────


def colour_row(
    schema: Schema, settings: Settings, changes: list[None] | None = None
) -> pages.OptionRow:
    spec = presentation.Row("backgroundColor", "Background colour", picker="color")
    return build(schema, settings, spec, changes)


def test_a_colour_gets_a_colour_button_rather_than_a_text_box(
    schema: Schema, settings: Settings
) -> None:
    # The schema says this is a string, and it is right; which kind of
    # string it is comes from presentation.py.
    row = colour_row(schema, settings)
    assert isinstance(row.widget, Adw.ActionRow)
    assert row.color_button.get_rgba().to_string() == Gdk.RGBA(
        red=0x1C / 255, green=0x1C / 255, blue=0x1F / 255, alpha=1.0
    ).to_string()


def test_choosing_a_colour_writes_it_as_six_hex_digits(
    schema: Schema, settings: Settings
) -> None:
    changes: list[None] = []
    row = colour_row(schema, settings, changes)

    chosen = Gdk.RGBA()
    assert chosen.parse("#e62d42")
    row.color_button.set_rgba(chosen)

    assert settings.pending == {"backgroundColor": "#e62d42"}
    assert changes == [None]


def test_a_colour_is_rounded_to_the_nearest_channel_rather_than_truncated(
    schema: Schema, settings: Settings
) -> None:
    # Gdk keeps channels as floats; 0.5 is 128, not 127.
    row = colour_row(schema, settings)
    row.color_button.set_rgba(Gdk.RGBA(red=0.5, green=1.0, blue=0.0, alpha=1.0))
    assert settings.pending == {"backgroundColor": "#80ff00"}


def test_transparency_is_dropped_rather_than_written_out(
    schema: Schema, settings: Settings
) -> None:
    # Nothing downstream of the settings file can honour it: not swaybg's
    # --color, not the GTK3 theme's @define-color.
    row = colour_row(schema, settings)
    row.color_button.set_rgba(Gdk.RGBA(red=1.0, green=0.0, blue=0.0, alpha=0.25))
    assert settings.pending == {"backgroundColor": "#ff0000"}


def test_refresh_moves_the_colour_button_to_the_stored_colour(
    schema: Schema, settings: Settings
) -> None:
    row = colour_row(schema, settings)
    settings.set("backgroundColor", "#3a944a")

    row.refresh()

    assert _hex_of(row.color_button.get_rgba()) == "#3a944a"
    assert row.changed_icon.get_visible()


def test_something_that_is_not_a_colour_shows_as_black(
    schema: Schema, settings: Settings
) -> None:
    # /etc/nixos is editable by hand. Visibly wrong, and one click from
    # right, beats a widget that refuses to be built.
    settings.stored["backgroundColor"] = "chartreuse-ish"
    row = colour_row(schema, settings)
    assert _hex_of(row.color_button.get_rgba()) == "#000000"
    assert not settings.dirty


def test_a_colour_that_is_not_even_a_string_shows_as_black(
    schema: Schema, settings: Settings
) -> None:
    settings.stored["backgroundColor"] = 17
    row = colour_row(schema, settings)
    assert _hex_of(row.color_button.get_rgba()) == "#000000"


def _hex_of(colour: Gdk.RGBA) -> str:
    red, green, blue = (round(part * 255) for part in (colour.red, colour.green, colour.blue))
    return f"#{red:02x}{green:02x}{blue:02x}"


# ── images ───────────────────────────────────────────────────────────


def image_row(
    schema: Schema,
    settings: Settings,
    changes: list[None] | None = None,
    subtitle: str = "Fills the screen.",
) -> pages.OptionRow:
    spec = presentation.Row("backgroundImage", "Background image", subtitle, picker="image")
    return build(schema, settings, spec, changes)


def test_no_image_says_so_and_offers_nothing_to_clear(
    schema: Schema, settings: Settings
) -> None:
    row = image_row(schema, settings)
    assert row.image_row.get_subtitle() == "None"
    assert not row.clear_button.get_sensitive()
    # The guidance goes to the tooltip, because the subtitle is the path.
    assert row.widget.get_tooltip_text() == "Fills the screen."


def test_an_image_row_without_guidance_gets_no_tooltip(
    schema: Schema, settings: Settings
) -> None:
    row = image_row(schema, settings, subtitle="")
    assert row.widget.get_tooltip_text() is None


def test_an_image_is_shown_by_its_path(schema: Schema, settings: Settings) -> None:
    settings.stored["backgroundImage"] = "/home/batonac/Pictures/hill.jpg"
    row = image_row(schema, settings)
    assert row.image_row.get_subtitle() == "/home/batonac/Pictures/hill.jpg"
    assert row.clear_button.get_sensitive()


def test_clearing_an_image_goes_back_to_the_colour(
    schema: Schema, settings: Settings
) -> None:
    settings.stored["backgroundImage"] = "/home/batonac/Pictures/hill.jpg"
    changes: list[None] = []
    row = image_row(schema, settings, changes)

    row.clear_button.emit("clicked")

    assert settings.pending == {"backgroundImage": ""}
    assert changes == [None]
    row.refresh()
    assert row.image_row.get_subtitle() == "None"
    assert not row.clear_button.get_sensitive()


def test_choosing_opens_a_file_dialog_on_the_window_the_row_is_in(
    schema: Schema, settings: Settings, host: Adw.Window, monkeypatch: pytest.MonkeyPatch
) -> None:
    opened: list[Gtk.Window | None] = []
    monkeypatch.setattr(
        Gtk.FileDialog,
        "open",
        lambda _dialog, parent, _cancellable, _callback: opened.append(parent),
    )
    row = image_row(schema, settings)
    host.set_content(row.widget)

    _choose_button(row).emit("clicked")

    assert opened == [host]


def test_choosing_from_a_row_that_is_in_no_window_still_opens(
    schema: Schema, settings: Settings, monkeypatch: pytest.MonkeyPatch
) -> None:
    opened: list[Gtk.Window | None] = []
    monkeypatch.setattr(
        Gtk.FileDialog,
        "open",
        lambda _dialog, parent, _cancellable, _callback: opened.append(parent),
    )
    row = image_row(schema, settings)

    _choose_button(row).emit("clicked")

    assert opened == [None]


def _choose_button(row: pages.OptionRow) -> Gtk.Button:
    return next(
        child
        for child in _suffixes(row.widget)
        if isinstance(child, Gtk.Button) and child.get_label() == "Choose…"
    )


class _Chose:
    """A file dialog that was answered with this file."""

    def __init__(self, path: str | None) -> None:
        self._file = Gio.File.new_for_path(path) if path is not None else None

    def open_finish(self, _result: Gio.AsyncResult) -> Gio.File | None:
        return self._file


class _Dismissed:
    """A file dialog that was closed without choosing anything."""

    def open_finish(self, _result: Gio.AsyncResult) -> Gio.File:
        raise GLib.Error("dismissed")


def test_the_chosen_file_becomes_the_background(schema: Schema, settings: Settings) -> None:
    row = image_row(schema, settings)

    row._on_image_chosen(
        cast(Gtk.FileDialog, _Chose("/home/batonac/Pictures/hill.jpg")),
        cast(Gio.AsyncResult, None),
    )

    assert settings.pending == {"backgroundImage": "/home/batonac/Pictures/hill.jpg"}
    row.refresh()
    assert row.image_row.get_subtitle() == "/home/batonac/Pictures/hill.jpg"


def test_dismissing_the_dialog_changes_nothing(schema: Schema, settings: Settings) -> None:
    row = image_row(schema, settings)

    row._on_image_chosen(cast(Gtk.FileDialog, _Dismissed()), cast(Gio.AsyncResult, None))

    assert not settings.dirty


@pytest.mark.parametrize("chosen", [None, "recent:///"])
def test_something_without_a_path_of_its_own_is_not_a_background(
    schema: Schema, settings: Settings, chosen: str | None
) -> None:
    # swaybg opens a path, so a file the session can only name by URI is
    # not one this can accept.
    row = image_row(schema, settings)
    dialog = _Chose(None) if chosen is None else _Uri(chosen)

    row._on_image_chosen(cast(Gtk.FileDialog, dialog), cast(Gio.AsyncResult, None))

    assert not settings.dirty


class _Uri:
    def __init__(self, uri: str) -> None:
        self._file = Gio.File.new_for_uri(uri)

    def open_finish(self, _result: Gio.AsyncResult) -> Gio.File:
        return self._file


# ── labels ───────────────────────────────────────────────────────────


def test_enum_labels_are_by_the_last_part_of_the_key() -> None:
    assert pages.enum_label("compressionLevel", "fast") == "Fast (zstd 1)"
    assert pages.enum_label("nested.compressionLevel", "fast") == "Fast (zstd 1)"


def test_an_enum_member_with_no_plainer_wording_is_shown_as_it_is() -> None:
    assert pages.enum_label("compressionLevel", "extreme") == "extreme"
    assert pages.enum_label("hostName", "kitchen") == "kitchen"


def test_the_accents_are_offered_in_gnome_s_order_rather_than_the_alphabet(
    schema: Schema, settings: Settings
) -> None:
    row = build(schema, settings, presentation.Row("accentColor", "Accent colour"))
    assert isinstance(row.widget, Adw.ComboRow)
    model = row.widget.get_model()
    assert isinstance(model, Gtk.StringList)
    assert [model.get_string(i) for i in range(model.get_n_items())] == [
        "Blue",
        "Teal",
        "Green",
        "Yellow",
        "Orange",
        "Red",
        "Pink",
        "Purple",
        "Slate",
    ]

    row.widget.set_selected(5)
    assert settings.pending == {"accentColor": "red"}


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
