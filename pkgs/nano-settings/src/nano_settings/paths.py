"""Where everything lives.

The two data files sit beside this package in the store, so they are found
relative to __file__ with no substitution. The two executables cannot be:
the polkit agent is a build-time dependency and gets its store path patched
in, and the helper is deliberately referenced through the *stable* system
profile path rather than the store, because that is the path the polkit
action's exec.path annotation names. A store path there would stop matching
the moment anything in the helper's closure changed.

The remaining three are program names rather than paths, and stay that way:
pkexec is setuid, passwd is PAM-adjacent, and both must come from the system
rather than from whatever store path this build happened to close over. nix
is on PATH because the wrapper in default.nix puts it there. They are named
here anyway so that every external command this application can run is
listed in one file — and so the tests can point them at a script that
answers the way the real one would.
"""

from __future__ import annotations

import os
from pathlib import Path
from typing import Final

_SHARE: Final = Path(__file__).resolve().parent.parent

# Set by the development shell to the schema built alongside it. There is no
# schema.json in a source checkout — it is generated from modules/options.nix
# at build time — so without this the app only runs from the store.
SCHEMA_ENV: Final = "NANO_SETTINGS_SCHEMA"


def _schema() -> Path:
    override = os.environ.get(SCHEMA_ENV)
    return Path(override) if override else _SHARE / "schema.json"


SCHEMA: Final = _schema()
CATALOG: Final = _SHARE / "catalog.json"

SETTINGS: Final = Path("/etc/nixos/nanoDesktop-settings.json")
FLAKE_DIR: Final = Path("/etc/nixos")

HELPER: Final = Path("/run/current-system/sw/bin/nano-settings-helper")

# Patched by the derivation. Left as the bare name so that running the app
# straight out of a source checkout still finds an agent if one is on PATH.
POLKIT_AGENT: Final = "@polkitAgent@"

PKEXEC: Final = "pkexec"
PASSWD: Final = "passwd"
NIX: Final = "nix"

APP_ID: Final = "nu.avu.NanoSettings"
