# The nanoDesktop module. Consumers still import exactly one thing —
# self.nixosModules.nanoDesktop — and this is it; the sections below are
# ordinary NixOS modules that merge as usual, so nothing about the interface
# changed when the flake was split up.
#
# Where things live:
#
#   options.nix       every nanoDesktop.* option, features.* included. Also the
#                     installer's menu, which is derived from this schema.
#   boot.nix          kernel, kernel command line, sysctls, bootloader, /tmp
#   storage.nix       the diskType / compressionLevel profiles, the disko
#                     partition table, zram, and the block-layer tuning
#   hardware.nix      graphics + VA-API, bluetooth, scanners, power management
#   networking.nix    iwd + systemd-networkd, avahi, firewall
#   audio.nix         PipeWire, or apulse/pressureaudio when it is switched off
#   nix.nix           nix settings, the resource guards, the upgrade script and
#                     its timer
#   system.nix        console, locale, users, polkit, documentation
#   desktop.nix       the /etc/xdg configuration files, session environment,
#                     fonts and theme
#   session.nix       the tty1 labwc service and the systemd user session
#   applications.nix  what is installed, and which application opens what
#   services.nix      the remaining desktop daemons, each behind a feature flag
#
# ../pkgs holds the two derivations more than one module needs: the office
# suite (applications.nix wants its packages and its MIME types) and the
# system-upgrade script (applications.nix installs it, nix.nix times it).
{ inputs }:
{
  imports = [
    inputs.disko.nixosModules.disko

    ./options.nix

    ./applications.nix
    ./audio.nix
    ./boot.nix
    ./desktop.nix
    ./hardware.nix
    ./networking.nix
    ./nix.nix
    ./services.nix
    ./session.nix
    ./storage.nix
    ./system.nix
  ];
}
