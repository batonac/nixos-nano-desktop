"""The window: a sidebar of pages, and the Apply flow that ties them together.

Edits are batched. Every change marks the window dirty and raises a banner;
nothing reaches /etc/nixos until Apply, which shows what is about to change
and then hands the whole file to the helper in one go. That is not just
tidiness — a rebuild on the hardware this desktop targets is minutes, and
one rebuild for a session of edits is the difference between a usable
settings app and a slow one.
"""

from __future__ import annotations

from gi.repository import Adw, Gtk

from . import pages, presentation
from .account import AccountPage
from .maintenance import LogView, MaintenancePage
from .settings import Schema, Settings, format_value
from .software import SoftwarePage


class Window(Adw.ApplicationWindow):
    def __init__(self, application: Adw.Application, schema: Schema, settings: Settings) -> None:
        super().__init__(application=application, title="System Settings")
        self.schema = schema
        self.settings = settings
        self.option_rows: list[pages.OptionRow] = []
        self.busy = False
        # The three hand-built pages. Declared rather than assigned, because
        # which of them exists is decided by the loop in _build over
        # presentation.PAGES, and every one of them is read from elsewhere.
        self.software: SoftwarePage
        self.account: AccountPage
        self.maintenance: MaintenancePage

        self.set_default_size(940, 700)
        self.set_size_request(360, 400)

        self.log = LogView()
        self._build()
        self._sync()

    # ── construction ─────────────────────────────────────────────────

    def _build(self) -> None:
        # Built before the pages, because constructing a page sets widgets
        # to their stored values and the resulting signals land in _sync.
        self.apply_button = Gtk.Button.new_with_label("Apply")
        self.apply_button.add_css_class("suggested-action")
        self.apply_button.connect("clicked", self._on_apply)

        self.banner = Adw.Banner()
        self.banner.set_button_label("Review and apply")
        self.banner.connect("button-clicked", self._on_apply)

        self.stack = Adw.ViewStack()

        for page in presentation.PAGES:
            child: Gtk.Widget
            if page.custom == "software":
                self.software = SoftwarePage(self.settings, self._on_change)
                child = self.software.view
            elif page.custom == "account":
                self.account = AccountPage(self.settings)
                child = self.account.view
            elif page.custom == "updates":
                self.maintenance = MaintenancePage(
                    self.settings, self.log, self._on_change, self._set_busy
                )
                child = self.maintenance.view
            else:
                child, rows = pages.build_page(page, self.schema, self.settings, self._on_change)
                self.option_rows.extend(rows)
            self.stack.add_titled_with_icon(child, page.ident, page.title, page.icon)

        # A sidebar, not a header switcher: eight pages do not fit across the
        # top of a 1366-wide screen without every label truncating to three
        # letters, which is what this looked like before.
        self.sidebar = Gtk.ListBox()
        self.sidebar.add_css_class("navigation-sidebar")
        for page in presentation.PAGES:
            row = Adw.ActionRow()
            row.set_title(page.title)
            row.add_prefix(Gtk.Image.new_from_icon_name(page.icon))
            self.sidebar.append(row)
        self.sidebar.connect("row-selected", self._on_sidebar)

        sidebar_scroller = Gtk.ScrolledWindow()
        sidebar_scroller.set_child(self.sidebar)
        sidebar_scroller.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)

        sidebar_view = Adw.ToolbarView()
        sidebar_view.add_top_bar(Adw.HeaderBar())
        sidebar_view.set_content(sidebar_scroller)

        self.toasts = Adw.ToastOverlay()
        self.toasts.set_child(self.stack)

        body = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        body.append(self.banner)
        body.append(self.toasts)

        content_header = Adw.HeaderBar()
        content_header.pack_end(self.apply_button)
        content_view = Adw.ToolbarView()
        content_view.add_top_bar(content_header)
        content_view.set_content(body)

        self.content_page = Adw.NavigationPage.new(content_view, presentation.PAGES[0].title)
        self.split = Adw.NavigationSplitView()
        self.split.set_sidebar(Adw.NavigationPage.new(sidebar_view, "Settings"))
        self.split.set_content(self.content_page)
        self.split.set_min_sidebar_width(200)

        # Below this the sidebar becomes a page of its own rather than a
        # column, so the app stays usable on a small or half-tiled window.
        narrow = Adw.Breakpoint.new(Adw.BreakpointCondition.parse("max-width: 700px"))
        narrow.add_setter(self.split, "collapsed", True)
        self.add_breakpoint(narrow)

        self.set_content(self.split)
        self.sidebar.select_row(self.sidebar.get_row_at_index(0))

    def _on_sidebar(self, _listbox: Gtk.ListBox, row: Gtk.ListBoxRow | None) -> None:
        if row is None:
            return
        page = presentation.PAGES[row.get_index()]
        self.stack.set_visible_child_name(page.ident)
        self.content_page.set_title(page.title)
        # Only meaningful when collapsed, where the sidebar is a separate
        # page and choosing from it should move to what was chosen.
        self.split.set_show_content(True)

    # ── state ────────────────────────────────────────────────────────

    def _on_change(self) -> None:
        self._sync()

    def _sync(self) -> None:
        dirty = self.settings.dirty
        count = len(self.settings.pending)
        self.apply_button.set_sensitive(dirty and not self.busy)
        self.banner.set_revealed(dirty)
        self.banner.set_title(
            "1 setting changed but not applied"
            if count == 1
            else f"{count} settings changed but not applied"
        )

    def _set_busy(self, busy: bool) -> None:
        """While root is working, take away the things that would collide.

        Only the buttons that would start a second privileged run: Apply
        (through _sync) and the maintenance actions. The pages themselves
        stay live, because sensitivity is inherited in GTK — desensitising
        the stack would take the log view with it, and the log is the one
        thing worth looking at while a rebuild runs. An edit made meanwhile
        simply becomes a pending change for the next Apply.
        """
        self.busy = busy
        self.maintenance.set_sensitive(not busy)
        self._sync()

    def refresh_all(self) -> None:
        for row in self.option_rows:
            row.refresh()
        self.software.refresh()
        self.maintenance.refresh()
        self._sync()

    # ── applying ─────────────────────────────────────────────────────

    def _on_apply(self, _widget: Gtk.Widget) -> None:
        if not self.settings.dirty or self.busy:
            return

        body = "\n".join(
            f"• {self._label(key)}:  {format_value(old)}  →  {format_value(new)}"
            for key, old, new in self.settings.diff()
        )
        dialog = Adw.AlertDialog.new("Apply these changes?", None)
        dialog.set_body(
            f"{body}\n\n"
            "Applying rebuilds the system, which takes a few minutes and needs "
            "the administrator password. If the rebuild fails, the previous "
            "settings are put back automatically."
        )
        dialog.add_response("cancel", "Cancel")
        dialog.add_response("apply", "Apply")
        dialog.set_response_appearance("apply", Adw.ResponseAppearance.SUGGESTED)
        dialog.set_default_response("apply")
        dialog.connect("response", self._on_apply_response)
        dialog.present(self)

    def _goto(self, ident: str) -> None:
        for index, page in enumerate(presentation.PAGES):
            if page.ident == ident:
                self.sidebar.select_row(self.sidebar.get_row_at_index(index))
                return

    def _label(self, key: str) -> str:
        row = presentation.rows_by_key().get(key)
        if row is not None:
            return row.title
        return key.split(".")[-1]

    def _on_apply_response(self, _dialog: Adw.AlertDialog, response: str) -> None:
        if response != "apply":
            return
        payload = self.settings.serialize()
        # Selecting the row is what switches the stack, so the sidebar
        # highlight and the page title follow along rather than drifting
        # out of step with what is on screen.
        self._goto("updates")
        self.maintenance.start(
            "apply",
            "Applying settings",
            stdin_text=payload,
            on_success=self._on_applied,
        )

    def _on_applied(self) -> None:
        self.settings.mark_applied()
        self.refresh_all()
        self.toasts.add_toast(Adw.Toast.new("Settings applied."))
