"""The Software page: pick from a catalogue, or name any nixpkgs attribute.

Both routes write to nanoDesktop.extraPackageNames, a list of strings, which
is the only shape a package list can take in a JSON settings file.

There is deliberately no browse-all-of-nixpkgs here. Searching the full set
means building an eval cache — minutes of CPU and a gigabyte or two of peak
memory — on a machine chosen for this desktop precisely because it does not
have that to spare. The catalogue covers what people actually reach for, and
the attribute box covers the rest at the cost of knowing the name.
"""

from __future__ import annotations

import json
import re
from collections.abc import Iterable
from typing import Final

from gi.repository import Adw, Gio, GLib, Gtk

from . import paths
from .datatypes import CatalogItem, JSONValue, OnChange, narrow_catalog_item
from .settings import Settings

KEY: Final = "extraPackageNames"

# What a nixpkgs attribute path can look like. Checked before the name is
# spliced into the probe expression below, which is what keeps a typed
# package name from being typed Nix code.
ATTR_RE: Final = re.compile(r"^[A-Za-z0-9_][A-Za-z0-9_'-]*(\.[A-Za-z0-9_][A-Za-z0-9_'-]*)*$")


def load_catalog() -> list[CatalogItem]:
    """catalog.json, with anything unreadable in it dropped.

    Nothing here is load-bearing: a missing or malformed catalogue costs the
    list of suggestions and nothing else, and the attribute box below it
    still reaches all of nixpkgs.
    """
    try:
        with open(paths.CATALOG, encoding="utf-8") as handle:
            raw = json.load(handle)
    except (OSError, ValueError):
        return []
    if not isinstance(raw, list):
        return []
    return [item for item in map(narrow_catalog_item, raw) if item is not None]


class SoftwarePage:
    def __init__(self, settings: Settings, on_change: OnChange) -> None:
        self.settings = settings
        self.on_change = on_change
        self.catalog = load_catalog()
        self._rows: dict[str, Adw.SwitchRow] = {}
        self._updating = False
        self._validator: Gio.Subprocess | None = None

        self.view = Adw.PreferencesPage()
        self.view.set_title("Software")
        self.view.set_icon_name("system-software-install-symbolic")

        self._build_search()
        self._build_catalog()
        self._build_manual()
        self.refresh()

    # ── model ────────────────────────────────────────────────────────

    def _selected(self) -> list[str]:
        value = self.settings.effective(KEY)
        if not isinstance(value, list):
            return []
        return [name for name in value if isinstance(name, str)]

    def _set_selected(self, names: Iterable[str]) -> None:
        # Sorted and de-duplicated: the list is a set in everything but type,
        # and a stable order keeps the diff in the review dialog readable.
        # Built as a list of settings values rather than as a list of strings
        # because a list is invariant: list[str] is not a list[JSONValue],
        # and this one is going somewhere that may hold either.
        self.settings.set(KEY, list[JSONValue](sorted(set(names))))
        self.on_change()

    def add(self, attr: str) -> None:
        self._set_selected([*self._selected(), attr])

    def remove(self, attr: str) -> None:
        self._set_selected([name for name in self._selected() if name != attr])

    # ── widgets ──────────────────────────────────────────────────────

    def _build_search(self) -> None:
        group = Adw.PreferencesGroup()
        self.search = Gtk.SearchEntry()
        self.search.set_placeholder_text("Search applications")
        self.search.connect("search-changed", lambda _entry: self._apply_filter())
        group.add(self.search)
        self.view.add(group)

    def _build_catalog(self) -> None:
        categories: dict[str, list[CatalogItem]] = {}
        for item in self.catalog:
            categories.setdefault(item["category"], []).append(item)

        self.groups: list[Adw.PreferencesGroup] = []
        for category in sorted(categories):
            group = Adw.PreferencesGroup()
            group.set_title(category)
            for item in sorted(categories[category], key=lambda entry: entry["name"].lower()):
                row = Adw.SwitchRow()
                row.set_title(item["name"])
                subtitle = item["summary"]
                if item["unfree"]:
                    subtitle = f"{subtitle}  ·  Unfree licence" if subtitle else "Unfree licence"
                row.set_subtitle(subtitle)
                row.connect("notify::active", self._on_toggle, item["attr"])
                self._rows[item["attr"]] = row
                group.add(row)
            self.view.add(group)
            self.groups.append(group)

    def _build_manual(self) -> None:
        group = Adw.PreferencesGroup()
        group.set_title("Anything else")
        group.set_description(
            "Any package in nixpkgs, by its attribute name — firefox, gimp, "
            "hunspellDicts.en_US. Names are checked before they are added."
        )

        self.manual_entry = Adw.EntryRow()
        self.manual_entry.set_title("Package attribute")
        self.manual_entry.connect("entry-activated", lambda _row: self._validate())

        self.add_button = Gtk.Button.new_with_label("Check and add")
        self.add_button.set_valign(Gtk.Align.CENTER)
        self.add_button.add_css_class("suggested-action")
        self.add_button.connect("clicked", lambda _button: self._validate())
        self.manual_entry.add_suffix(self.add_button)
        group.add(self.manual_entry)

        self.manual_status = Gtk.Label()
        self.manual_status.set_wrap(True)
        self.manual_status.set_xalign(0)
        self.manual_status.add_css_class("dim-label")
        self.manual_status.set_visible(False)
        self.manual_status.set_margin_top(6)
        group.add(self.manual_status)
        self.view.add(group)

        # Packages named by hand rather than picked from the catalogue.
        self.extra_group = Adw.PreferencesGroup()
        self.extra_group.set_title("Added by name")
        self.view.add(self.extra_group)
        self._extra_rows: list[Adw.ActionRow] = []

    # ── refresh ──────────────────────────────────────────────────────

    def refresh(self) -> None:
        self._updating = True
        try:
            selected = set(self._selected())
            for attr, row in self._rows.items():
                row.set_active(attr in selected)
        finally:
            self._updating = False

        for stale in self._extra_rows:
            self.extra_group.remove(stale)
        self._extra_rows = []

        uncatalogued = sorted(set(self._selected()) - set(self._rows))
        for attr in uncatalogued:
            action_row = Adw.ActionRow()
            action_row.set_title(attr)
            button = Gtk.Button.new_from_icon_name("user-trash-symbolic")
            button.set_valign(Gtk.Align.CENTER)
            button.add_css_class("flat")
            button.set_tooltip_text("Remove")
            button.connect("clicked", lambda _b, name=attr: self.remove(name))
            action_row.add_suffix(button)
            self.extra_group.add(action_row)
            self._extra_rows.append(action_row)
        self.extra_group.set_visible(bool(uncatalogued))

    def _apply_filter(self) -> None:
        needle = self.search.get_text().strip().lower()
        for item in self.catalog:
            row = self._rows[item["attr"]]
            haystack = f"{item['name']} {item['attr']} {item['summary']}".lower()
            row.set_visible(needle in haystack)
        for group in self.groups:
            # Hide a category once everything inside it is filtered out.
            visible = any(
                self._rows[item["attr"]].get_visible()
                for item in self.catalog
                if item["category"] == group.get_title()
            )
            group.set_visible(visible)

    # ── callbacks ────────────────────────────────────────────────────

    def _on_toggle(self, row: Adw.SwitchRow, _param: object, attr: str) -> None:
        if self._updating:
            return
        if row.get_active():
            self.add(attr)
        else:
            self.remove(attr)

    # ── validation ───────────────────────────────────────────────────

    def _validate(self) -> None:
        attr = self.manual_entry.get_text().strip()
        if not attr:
            return
        if attr in self._selected():
            self._status(f"{attr} is already in the list.")
            return
        if not ATTR_RE.match(attr):
            self._status(
                "That is not an attribute name. Expected something like "
                "gimp or hunspellDicts.en_US."
            )
            return

        self._status(f"Checking {attr}…")
        self.add_button.set_sensitive(False)

        launcher = Gio.SubprocessLauncher.new(
            Gio.SubprocessFlags.STDOUT_PIPE | Gio.SubprocessFlags.STDERR_PIPE
        )
        # Both of these would let the check pass something the rebuild will
        # then refuse: the rebuild runs as root through pkexec, with none of
        # this session's environment. A check that disagrees with the thing
        # it is checking is worse than no check.
        launcher.unsetenv("NIXPKGS_ALLOW_UNFREE")
        launcher.unsetenv("NIXPKGS_CONFIG")

        try:
            process = launcher.spawnv(
                [paths.NIX, "eval", "--impure", "--raw", "--expr", self._probe(attr)]
            )
        except GLib.Error as error:
            self._status(f"Could not run nix: {error.message}")
            self.add_button.set_sensitive(True)
            return

        self._validator = process
        process.communicate_utf8_async(None, None, self._on_validated, attr)

    def _probe(self, attr: str) -> str:
        """A one-attribute eval against the nixpkgs this system is pinned to.

        Not `nixosConfigurations.default.pkgs`, which would evaluate the
        whole system to answer a question about one package. Importing the
        input directly touches nixpkgs and nothing else — seconds, against
        a source already in the store.

        allowUnfree matches what modules/nix.nix sets for the system, so
        the check agrees with what the rebuild will actually do rather
        than refusing something the rebuild would have accepted.

        The result is forced through drvPath rather than name, because
        that is where nixpkgs' licence and broken-package checks fire.
        Reading .name off a package nixpkgs would refuse succeeds —
        measured, not assumed — so a probe that stopped there would wave
        through a whole class of packages this check exists to catch.
        """
        path = "".join(f' "{part}"' for part in attr.split("."))
        return f"""
          let
            flake = builtins.getFlake "{paths.FLAKE_DIR}";
            nixpkgs = flake.inputs.nixpkgs;
            pkgs = import nixpkgs {{
              system = builtins.currentSystem;
              config.allowUnfree = true;
            }};
            found = nixpkgs.lib.attrByPath [{path} ] null pkgs;
          in
          if found == null then "" else builtins.seq found.drvPath found.name
        """

    def _on_validated(self, process: Gio.Subprocess, result: Gio.AsyncResult, attr: str) -> None:
        self.add_button.set_sensitive(True)
        try:
            _, stdout, stderr = process.communicate_utf8_finish(result)
        except GLib.Error as error:
            self._status(f"Could not check {attr}: {error.message}")
            return

        if process.get_successful() and stdout and stdout.strip():
            self.add(attr)
            self.manual_entry.set_text("")
            self._status(f"Added {attr} ({stdout.strip()}).")
            self.refresh()
            return

        # An attribute that simply is not there returns an empty string and
        # succeeds; anything nixpkgs refuses to evaluate throws and explains
        # itself on stderr, where the line worth showing is the first one
        # nix marked as the error.
        lines = [line.strip() for line in (stderr or "").splitlines() if line.strip()]
        errors = [line for line in lines if line.startswith("error:")]
        if errors:
            hint = errors[0].removeprefix("error:").strip() or errors[0]
        elif lines:
            hint = lines[-1]
        else:
            hint = "there is no package by that name in nixpkgs"
        self._status(f"Could not add {attr}: {hint}")

    def _status(self, text: str) -> None:
        self.manual_status.set_text(text)
        self.manual_status.set_visible(True)
