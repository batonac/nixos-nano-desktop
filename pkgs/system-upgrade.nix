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
      # Session user services carry restartIfChanged=false and the
      # desktop session itself survives the switch (getty@tty1 is
      # masked), so session-level updates land at the next session
      # restart rather than yanking the desktop out from under the
      # user mid-upgrade.
      echo "Upgrade applied. The running desktop session keeps its current binaries; log out or reboot to finish applying session updates." >&2
    else
      echo "Flake lock unchanged, skipping rebuild" >&2
    fi
  '';
}
