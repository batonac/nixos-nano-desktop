# The type check and the test suite, as something that can be built.
#
# Deliberately not a checkPhase on ./default.nix. That derivation is in the
# closure of every machine this desktop installs, and a check phase there
# would put an X server, mypy and pytest into the build-time closure of the
# settings app — several hundred megabytes to fetch on hardware chosen for
# not having much of anything, to re-run a suite whose result did not depend
# on the machine running it. So it is built by name instead:
#
#   nix build .#nano-settings-tests
#
# The schema and the palette are handed over because the suite checks two
# things it cannot check without them: that every option presentation.py names
# still exists in modules/options.nix, and that every accent the option offers
# has a colour in pkgs/accent.nix. Everything else runs against a schema and a
# palette of its own.
{ lib, pkgs }:
let
  python = import ./python.nix { inherit pkgs; };
  schema = import ./schema.nix { inherit lib pkgs; };
  palette = import ./palette.nix { inherit lib pkgs; };
in
pkgs.runCommand "nano-settings-tests"
  {
    nativeBuildInputs = [
      python
      # The suite builds real widgets, so it starts a real X server.
      pkgs.xorg-server
      # Between them these put the typelibs on GI_TYPELIB_PATH and the
      # GSettings schemas on XDG_DATA_DIRS, which is what makes
      # `from gi.repository import Adw` resolve in a sandbox.
      pkgs.wrapGAppsHook4
      pkgs.gobject-introspection
    ];

    buildInputs = [
      pkgs.gtk4
      pkgs.libadwaita
      pkgs.glib
      pkgs.gsettings-desktop-schemas
      pkgs.adwaita-icon-theme
    ];

    NANO_SETTINGS_SCHEMA = schema;
    NANO_SETTINGS_PALETTE = palette;

    # A sandbox has no /etc/fonts, and fontconfig with nowhere to look is not
    # a warning: Pango ends up with no font map at all and GTK takes the
    # process down building its first label. One font is enough — nothing
    # here asserts on anything that gets rendered.
    FONTCONFIG_FILE = pkgs.makeFontsConf { fontDirectories = [ pkgs.dejavu_fonts ]; };
  }
  ''
    cp -r ${./src} src
    chmod -R u+w src
    cd src

    # GTK wants somewhere to put a settings cache, and pytest wants somewhere
    # for its own; neither exists in a sandbox until it is said to.
    export HOME="$TMPDIR"
    export XDG_RUNTIME_DIR="$TMPDIR"
    export XDG_CACHE_HOME="$TMPDIR/cache"
    export PYTHONPATH="$PWD"
    # wrapGAppsHook4 collects these for the wrapper it would write at fixup;
    # there is no fixup here, so they are put where GLib looks itself.
    export XDG_DATA_DIRS="$GSETTINGS_SCHEMAS_PATH''${XDG_DATA_DIRS:+:$XDG_DATA_DIRS}"

    echo "── mypy ──"
    mypy .

    echo "── pytest ──"
    python -m pytest

    touch $out
  ''
