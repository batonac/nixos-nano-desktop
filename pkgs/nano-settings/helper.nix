# The root half of nano-settings: the four things the GUI cannot do as the
# user. It is a separate executable rather than code inside the app because
# that is what keeps the privileged surface auditable — this file is the whole
# of it, it is a few dozen lines of shell, and the GUI is what calls pkexec,
# not what runs under it.
#
# Unlike ../system-upgrade.nix this does NOT re-exec itself through pkexec when
# run unprivileged. The GUI already owns that step (it has to, so it can spawn
# an authentication agent first), and a helper that silently escalates is a
# helper whose callers stop thinking about whether they are root.
{ lib, pkgs }:
let
  # The upgrade path is system-upgrade, unchanged — flake update, then rebuild
  # only if the lock actually moved. Reused rather than reimplemented so there
  # is one definition of what "update this machine" means, whether it came from
  # the GUI, the terminal or the nightly timer in modules/nix.nix. Its own
  # pkexec self-escalation is a no-op here: we are already root.
  systemUpgradeScript = import ../system-upgrade.nix { inherit lib pkgs; };
in
pkgs.writeShellApplication {
  name = "nano-settings-helper";
  runtimeInputs = with pkgs; [
    coreutils
    gitMinimal
    jq
    nix
    nixos-rebuild
  ];
  text = ''
    # One stream. nixos-rebuild splits its progress across stdout and stderr,
    # and the GUI renders a single log view — interleaving them here keeps the
    # output in the order it actually happened.
    exec 2>&1

    if [ "$(id -u)" -ne 0 ]; then
      echo "nano-settings-helper must run as root — the GUI invokes it through pkexec."
      exit 1
    fi

    FLAKE_DIR=/etc/nixos
    SETTINGS="$FLAKE_DIR/nanoDesktop-settings.json"
    BACKUP="$SETTINGS.bak"

    usage() {
      echo "usage: nano-settings-helper {apply|rebuild|upgrade|rollback}"
      echo "  apply     read new settings JSON on stdin, install it, rebuild"
      echo "  rebuild   rebuild from the settings already on disk"
      echo "  upgrade   update flake inputs, then rebuild if anything moved"
      echo "  rollback  switch back to the previous system generation"
    }

    case "''${1-}" in
      apply)
        # Stage in the flake directory itself so the install is a rename
        # within one filesystem — a half-written settings file is a
        # machine that cannot evaluate, and the window for that has to
        # be zero rather than small.
        staged=$(mktemp "$FLAKE_DIR/.nanoDesktop-settings.json.XXXXXX")
        trap 'rm -f "$staged"' EXIT
        cat > "$staged"

        if ! jq -e . "$staged" > /dev/null; then
          echo "Refusing to apply: what arrived on stdin is not valid JSON."
          exit 1
        fi

        # An explicit if, not `[ -f … ] && cp …`: writeShellApplication runs
        # under set -e, where a trailing && list that tests false is itself a
        # failing command, so the shorthand would abort apply on exactly the
        # machine that has no settings file yet.
        if [ -f "$SETTINGS" ]; then
          cp -p "$SETTINGS" "$BACKUP"
        fi

        # root-owned and world-readable: this is system configuration, and
        # the installer leaves it writable by the first user only because
        # of how it is generated.
        chown root:root "$staged"
        chmod 0644 "$staged"
        mv -f "$staged" "$SETTINGS"
        trap - EXIT

        echo "Settings written to $SETTINGS. Rebuilding…"
        if nixos-rebuild switch --flake "$FLAKE_DIR"; then
          echo
          echo "Done. The desktop shell restarted on the new settings, so the"
          echo "panel, notifications and background are already showing them."
          echo "Anything you have open keeps its current version until you"
          echo "log out."
        else
          status=$?
          echo
          echo "Rebuild failed. Restoring the previous settings."
          # The load-bearing half of this script. Without it a single bad
          # value leaves a machine that cannot evaluate at all — which
          # takes the nightly autoUpgrade timer down with it, silently,
          # and turns a wrong dropdown into a rescue-media problem.
          if [ -f "$BACKUP" ]; then
            cp -p "$BACKUP" "$SETTINGS"
          else
            rm -f "$SETTINGS"
          fi
          echo "Settings restored. The system was not changed."
          exit "$status"
        fi
        ;;

      rebuild)
        nixos-rebuild switch --flake "$FLAKE_DIR"
        ;;

      upgrade)
        exec ${lib.getExe systemUpgradeScript}
        ;;

      rollback)
        # No --flake: rollback walks the system profile's own generation
        # links, which is exactly the point — it has to work when the
        # current configuration is the thing that is broken.
        nixos-rebuild switch --rollback
        ;;

      -h | --help | help)
        usage
        ;;

      *)
        usage
        exit 1
        ;;
    esac
  '';
}
