"""Schema plus presentation, rendered as libadwaita preference rows.

One widget per option type, chosen from schema.json rather than from
anything written here — so an option that changes from a bool to an enum
over in modules/options.nix changes shape in the GUI on the next rebuild
with no edit on this side.
"""

from __future__ import annotations

from typing import Final

from gi.repository import Adw, Gtk

from . import presentation
from .datatypes import OnChange, SchemaEntry, SettingValue
from .settings import Schema, Settings, format_value

# Enum members read as identifiers because that is what they are in the Nix
# file. Where a plainer wording exists it is used on the row; the identifier
# is what gets written, and the detail dialog still shows it.
ENUM_LABELS: Final[dict[str, dict[str, str]]] = {
    "hardwareVideo": {
        "auto": "Detect automatically",
        "intel-modern": "Intel, 2014 and newer",
        "intel-legacy": "Intel, 2013 and older",
        "none": "None",
    },
    "officeSuite": {
        "libreoffice": "LibreOffice",
        "gnome": "AbiWord and Gnumeric",
        "none": "None",
    },
    "compressionLevel": {
        "fast": "Fast (zstd 1)",
        "balanced": "Balanced (zstd 6)",
        "max": "Maximum (zstd 12)",
    },
    "energyPerfBias": {"balanced": "Balanced", "performance": "Performance"},
    "firmwareProfile": {"laptop": "Laptop", "full": "Everything"},
    "diskType": {"ssd": "Solid state", "hdd": "Hard disk"},
    "bootMode": {"uefi": "UEFI", "legacy": "Legacy BIOS"},
}

# Anything wider than a switch or a dropdown. All of them are Adw rows that
# take suffixes, which is the one thing this module needs of them.
OptionWidget = Adw.ActionRow | Adw.EntryRow


def enum_label(key: str, value: str) -> str:
    return ENUM_LABELS.get(key.split(".")[-1], {}).get(value, value)


class OptionRow:
    """One setting: its widget, and the bookkeeping that keeps it in sync."""

    def __init__(
        self,
        spec: presentation.Row,
        schema_entry: SchemaEntry,
        settings: Settings,
        on_change: OnChange,
    ) -> None:
        self.spec = spec
        self.entry = schema_entry
        self.settings = settings
        self.on_change = on_change
        self._updating = False
        # Set by whichever builder runs: the combo needs its members to map
        # a selected index back to a value, the frozen row needs somewhere
        # to redraw. Declared here so neither is a surprise attribute.
        self.values: list[str] = []
        self.value_label: Gtk.Label | None = None

        self.changed_icon = Gtk.Image.new_from_icon_name("document-edit-symbolic")
        self.changed_icon.set_tooltip_text("Changed, not yet applied")
        self.changed_icon.add_css_class("accent")

        self.widget: OptionWidget = self._build()
        self._add_suffixes()
        self.refresh()

    # ── construction ─────────────────────────────────────────────────

    def _build(self) -> OptionWidget:
        if self.spec.frozen:
            return self._build_frozen()
        kind = self.entry["type"]
        if kind == "bool":
            return self._build_switch()
        if kind == "enum":
            return self._build_combo()
        if kind in ("int", "unsignedInt", "ints.unsigned"):
            return self._build_spin()
        return self._build_entry()

    def _row_base[RowT: Adw.ActionRow](self, row: RowT) -> RowT:
        row.set_title(self.spec.title)
        if self.spec.subtitle:
            row.set_subtitle(self.spec.subtitle)
        return row

    def _build_frozen(self) -> Adw.ActionRow:
        row = self._row_base(Adw.ActionRow())
        value = self.settings.effective(self.spec.key)
        if self.entry["type"] == "enum" and isinstance(value, str):
            label = enum_label(self.spec.key, value)
        else:
            label = format_value(value)
        self.value_label = Gtk.Label(label=label)
        self.value_label.add_css_class("dim-label")
        row.add_suffix(self.value_label)
        return row

    def _build_switch(self) -> Adw.SwitchRow:
        row = self._row_base(Adw.SwitchRow())
        row.connect("notify::active", self._on_switch)
        return row

    def _build_combo(self) -> Adw.ComboRow:
        row = self._row_base(Adw.ComboRow())
        self.values = list(self.entry["enum"] or [])
        row.set_model(Gtk.StringList.new([enum_label(self.spec.key, v) for v in self.values]))
        row.connect("notify::selected", self._on_combo)
        return row

    def _build_spin(self) -> Adw.SpinRow:
        row = self._row_base(Adw.SpinRow())
        row.set_adjustment(Gtk.Adjustment(lower=0, upper=1024, step_increment=1, page_increment=8))
        row.connect("notify::value", self._on_spin)
        return row

    def _build_entry(self) -> Adw.EntryRow:
        row = Adw.EntryRow()
        row.set_title(self.spec.title)
        # EntryRow has no subtitle; the text is the value, so the one-liner
        # goes where it still reads as guidance rather than as content.
        if self.spec.subtitle:
            row.set_tooltip_text(self.spec.subtitle)
        row.connect("changed", self._on_entry)
        return row

    def _add_suffixes(self) -> None:
        self.widget.add_suffix(self.changed_icon)
        if self.entry["description"]:
            button = Gtk.Button.new_from_icon_name("help-about-symbolic")
            button.set_valign(Gtk.Align.CENTER)
            button.add_css_class("flat")
            button.set_tooltip_text("Why this setting exists")
            button.connect("clicked", self._show_detail)
            self.widget.add_suffix(button)

    # ── syncing ──────────────────────────────────────────────────────

    def refresh(self) -> None:
        """Push the model's value into the widget without echoing back."""
        self._updating = True
        try:
            value = self.settings.effective(self.spec.key)
            if self.spec.frozen:
                pass
            elif isinstance(self.widget, Adw.SwitchRow):
                self.widget.set_active(bool(value))
            elif isinstance(self.widget, Adw.ComboRow):
                if isinstance(value, str) and value in self.values:
                    self.widget.set_selected(self.values.index(value))
            elif isinstance(self.widget, Adw.SpinRow):
                self.widget.set_value(float(value) if isinstance(value, (int, float)) else 0.0)
            # No else: a row that is not frozen is one of these four, because
            # _build made it one of these four.
            elif isinstance(self.widget, Adw.EntryRow):  # pragma: no branch
                text = "" if value is None else str(value)
                if self.widget.get_text() != text:
                    self.widget.set_text(text)
        finally:
            self._updating = False
        self.changed_icon.set_visible(self.spec.key in self.settings.pending)

    def _commit(self, value: SettingValue) -> None:
        if self._updating:
            return
        self.settings.set(self.spec.key, value)
        self.changed_icon.set_visible(self.spec.key in self.settings.pending)
        self.on_change()

    def _on_switch(self, row: Adw.SwitchRow, _param: object) -> None:
        self._commit(row.get_active())

    def _on_combo(self, row: Adw.ComboRow, _param: object) -> None:
        index = row.get_selected()
        if 0 <= index < len(self.values):
            self._commit(self.values[index])

    def _on_spin(self, row: Adw.SpinRow, _param: object) -> None:
        self._commit(int(row.get_value()))

    def _on_entry(self, row: Adw.EntryRow) -> None:
        self._commit(row.get_text())

    # ── detail ───────────────────────────────────────────────────────

    def _show_detail(self, button: Gtk.Button) -> None:
        body = self.entry["description"].strip()
        default = format_value(self.entry["default"])
        dialog = Adw.AlertDialog.new(self.spec.title, None)
        dialog.set_heading(f"nanoDesktop.{self.spec.key}")
        dialog.set_body(f"{body}\n\nDefault: {default}")
        dialog.add_response("close", "Close")
        dialog.present(button)


def build_page(
    page: presentation.Page,
    schema: Schema,
    settings: Settings,
    on_change: OnChange,
) -> tuple[Adw.PreferencesPage, list[OptionRow]]:
    """An Adw.PreferencesPage for one presentation.Page, and its rows."""
    view = Adw.PreferencesPage()
    view.set_title(page.title)
    view.set_icon_name(page.icon)
    rows: list[OptionRow] = []

    for group in page.groups:
        adw_group = Adw.PreferencesGroup()
        adw_group.set_title(group.title)
        if group.description:
            adw_group.set_description(group.description)
        populated = False
        for spec in group.rows:
            if spec.key not in schema:
                # An option the running system does not have. Skipped rather
                # than shown as broken: the schema is generated from the
                # module this app was built with, so this only happens to a
                # checkout mid-edit.
                continue
            row = OptionRow(spec, schema[spec.key], settings, on_change)
            adw_group.add(row.widget)
            rows.append(row)
            populated = True
        if populated:
            view.add(adw_group)

    return view, rows
