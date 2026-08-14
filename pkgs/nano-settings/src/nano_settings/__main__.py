"""Entry point."""

from __future__ import annotations

import sys

import gi

gi.require_version("Adw", "1")
gi.require_version("Gtk", "4.0")

from gi.repository import Adw, Gtk  # noqa: E402

from . import paths  # noqa: E402
from .privileged import PolkitAgent  # noqa: E402
from .settings import Schema, Settings, SettingsError  # noqa: E402
from .window import Window  # noqa: E402


class Application(Adw.Application):
    def __init__(self) -> None:
        super().__init__(application_id=paths.APP_ID)
        self.agent = PolkitAgent()
        self.window: Window | None = None

    def do_startup(self) -> None:
        Adw.Application.do_startup(self)
        # Started here rather than on the first privileged action so that by
        # the time anyone clicks Apply it has long since registered.
        self.agent.start()

    def do_activate(self) -> None:
        if self.window is None:
            try:
                schema = Schema.load()
                settings = Settings.load(schema)
            except (OSError, ValueError, SettingsError) as error:
                self._fail(str(error))
                return
            self.window = Window(self, schema, settings)
        self.window.present()

    def do_shutdown(self) -> None:
        self.agent.stop()
        Adw.Application.do_shutdown(self)

    def _fail(self, message: str) -> None:
        window = Adw.ApplicationWindow(application=self, title="System Settings")
        window.set_default_size(480, 200)
        status = Adw.StatusPage()
        status.set_icon_name("dialog-error-symbolic")
        status.set_title("Settings could not be read")
        status.set_description(message)
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        box.append(Adw.HeaderBar())
        box.append(status)
        window.set_content(box)
        window.present()


def main() -> int:
    return Application().run(sys.argv)


if __name__ == "__main__":
    sys.exit(main())
