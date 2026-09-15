"""The window: a sidebar of pages, and the Apply flow that ties them together.

Edits are batched. Every change marks the window dirty and raises a banner;
nothing reaches /etc/nixos until Apply, which shows what is about to change
and then hands the whole file to the helper in one go. That is not just
tidiness — a rebuild on the hardware this desktop targets is minutes, and
one rebuild for a session of edits is the difference between a usable
settings app and a slow one.

Pages are built when they are first looked at. Building all eight up front
was about half of what the window cost to open — the Software page alone is
eighty-odd rows — for seven pages that a visit to change one setting never
sees. A page built late reads the model as it is then, so an edit pending
from before it existed shows as pending in it and one applied shows as
applied; the banner and the review dialog read the model too, never the
widgets, so they need no page at all.
"""

from __future__ import annotations

from gi.repository import Adw, Gtk

from . import network, pages, presentation
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
        # Between a click on Apply and the network's answer, when a second
        # click must not ask a second time.
        self.checking = False
        # The three hand-built pages: None until each is first shown.
        self.software: SoftwarePage | None = None
        self.account: AccountPage | None = None
        self.maintenance: MaintenancePage | None = None

        self.set_default_size(940, 700)
        self.set_size_request(360, 400)

        # Before any page, because it is shared: Apply writes to it, and the
        # Updates page shows it — and Apply can run before that page has
        # ever been visited.
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

        # Empty until a page is chosen; _ensure_page fills it one page at a
        # time. The order of its children is the order of visits, which
        # nothing looks at — the sidebar is the navigation.
        self.stack = Adw.ViewStack()

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
        # Selecting is what builds a page, through _on_sidebar — so this is
        # where the first page comes from, and the only one built here.
        self.sidebar.select_row(self.sidebar.get_row_at_index(0))

    def _ensure_page(self, page: presentation.Page) -> Gtk.Widget:
        """The stack child for a page, built on the first request."""
        child = self.stack.get_child_by_name(page.ident)
        if child is not None:
            return child
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
        return child

    def _updates(self) -> MaintenancePage:
        """The Updates page, whether or not it has been visited yet."""
        self._ensure_page(presentation.PAGES_BY_IDENT["updates"])
        assert self.maintenance is not None
        return self.maintenance

    def _on_sidebar(self, _listbox: Gtk.ListBox, row: Gtk.ListBoxRow | None) -> None:
        if row is None:
            return
        page = presentation.PAGES[row.get_index()]
        self._ensure_page(page)
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
        self.apply_button.set_sensitive(dirty and not self.busy and not self.checking)
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
        # Only the Updates page ever says root is working, so it exists by
        # the time this runs; the check is for the type and never fails.
        if self.maintenance is not None:  # pragma: no branch
            self.maintenance.set_sensitive(not busy)
        self._sync()

    def refresh_all(self) -> None:
        for row in self.option_rows:
            row.refresh()
        # A page not built yet reads the model when it is, so only the ones
        # that exist have anything to bring up to date.
        if self.software is not None:
            self.software.refresh()
        if self.maintenance is not None:
            self.maintenance.refresh()
        self._sync()

    # ── applying ─────────────────────────────────────────────────────

    def _on_apply(self, _widget: Gtk.Widget) -> None:
        if not self.settings.dirty or self.busy or self.checking:
            return
        if not self._downloads():
            self._review()
            return
        # Ask the cache first — the thing the rebuild would actually talk to
        # — and refuse in words if it cannot be reached. Asked through the
        # main loop, so the button greys out rather than the window freezing
        # for the few seconds the answer can take.
        self.checking = True
        self._sync()
        network.check_online(self._on_online_checked)

    def _downloads(self) -> list[str]:
        """The pending changes that are downloads, by their row titles.

        An option the install media bakes differently from the module's
        default (SchemaEntry.installMedia) has every other value off the
        media; moving to one of them means the rebuild fetches it, and on
        a machine with no route out that is a rebuild that fails after the
        password prompt, twenty minutes in. Moving BACK to the media's
        value needs nothing and is not counted.
        """
        return [
            self._label(key)
            for key, _old, new in self.settings.diff()
            if key in self.schema
            and self.schema[key]["installMedia"] is not None
            and new != self.schema[key]["installMedia"]
        ]

    def _on_online_checked(self, online: bool) -> None:
        self.checking = False
        self._sync()
        # Asked again rather than remembered from the click: the pages stayed
        # live while the network was consulted, and a download set back to
        # the media's value in the meantime needs no network after all.
        downloads = self._downloads()
        if online or not downloads:
            self._review()
            return

        names = "\n".join(f"• {name}" for name in downloads)
        offline = Adw.AlertDialog.new("Not connected to the internet", None)
        offline.set_body(
            f"{names}\n\n"
            "These choices are not on the install media, so applying them "
            "downloads their programs. Connect to a network and try again, "
            "or set them back."
        )
        offline.add_response("close", "Close")
        offline.set_default_response("close")
        offline.present(self)

    def _review(self) -> None:
        """What is about to change, and the question."""
        diff = self.settings.diff()
        # Nothing left to ask about: everything was set back while the
        # network was being consulted.
        if not diff:
            return
        body = "\n".join(
            f"• {self._label(key)}:  {format_value(old)}  →  {format_value(new)}"
            for key, old, new in diff
        )
        downloads = self._downloads()

        dialog = Adw.AlertDialog.new("Apply these changes?", None)
        note = (
            (
                "\n\nSome of these download their programs — "
                + ", ".join(downloads)
                + " — which takes longer on a slow connection."
            )
            if downloads
            else ""
        )
        dialog.set_body(
            f"{body}\n\n"
            "Applying rebuilds the system, which takes a few minutes and needs "
            "the administrator password. If the rebuild fails, the previous "
            f"settings are put back automatically.{note}"
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
        # out of step with what is on screen — and what builds the page,
        # if this is the first time it is needed.
        self._goto("updates")
        self._updates().start(
            "apply",
            "Applying settings",
            stdin_text=payload,
            on_success=self._on_applied,
        )

    def _on_applied(self) -> None:
        self.settings.mark_applied()
        self.refresh_all()
        self.toasts.add_toast(Adw.Toast.new("Settings applied."))
