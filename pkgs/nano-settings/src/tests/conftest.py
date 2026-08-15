"""What every test here needs: a display, a main loop, and a fake system.

The widgets are real. Nothing in this suite mocks GTK — a settings app is
almost entirely the wiring between a model and a toolkit, and a test that
replaced the toolkit would be testing the wiring against itself. So the
session gets a display of its own, and every page is built on it exactly as
the application builds it.

Its own, rather than the one the developer is sitting in front of: an Xvfb
started here means the suite never puts a window on somebody's screen, never
inherits a theme or a scale factor that changes what the widgets do, and runs
the same way inside the nix build sandbox as it does in the dev shell.

The three things the application shells out to — pkexec, nix and passwd — are
named in paths.py rather than written into the call sites, so each of them can
be pointed at a script that answers the way the real one would. That is what
makes the streaming, the exit codes and the pty conversation testable without
either mocking Gio or asking for a root password.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import time
from collections.abc import Callable, Iterator
from pathlib import Path
from typing import Protocol

import pytest

# ── the display ──────────────────────────────────────────────────────
#
# All of this happens at import, before gi.repository is touched, and that
# ordering is the whole point rather than a style choice: importing
# gi.repository.Gtk initialises GTK against whatever DISPLAY says at that
# moment. Left to a fixture, the suite would have quietly run against the
# developer's own session — where it passes, because there is a display —
# and segfaulted in the build sandbox, where there is not.


def _start_xvfb(xvfb: str) -> subprocess.Popen[bytes]:
    """Start an X server on a display it picks itself, and point DISPLAY at it.

    -displayfd rather than a hardcoded :99 and a sleep: the server writes the
    number it settled on once it is actually listening, so there is no race
    to lose and no collision with whatever else is on this machine.
    """
    read_fd, write_fd = os.pipe()
    os.set_inheritable(write_fd, True)
    process = subprocess.Popen(
        [xvfb, "-displayfd", str(write_fd), "-screen", "0", "1280x1024x24", "-nolisten", "tcp"],
        pass_fds=(write_fd,),
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    os.close(write_fd)
    with os.fdopen(read_fd, "rb") as pipe:
        number = pipe.readline().decode("ascii").strip()
    if not number:
        process.kill()
        raise RuntimeError("Xvfb exited without reporting a display")

    os.environ["DISPLAY"] = f":{number}"
    os.environ["GDK_BACKEND"] = "x11"
    # Everything the ambient session would otherwise pull in: a compositor to
    # prefer over our X server, an accessibility bus to wait for, and — the
    # one that matters — a session bus, on which Adw.Application would find
    # the real nano-settings already registered and quietly become a remote
    # controller for it rather than running anything itself.
    for variable in ("WAYLAND_DISPLAY", "DBUS_SESSION_BUS_ADDRESS", "XDG_SESSION_TYPE"):
        os.environ.pop(variable, None)
    os.environ["GTK_A11Y"] = "none"
    os.environ["GSK_RENDERER"] = "cairo"
    return process


_XVFB = shutil.which("Xvfb")
if _XVFB is None:  # pragma: no cover - the dev shell and the build both have one
    raise RuntimeError("Xvfb is not on PATH. Run these from `nix develop .#nano-settings`.")

_SERVER = _start_xvfb(_XVFB)

import gi  # noqa: E402

# The modules under test ask for Adw and Gtk without naming a version,
# because __main__ has always pinned them by the time they are loaded.
# conftest is what __main__ is here.
gi.require_version("Adw", "1")
gi.require_version("Gtk", "4.0")

from gi.repository import Adw, GLib  # noqa: E402

from nano_settings import paths  # noqa: E402
from nano_settings.datatypes import JSONObject, JSONValue  # noqa: E402
from nano_settings.settings import Schema, Settings  # noqa: E402

Adw.init()


@pytest.fixture(scope="session", autouse=True)
def display() -> Iterator[None]:
    """Nothing to set up — only the X server to take down again."""
    try:
        yield
    finally:
        _SERVER.terminate()
        _SERVER.wait(timeout=10)


class Pump(Protocol):
    """Turn the main loop until something has happened, or give up."""

    def __call__(self, until: Callable[[], bool], timeout: float = ...) -> None: ...


@pytest.fixture
def pump() -> Pump:
    """Half of this application is a Gio async callback.

    Which means most of what is worth asserting has not happened yet when the
    call that started it returns. Everything that waits, waits here.
    """

    def run(until: Callable[[], bool], timeout: float = 30.0) -> None:
        context = GLib.MainContext.default()
        deadline = time.monotonic() + timeout
        while not until():
            if time.monotonic() >= deadline:
                raise AssertionError("timed out waiting for the main loop")
            if not context.iteration(False):
                time.sleep(0.005)

    return run


@pytest.fixture
def host() -> Iterator[Adw.Window]:
    """A window to hang dialogs off.

    Adw.Dialog is presented into the nearest dialog host, which in the
    application is the main window. A page built on its own has none, so the
    tests that present one put it in here first.
    """
    window = Adw.Window()
    yield window
    window.destroy()


# ── the fake system ──────────────────────────────────────────────────

ScriptWriter = Callable[[str, str], Path]


@pytest.fixture
def script(tmp_path: Path) -> ScriptWriter:
    """Write an executable script into the temporary directory."""

    def make(name: str, body: str) -> Path:
        path = tmp_path / name
        path.write_text(body)
        path.chmod(0o755)
        return path

    return make


@pytest.fixture
def shell_script(script: ScriptWriter) -> ScriptWriter:
    def make(name: str, body: str) -> Path:
        return script(name, f"#!/bin/sh\n{body}\n")

    return make


@pytest.fixture
def python_script(script: ScriptWriter) -> ScriptWriter:
    def make(name: str, body: str) -> Path:
        return script(name, f"#!{sys.executable}\n{body}\n")

    return make


@pytest.fixture
def passthrough_pkexec(shell_script: ScriptWriter, monkeypatch: pytest.MonkeyPatch) -> Path:
    """A pkexec that authorises everything, being a test.

    The real one is the boundary this application deliberately does not
    cross; what is worth testing on this side of it is what happens to the
    helper's output and its exit status, and for that an `exec "$@"` is the
    honest stand-in.
    """
    fake = shell_script("pkexec", 'exec "$@"')
    monkeypatch.setattr(paths, "PKEXEC", str(fake))
    return fake


# ── the model ────────────────────────────────────────────────────────


def _entry(
    kind: str,
    default: JSONValue,
    *,
    # Spelled as the JSON shape rather than as list[str], because that is
    # what it becomes on the way through json.dumps and what a list has to
    # be to go into one.
    enum: list[JSONValue] | None = None,
    elem: str | None = None,
    description: str = "Why this option exists, at length.",
) -> JSONObject:
    return {
        "type": kind,
        "elemType": elem,
        "enum": enum,
        "default": default,
        "description": description,
    }


# The shape schema.nix produces, for every option presentation.py names plus
# the two the custom pages reach for directly. Written out rather than read
# from the generated schema.json so the suite does not need a nix build to
# have run; test_presentation.py is what keeps the two agreeing.
SCHEMA_TREE: JSONObject = {
    "hostName": _entry("str", "nano-desktop"),
    "username": _entry("str", "user"),
    "timeZone": _entry("str", "America/New_York"),
    "locale": _entry("str", "en_US.UTF-8"),
    "stateVersion": _entry("str", "25.11"),
    "initialPassword": _entry("str", "password"),
    "diskDevice": _entry("str", "/dev/sda"),
    "swapSizeGiB": _entry("unsignedInt", 8),
    "virtualTerminals": _entry("bool", True),
    "cpuMitigations": _entry("bool", True),
    "cpuBufferClears": _entry("bool", True),
    "browserSiteIsolation": _entry("bool", True),
    # The one option with no description of its own, so that the row without
    # a help button is built somewhere in the suite.
    "disableLogging": _entry("bool", False, description=""),
    "officeSuite": _entry("enum", "libreoffice", enum=["libreoffice", "gnome", "none"]),
    "accentColor": _entry(
        "enum",
        "blue",
        enum=["blue", "teal", "green", "yellow", "orange", "red", "pink", "purple", "slate"],
    ),
    "backgroundColor": _entry("str", "#1c1c1f"),
    "backgroundImage": _entry("str", ""),
    "hardwareVideo": _entry("enum", "auto", enum=["auto", "intel-modern", "intel-legacy", "none"]),
    "firmwareProfile": _entry("enum", "laptop", enum=["laptop", "full"]),
    "energyPerfBias": _entry("enum", "balanced", enum=["balanced", "performance"]),
    "compressionLevel": _entry("enum", "fast", enum=["fast", "balanced", "max"]),
    "diskType": _entry("enum", "ssd", enum=["ssd", "hdd"]),
    "bootMode": _entry("enum", "uefi", enum=["uefi", "legacy"]),
    "extraPackageNames": _entry("list", [], elem="str"),
    "features": {
        "autoUpgrade": _entry("bool", True),
        "printing": _entry("bool", True),
        "scanning": _entry("bool", True),
        "bluetooth": _entry("bool", True),
        "networkDiscovery": _entry("bool", False),
        "virtualFilesystems": _entry("bool", True),
        "clipboardHistory": _entry("bool", True),
        "thumbnails": _entry("bool", True),
        "audioServer": _entry("bool", False),
        "desktopPortal": _entry("bool", False),
        "thermalManagement": _entry("bool", True),
        "processScheduling": _entry("bool", False),
        "settingsApp": _entry("bool", True),
    },
}


@pytest.fixture
def schema() -> Schema:
    # Round-tripped through JSON so a test that mutates what it is given
    # cannot reach the table above.
    return Schema(json.loads(json.dumps(SCHEMA_TREE)))


@pytest.fixture
def settings(schema: Schema) -> Settings:
    """A machine whose settings file names a few things and defaults the rest."""
    return Settings(
        schema,
        {
            "hostName": "kitchen",
            "swapSizeGiB": 4,
            "compressionLevel": "balanced",
            "extraPackageNames": ["gimp", "htop"],
            "features": {"printing": False},
        },
    )


# The nine accents, valued as pkgs/accent.nix values them. Written out here
# for the same reason SCHEMA_TREE is — so the suite does not need a nix build
# to have run — and kept honest by test_palette.py, which compares this
# against the generated palette.json when there is one.
PALETTE: dict[str, str] = {
    "blue": "#3584e4",
    "teal": "#2190a4",
    "green": "#3a944a",
    "yellow": "#c88800",
    "orange": "#ed5b00",
    "red": "#e62d42",
    "pink": "#d56199",
    "purple": "#9141ac",
    "slate": "#6f8396",
}


@pytest.fixture
def palette_file(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    """The palette above, in place of the generated one.

    Every test that wants a swatch bar takes this, so that what it gets does
    not depend on whether the shell that ran it had built a palette.json.
    """
    path = tmp_path / "palette.json"
    path.write_text(json.dumps(PALETTE))
    monkeypatch.setattr(paths, "PALETTE", path)
    return path


@pytest.fixture
def catalog_file(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    """A small catalogue, in place of the shipped one."""
    path = tmp_path / "catalog.json"
    path.write_text(
        json.dumps(
            [
                {
                    "attr": "gimp",
                    "name": "GIMP",
                    "category": "Graphics",
                    "summary": "Photo editor",
                },
                # No category and no summary: filled in by the narrowing.
                {"attr": "inkscape", "name": "Inkscape"},
                {
                    "attr": "steam",
                    "name": "Steam",
                    "category": "Games",
                    "summary": "Games",
                    "unfree": True,
                },
                {"attr": "unrar", "name": "unrar", "category": "Games", "unfree": True},
            ]
        )
    )
    monkeypatch.setattr(paths, "CATALOG", path)
    return path
