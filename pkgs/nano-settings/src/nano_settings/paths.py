"""Where everything lives.

The two data files sit beside this package in the store, so they are found
relative to __file__ with no substitution. The two executables cannot be:
the polkit agent is a build-time dependency and gets its store path patched
in, and the helper is deliberately referenced through the *stable* system
profile path rather than the store, because that is the path the polkit
action's exec.path annotation names. A store path there would stop matching
the moment anything in the helper's closure changed.
"""

from pathlib import Path

_SHARE = Path(__file__).resolve().parent.parent

SCHEMA = _SHARE / "schema.json"
CATALOG = _SHARE / "catalog.json"

SETTINGS = Path("/etc/nixos/nanoDesktop-settings.json")
FLAKE_DIR = Path("/etc/nixos")

HELPER = "/run/current-system/sw/bin/nano-settings-helper"

# Patched by the derivation. Left as the bare name so that running the app
# straight out of a source checkout still finds an agent if one is on PATH.
POLKIT_AGENT = "@polkitAgent@"

APP_ID = "nu.avu.NanoSettings"
