"""Updates and maintenance: rebuild, update, roll back, and the log view.

The log is shared with the Apply flow, which is why it lives here and the
window hands it around: everything privileged ends up writing to the same
place, and the user should only ever have one place to look.

None of these can be cancelled once started. The child runs as root and this
process does not, so the buttons go insensitive for the duration rather than
offering a Stop that could not work.
"""

from gi.repository import Adw, Gtk

from .privileged import Runner


class LogView:
    """A monospace, auto-scrolling view of whatever the helper is saying."""

    def __init__(self):
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

    def clear(self):
        self.buffer.set_text("")

    def append(self, line):
        end = self.buffer.get_end_iter()
        self.buffer.insert(end, line + "\n")
        # Scroll by mark rather than by adjustment: the adjustment has not
        # been recomputed yet at this point in the frame.
        mark = self.buffer.create_mark(None, self.buffer.get_end_iter(), False)
        self.text.scroll_mark_onscreen(mark)
        self.buffer.delete_mark(mark)


class MaintenancePage:
    def __init__(self, schema, settings, log, on_change, set_busy):
        self.settings = settings
        self.log = log
        self.on_change = on_change
        self.set_busy = set_busy
        self.schema = schema
        self._runner = None
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

    def _build_auto(self):
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

    def _build_actions(self):
        group = Adw.PreferencesGroup()
        group.set_title("Maintenance")
        self.buttons = []

        for title, subtitle, label, command, destructive in (
            (
                "Update now",
                "Fetch new versions of everything and rebuild if anything moved.",
                "Update",
                "upgrade",
                False,
            ),
            (
                "Rebuild",
                "Rebuild from the settings already saved. Useful after editing the "
                "configuration by hand.",
                "Rebuild",
                "rebuild",
                False,
            ),
            (
                "Roll back",
                "Return to the previous system generation — the one before the most "
                "recent rebuild.",
                "Roll back",
                "rollback",
                True,
            ),
        ):
            row = Adw.ActionRow()
            row.set_title(title)
            row.set_subtitle(subtitle)
            row.set_subtitle_lines(0)
            button = Gtk.Button.new_with_label(label)
            button.set_valign(Gtk.Align.CENTER)
            button.add_css_class("destructive-action" if destructive else "suggested-action")
            button.connect("clicked", self._on_action, command, title)
            row.add_suffix(button)
            self.buttons.append(button)
            group.add(row)

        self.view.add(group)

    def _build_log(self):
        group = Adw.PreferencesGroup()
        group.set_title("Output")
        group.set_description("What the last operation reported.")
        group.add(self.log.scroller)
        self.view.add(group)

    # ── state ────────────────────────────────────────────────────────

    def refresh(self):
        self._updating = True
        try:
            self.auto_row.set_active(bool(self.settings.effective("features.autoUpgrade")))
        finally:
            self._updating = False

    def _on_auto(self, row, _param):
        if self._updating:
            return
        self.settings.set("features.autoUpgrade", row.get_active())
        self.on_change()

    def set_sensitive(self, sensitive):
        for button in self.buttons:
            button.set_sensitive(sensitive)

    # ── running ──────────────────────────────────────────────────────

    def _on_action(self, _button, command, title):
        if command == "rollback":
            self._confirm_rollback()
        else:
            self.start(command, title)

    def _confirm_rollback(self):
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
        dialog.connect(
            "response",
            lambda _dialog, response: response == "rollback" and self.start("rollback", "Roll back"),
        )
        dialog.present(self.view.get_root())

    def start(self, command, title, stdin_text=None, on_success=None):
        self.log.clear()
        self.log.append(f"── {title} ──")
        self.set_busy(True)

        def on_line(line):
            self.log.append(line)

        def on_done(ok, message):
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
