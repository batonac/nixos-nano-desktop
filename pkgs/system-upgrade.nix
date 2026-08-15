# The `system-upgrade` command: flake update + nixos-rebuild switch, run by
# hand or by the timer in modules/nix.nix. Lives here because both that timer
# and the package list in modules/applications.nix need it.
{ lib, pkgs }:
# Minimal system upgrade script (no timers, manual invocation only)
pkgs.writeShellApplication {
  name = "system-upgrade";
  runtimeInputs = with pkgs; [
    coreutils
    gitMinimal
    nix
    nixos-rebuild
  ];
  text = ''
    if [ "$(id -u)" -ne 0 ]; then
      exec /run/wrappers/bin/pkexec "$0" "$@"
    fi
    cd /etc/nixos
    BEFORE=$(sha256sum flake.lock 2>/dev/null || echo "")
    ${lib.getExe pkgs.nix} flake update --flake /etc/nixos
    AFTER=$(sha256sum flake.lock 2>/dev/null || echo "")
    if [ "$BEFORE" != "$AFTER" ]; then
      ${lib.getExe pkgs.nixos-rebuild} switch --flake /etc/nixos
      # The switch restarts the desktop shell in place (see
      # modules/session.nix): the panel, notifications, background and
      # clipboard watcher come back on the new versions, and labwc
      # reloads its configuration. What it deliberately does not touch
      # is the compositor binary and the applications the user has open
      # — those are the one thing a switch cannot replace under them.
      echo "Upgrade applied. The desktop shell has restarted on the new version; the compositor and anything you have open keep theirs until you log out." >&2
    else
      echo "Flake lock unchanged, skipping rebuild" >&2
    fi
  '';
}
