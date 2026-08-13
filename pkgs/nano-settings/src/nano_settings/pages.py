"""Schema plus presentation, rendered as libadwaita preference rows.

One widget per option type, chosen from schema.json rather than from
anything written here — so an option that changes from a bool to an enum
over in modules/options.nix changes shape in the GUI on the next rebuild
with no edit on this side.
"""

from gi.repository import Adw, Gtk

from . import presentation
from .settings import format_value

# Enum members read as identifiers because that is what they are in the Nix
# file. Where a plainer wording exists it is used on the row; the identifier
# is what gets written, and the detail dialog still shows it.
ENUM_LABELS = {
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


def enum_label(key, value):
    return ENUM_LABELS.get(key.split(".")[-1], {}).get(value, value)


class OptionRow:
    """One setting: its widget, and the bookkeeping that keeps it in sync."""

    def __init__(self, spec, schema_entry, settings, on_change):
        self.spec = spec
        self.entry = schema_entry
        self.settings = settings
        self.on_change = on_change
        self._updating = False

        self.changed_icon = Gtk.Image.new_from_icon_name("document-edit-symbolic")
        self.changed_icon.set_tooltip_text("Changed, not yet applied")
        self.changed_icon.add_css_class("accent")

        self.widget = self._build()
        self._add_suffixes()
        self.refresh()

    # ── construction ─────────────────────────────────────────────────

    def _build(self):
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

    def _row_base(self, row):
        row.set_title(self.spec.title)
        if self.spec.subtitle:
            row.set_subtitle(self.spec.subtitle)
        return row

    def _build_frozen(self):
        row = self._row_base(Adw.ActionRow())
        value = self.settings.effective(self.spec.key)
        label = enum_label(self.spec.key, value) if self.entry["type"] == "enum" else format_value(value)
        self.value_label = Gtk.Label(label=label)
        self.value_label.add_css_class("dim-label")
        row.add_suffix(self.value_label)
        return row

    def _build_switch(self):
        row = self._row_base(Adw.SwitchRow())
        row.connect("notify::active", self._on_switch)
        return row

    def _build_combo(self):
        row = self._row_base(Adw.ComboRow())
        self.values = list(self.entry["enum"] or [])
        row.set_model(Gtk.StringList.new([enum_label(self.spec.key, v) for v in self.values]))
        row.connect("notify::selected", self._on_combo)
        return row

    def _build_spin(self):
        row = self._row_base(Adw.SpinRow())
        row.set_adjustment(Gtk.Adjustment(lower=0, upper=1024, step_increment=1, page_increment=8))
        row.connect("notify::value", self._on_spin)
        return row

    def _build_entry(self):
        row = Adw.EntryRow()
        row.set_title(self.spec.title)
        # EntryRow has no subtitle; the text is the value, so the one-liner
        # goes where it still reads as guidance rather than as content.
        if self.spec.subtitle:
            row.set_tooltip_text(self.spec.subtitle)
        row.connect("changed", self._on_entry)
        return row

    def _add_suffixes(self):
        self.widget.add_suffix(self.changed_icon)
        if self.entry.get("description"):
            button = Gtk.Button.new_from_icon_name("help-about-symbolic")
            button.set_valign(Gtk.Align.CENTER)
            button.add_css_class("flat")
            button.set_tooltip_text("Why this setting exists")
            button.connect("clicked", self._show_detail)
            self.widget.add_suffix(button)

    # ── syncing ──────────────────────────────────────────────────────

    def refresh(self):
        """Push the model's value into the widget without echoing back."""
        self._updating = True
        try:
            value = self.settings.effective(self.spec.key)
            if self.spec.frozen:
                pass
            elif isinstance(self.widget, Adw.SwitchRow):
                self.widget.set_active(bool(value))
            elif isinstance(self.widget, Adw.ComboRow):
                if value in self.values:
                    self.widget.set_selected(self.values.index(value))
            elif isinstance(self.widget, Adw.SpinRow):
                self.widget.set_value(float(value or 0))
            elif isinstance(self.widget, Adw.EntryRow):
                text = "" if value is None else str(value)
                if self.widget.get_text() != text:
                    self.widget.set_text(text)
        finally:
            self._updating = False
        self.changed_icon.set_visible(self.spec.key in self.settings.pending)

    def _commit(self, value):
        if self._updating:
            return
        self.settings.set(self.spec.key, value)
        self.changed_icon.set_visible(self.spec.key in self.settings.pending)
        self.on_change()

    def _on_switch(self, row, _param):
        self._commit(row.get_active())

    def _on_combo(self, row, _param):
        index = row.get_selected()
        if 0 <= index < len(self.values):
            self._commit(self.values[index])

    def _on_spin(self, row, _param):
        self._commit(int(row.get_value()))

    def _on_entry(self, row):
        self._commit(row.get_text())

    # ── detail ───────────────────────────────────────────────────────

    def _show_detail(self, button):
        body = self.entry["description"].strip()
        default = format_value(self.entry.get("default"))
        dialog = Adw.AlertDialog.new(self.spec.title, None)
        dialog.set_heading(f"nanoDesktop.{self.spec.key}")
        dialog.set_body(f"{body}\n\nDefault: {default}")
        dialog.add_response("close", "Close")
        dialog.present(button.get_root())


def build_page(page, schema, settings, on_change):
    """An Adw.PreferencesPage for one presentation.Page, and its rows."""
    view = Adw.PreferencesPage()
    view.set_title(page.title)
    view.set_icon_name(page.icon)
    rows = []

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
