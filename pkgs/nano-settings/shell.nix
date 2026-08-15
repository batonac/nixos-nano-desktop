# Development shell for nano-settings: `nix develop .#nano-settings`.
#
# The interpreter, the GTK stack and every Python dependency come from the
# same nixpkgs the application is built against, because PyGObject is a
# compiled extension bound to one GObject-Introspection and one GTK — a wheel
# from PyPI would be linked against neither, and a venv that resolved its own
# PyGObject would be testing something other than what ships.
#
# What the venv is for, then, is the half nix cannot do: a stable
# ./.venv/bin/python for editors and language servers to point at, and the
# editable install of the package itself so `import nano_settings` works from
# a checkout. It is provisioned from the nix interpreter on shell entry and
# rebuilt whenever that interpreter changes, so it can never drift into being
# the source of truth — deleting it loses nothing.
{ lib, pkgs }:
let
  schema = import ./schema.nix { inherit lib pkgs; };
  palette = import ./palette.nix { inherit lib pkgs; };

  # The same interpreter ./tests.nix builds against, so that a suite which
  # passes in here passes there too. See ./python.nix.
  pythonEnv = import ./python.nix { inherit pkgs; };

  # The tests build real widgets rather than mocking the toolkit, so they
  # need a display. conftest.py starts one from this if the shell has none.
  xvfb = pkgs.xorg-server;
in
pkgs.mkShell {
  name = "nano-settings-dev";

  nativeBuildInputs = with pkgs; [
    # Sets GI_TYPELIB_PATH and XDG_DATA_DIRS from buildInputs below, which is
    # the whole reason `from gi.repository import Adw` resolves in here.
    wrapGAppsHook4
    gobject-introspection
  ];

  buildInputs = with pkgs; [
    gtk4
    libadwaita
    glib
    gsettings-desktop-schemas
    adwaita-icon-theme
  ];

  packages = [
    pythonEnv
    xvfb
    pkgs.ruff
    pkgs.nix # the Software page shells out to it to check a package name
  ];

  # Runtime data. In the store all three sit beside the package and are found
  # relative to __file__; from a checkout the catalogue still is, but the
  # schema and the palette are generated, so they are built with the shell and
  # pointed at here. Rebuilt on every `nix develop`, so neither can go stale
  # against modules/options.nix or pkgs/accent.nix the way a file written into
  # the tree would.
  NANO_SETTINGS_SCHEMA = schema;
  NANO_SETTINGS_PALETTE = palette;

  shellHook = ''
    root=$(${lib.getExe pkgs.git} rev-parse --show-toplevel 2>/dev/null || echo "$PWD")
    src="$root/pkgs/nano-settings/src"
    venv="$root/pkgs/nano-settings/.venv"

    if [ ! -d "$src/nano_settings" ]; then
      echo "nano-settings: $src is not there — is this the right checkout?" >&2
    else
      # Stamped with the interpreter that made it: a venv carries absolute
      # paths into the store, so one left over from a previous nixpkgs is
      # broken in ways that read as mysterious import errors.
      stamp="$venv/.nix-interpreter"
      if [ "$(cat "$stamp" 2>/dev/null || true)" != "${pythonEnv}" ]; then
        echo "nano-settings: provisioning $venv"
        rm -rf "$venv"
        ${pythonEnv}/bin/python -m venv --system-site-packages "$venv"
        # The editable install, without pip and without a network: this is
        # the file pip itself writes for one.
        for site in "$venv"/lib/python*/site-packages; do
          printf '%s\n' "$src" > "$site/nano_settings.pth"
        done
        printf '%s' "${pythonEnv}" > "$stamp"
      fi
      export VIRTUAL_ENV="$venv"
      export PATH="$venv/bin:$PATH"
    fi

    echo "nano-settings dev shell"
    echo "  python $(python --version 2>&1 | cut -d' ' -f2) · pytest · mypy · ruff"
    echo "  cd pkgs/nano-settings/src && pytest        # tests + coverage"
    echo "  cd pkgs/nano-settings/src && mypy .        # type check"
    echo "  python -m nano_settings                    # run the app"
  '';
}
