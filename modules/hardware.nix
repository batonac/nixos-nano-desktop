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

  # ── Firmware (nanoDesktop.firmwareProfile) ──────────────────
  # linux-firmware is 770 MB — the largest thing on this system after
  # LibreOffice, larger than the kernel and its modules together — and
  # most of it is for hardware that is not a laptop. See options.nix
  # for what comes out and why.
  #
  # Overriding the PACKAGE rather than hardware.firmware: that option
  # is a list NixOS also fills with the small odd ones (ipw2200 for
  # Centrino, rt5677 for Chromebook audio, zd1211 and rtl8192su for USB
  # wifi dongles, rtl8761b for USB bluetooth) — precisely the hardware
  # this desktop exists for. mkForce over the list would have taken
  # those with it; this leaves the list alone and trims only the whale.
  #
  # The trim is applied to the COMPRESSED package, and then compression
  # is declined. NixOS runs every firmware package through
  # compressFirmwareZstd — zstd -19 over about 1.4 GB, which is minutes
  # here and a good deal longer on the machines this targets, and it
  # would run again on every linux-firmware bump. Doing it in this order
  # means the expensive part is the one Hydra already built and the
  # binary cache already has; `passthru.compressFirmware = false` is the
  # module's own opt-out (services/hardware/udev.nix) and is what stops
  # it being redone. What is left is a farm of symlinks into that cached
  # path — no copying, no compression, no compiling.
  #
  # Exclusions rather than an allow-list, deliberately: the kernel loads
  # plenty of firmware from files sitting loose at the top of
  # lib/firmware — 103 of them, iwlwifi's .ucode among them — and from
  # small directories nobody thinks to name. An allow-list has to be
  # complete, and the failure mode for getting it wrong is a device that
  # silently does not work.
  nixpkgs.overlays = mkIf (cfg.firmwareProfile == "laptop") [
    (final: prev: {
      linux-firmware =
        let
          # The exact derivation the udev module would have produced, so
          # it is a cache hit rather than a local zstd run.
          compressed = prev.compressFirmwareZstd prev.linux-firmware;
        in
        prev.runCommand "linux-firmware-laptop"
          {
            passthru = {
              compressFirmware = false;
              inherit (prev.linux-firmware) version;
            };
            inherit (prev.linux-firmware) meta;
          }
          ''
            # A real copy, and it has to be. Symlinks would still point at
            # the full package and keep all 770 MB of it in the closure —
            # saving nothing — and hard links are refused outright, since
            # nix bind-mounts the store into the build sandbox as a
            # separate device ("Invalid cross-device link").
            #
            # So this writes the ~380 MB it keeps. That is I/O, not
            # compression and not compilation, and it happens once per
            # linux-firmware bump. Copying only the kept entries rather
            # than copying everything and deleting after is the difference
            # between writing 380 MB and writing 770 MB.
            #
            # Internal symlinks are relative (compressFirmwareZstd keeps
            # them that way), so they survive the copy and carry no
            # reference back to the original.
            mkdir -p $out/lib/firmware
            for entry in ${compressed}/lib/firmware/*; do
              case " ${
                concatStringsSep " " [
                  "qcom" # 168M — Qualcomm SoCs: phones, Windows-on-ARM
                  "nvidia" # 104M — nouveau / GSP
                  "mellanox" # 102M — datacentre NICs
                  "qed" # 10M  — QLogic FastLinQ, datacentre NICs
                  "netronome" # 5M   — SmartNICs
                  "dpaa2" # 5M   — NXP embedded networking
                ]
              } " in
                *" $(basename "$entry") "*) continue ;;
              esac
              cp -r "$entry" $out/lib/firmware/
            done
            chmod -R u+w $out/lib/firmware
          '';
    })
  ];

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
