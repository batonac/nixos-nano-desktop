"""Updates and maintenance: rebuild, update, roll back, and the log view.

The log is shared with the Apply flow, which is why it lives here and the
window hands it around: everything privileged ends up writing to the same
place, and the user should only ever have one place to look.

None of these can be cancelled once started. The child runs as root and this
process does not, so the buttons go insensitive for the duration rather than
offering a Stop that could not work.
"""

from __future__ import annotations

from typing import Final, NamedTuple

from gi.repository import Adw, Gtk

from .datatypes import OnBusy, OnChange
from .privileged import Runner
from .settings import Settings

AUTO_UPGRADE_KEY: Final = "features.autoUpgrade"


class Action(NamedTuple):
    """One button on the Maintenance group, and the subcommand behind it."""

    title: str
    subtitle: str
    label: str
    command: str
    destructive: bool


ACTIONS: Final = (
    Action(
        "Update now",
        "Fetch new versions of everything and rebuild if anything moved.",
        "Update",
        "upgrade",
        False,
    ),
    Action(
        "Rebuild",
        "Rebuild from the settings already saved. Useful after editing the "
        "configuration by hand.",
        "Rebuild",
        "rebuild",
        False,
    ),
    Action(
        "Roll back",
        "Return to the previous system generation — the one before the most "
        "recent rebuild.",
        "Roll back",
        "rollback",
        True,
    ),
)


class LogView:
    """A monospace, auto-scrolling view of whatever the helper is saying."""

    def __init__(self) -> None:
        self.buffer = Gtk.TextBuffer()
        self.text = Gtk.TextView.new_with_buffer(self.buffer)
        self.text.set_editable(False)
        self.text.set_cursor_visible(False)
        self.text.set_monospace(True)
        self.text.set_wrap_mode(Gtk.WrapMode.WORD_CHAR)
        self.text.set_left_margin(8)
        self.text.set_right_margin(8)
        self.text.set_top_margin(8)
        self.text.set_bottom_margin(8)

        self.scroller = Gtk.ScrolledWindow()
        self.scroller.set_child(self.text)
        self.scroller.set_vexpand(True)
        self.scroller.set_min_content_height(220)
        self.scroller.add_css_class("card")

    def clear(self) -> None:
        self.buffer.set_text("")

    def append(self, line: str) -> None:
        end = self.buffer.get_end_iter()
        self.buffer.insert(end, line + "\n")
        # Scroll by mark rather than by adjustment: the adjustment has not
        # been recomputed yet at this point in the frame.
        mark = self.buffer.create_mark(None, self.buffer.get_end_iter(), False)
        self.text.scroll_mark_onscreen(mark)
        self.buffer.delete_mark(mark)


class MaintenancePage:
    def __init__(
        self,
        settings: Settings,
        log: LogView,
        on_change: OnChange,
        set_busy: OnBusy,
    ) -> None:
        self.settings = settings
        self.log = log
        self.on_change = on_change
        self.set_busy = set_busy
        self._runner: Runner | None = None
        # Set before any widget exists: refresh() below flips the switch,
        # which emits notify::active, which would otherwise report an edit
        # to a window that is still being built.
        self._updating = False

        self.view = Adw.PreferencesPage()
        self.view.set_title("Updates")
        self.view.set_icon_name("software-update-available-symbolic")

        self._build_auto()
        self._build_actions()
        self._build_log()

    def _build_auto(self) -> None:
        group = Adw.PreferencesGroup()
        group.set_title("Automatic updates")
        self.auto_row = Adw.SwitchRow()
        self.auto_row.set_title("Update this computer daily")
        self.auto_row.set_subtitle(
            "Refreshes the sources and rebuilds in the background, at low priority. "
            "The running session keeps its current programs until you log out."
        )
        self.auto_row.connect("notify::active", self._on_auto)
        group.add(self.auto_row)
        self.view.add(group)
        self.refresh()

    def _build_actions(self) -> None:
        group = Adw.PreferencesGroup()
        group.set_title("Maintenance")
        self.buttons: list[Gtk.Button] = []

        for action in ACTIONS:
            row = Adw.ActionRow()
            row.set_title(action.title)
            row.set_subtitle(action.subtitle)
            row.set_subtitle_lines(0)
            button = Gtk.Button.new_with_label(action.label)
            button.set_valign(Gtk.Align.CENTER)
            button.add_css_class(
                "destructive-action" if action.destructive else "suggested-action"
            )
            button.connect("clicked", self._on_action, action)
            row.add_suffix(button)
            self.buttons.append(button)
            group.add(row)

        self.view.add(group)

    def _build_log(self) -> None:
        group = Adw.PreferencesGroup()
        group.set_title("Output")
        group.set_description("What the last operation reported.")
        group.add(self.log.scroller)
        self.view.add(group)

    # ── state ────────────────────────────────────────────────────────

    def refresh(self) -> None:
        self._updating = True
        try:
            self.auto_row.set_active(bool(self.settings.effective(AUTO_UPGRADE_KEY)))
        finally:
            self._updating = False

    def _on_auto(self, row: Adw.SwitchRow, _param: object) -> None:
        if self._updating:
            return
        self.settings.set(AUTO_UPGRADE_KEY, row.get_active())
        self.on_change()

    def set_sensitive(self, sensitive: bool) -> None:
        for button in self.buttons:
            button.set_sensitive(sensitive)

    # ── running ──────────────────────────────────────────────────────

    def _on_action(self, _button: Gtk.Button, action: Action) -> None:
        if action.command == "rollback":
            self._confirm_rollback(action)
        else:
            self.start(action.command, action.title)

    def _confirm_rollback(self, action: Action) -> None:
        dialog = Adw.AlertDialog.new(
            "Roll back to the previous generation?",
            "This undoes the most recent rebuild, including any settings it applied. "
            "The settings file itself is not changed, so the next rebuild would "
            "reapply them.",
        )
        dialog.add_response("cancel", "Cancel")
        dialog.add_response("rollback", "Roll back")
        dialog.set_response_appearance("rollback", Adw.ResponseAppearance.DESTRUCTIVE)
        dialog.set_default_response("cancel")
        dialog.connect("response", self._on_rollback_response, action)
        dialog.present(self.view)

    def _on_rollback_response(
        self, _dialog: Adw.AlertDialog, response: str, action: Action
    ) -> None:
        if response == "rollback":
            self.start(action.command, action.title)

    def start(
        self,
        command: str,
        title: str,
        stdin_text: str | None = None,
        on_success: OnChange | None = None,
    ) -> None:
        self.log.clear()
        self.log.append(f"── {title} ──")
        self.set_busy(True)

        def on_line(line: str) -> None:
            self.log.append(line)

        def on_done(ok: bool, message: str) -> None:
            if message:
                self.log.append("")
                self.log.append(message)
            elif ok:
                self.log.append("")
                self.log.append("Finished.")
            self.set_busy(False)
            if ok and on_success is not None:
                on_success()

        self._runner = Runner(on_line, on_done)
        self._runner.run(command, stdin_text=stdin_text)
