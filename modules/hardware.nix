{
  config,
  lib,
  pkgs,
  ...
}:
with lib;
let
  cfg = config.nanoDesktop;
in
{
  # ── Power Management ────────────────────────────────────────
  powerManagement = {
    enable = mkDefault true;
    powertop.enable = mkDefault false;
    # Most drives come back from suspend at their firmware default APM
    # level, so the head-parking rule in services.udev.extraRules
    # (storage.nix) has to be re-applied by hand — udev sees no add event
    # for a disk that was never removed. Same match as that rule
    # (rotational SATA/PATA disks) and the same best-effort handling; on a
    # machine with no spinning disk the loop matches nothing and costs a
    # couple of stat calls per resume.
    #
    # types.lines, so a host adding its own resumeCommands appends to
    # this rather than replacing it.
    resumeCommands = ''
      for disk in /sys/block/sd[a-z]; do
        [ -e "$disk/queue/rotational" ] || continue
        [ "$(cat "$disk/queue/rotational")" = 1 ] || continue
        ${pkgs.hdparm}/bin/hdparm -q -B 254 "/dev/''${disk##*/}" || true
      done
    '';
  };

  # ── Hardware ────────────────────────────────────────────────
  hardware = {
    bluetooth.enable = mkDefault cfg.features.bluetooth;
    enableRedistributableFirmware = mkDefault true;
    graphics = {
      enable = true;
      # mesa covers AMD and the Gallium paths either way; these add
      # the Intel VA-API driver(s) selected by nanoDesktop.
      # hardwareVideo. The two Intel drivers cover disjoint
      # generations, which is why "auto" ships both and lets libva
      # fall through to whichever initialises.
      extraPackages =
        with pkgs;
        [ mesa ]
        ++ optionals (elem cfg.hardwareVideo [
          "auto"
          "intel-modern"
        ]) [ intel-media-driver ]
        ++ optionals (elem cfg.hardwareVideo [
          "auto"
          "intel-legacy"
        ]) [ intel-vaapi-driver ];
    };
    sane = {
      enable = mkDefault cfg.features.scanning;
      extraBackends = with pkgs; [
        sane-airscan
        sane-backends
      ];
    };
    sensor.iio.enable = mkDefault false;
  };

  # ── Hardware-facing services ────────────────────────────────
  # Intel thermal daemon (features.thermalManagement) — steers away
  # from the throttle spiral that tired laptop cooling falls into.
  # Exits on non-Intel, so turn the feature off there.
  services.thermald.enable = mkDefault cfg.features.thermalManagement;

  # power-profiles-daemon has no consumer in this stack: there is no
  # GNOME Settings, and the panel exposes no power-profile widget,
  # so nothing ever calls org.freedesktop.UPower.PowerProfiles. It
  # is D-Bus activated, so leaving it on cost no resident memory —
  # only closure — but a daemon nothing can reach is not a feature.
  # Enable it alongside a UI that drives it.
  services.power-profiles-daemon.enable = mkDefault false;

  # brightnessctl udev rules so the video group can set backlight
  # (and nano-osd's brightness keys work without root).
  services.udev.packages = with pkgs; [ brightnessctl ];

  services.udisks2.enable = mkDefault true;
  services.upower.enable = mkDefault true;
}
