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

    # CPU microcode. This is NOT covered by
    # enableRedistributableFirmware above, which is easy to assume and
    # wrong: that option only fills hardware.firmware, and
    # hardware.cpu.*.updateMicrocode defaults to false on its own. The
    # one place in nixpkgs that wires the two together is
    # nixos-generate-config, which this module replaces outright —
    # disko owns the hardware configuration here — so nothing was ever
    # going to set it. Every machine installed from this flake has
    # therefore been running whatever revision its BIOS shipped with.
    #
    # On the hardware this desktop targets, that BIOS is a decade old
    # and its vendor stopped updating it years before the microcode
    # stopped moving. Measured on the Ivy Bridge this was written on:
    # running revision 0x20, while microcode-intel carries 0x21
    # (2019-02-13) for that exact signature.
    #
    # Worth being straight about what it does and does not buy. It does
    # not fix MDS on the older parts — Intel never shipped MDS
    # microcode for Ivy Bridge and never will, so that machine still
    # reads "no microcode" afterwards and nanoDesktop.cpuBufferClears
    # is still the right lever there. Where this matters is the other
    # half of the range: Haswell through Skylake and later, where the
    # gap between a 2014 BIOS and the current bundle does include
    # mitigation microcode. Those machines have been paying the full
    # runtime cost of mitigations while missing the microcode half that
    # makes some of them work, and nothing on the machine says so.
    #
    # Both vendors, because this module cannot know which CPU it is
    # being installed onto — the guided ISO is generic by design, and
    # nothing here asks. The asymmetry makes that cheap anyway: the AMD
    # image is 300 KB against Intel's 15 MB, so enabling both costs
    # what enabling Intel alone costs.
    #
    # And that cost is disk, landing somewhere slightly awkward: the
    # images are prepended to the initrd (boot.initrd.prepend), so it
    # is ~15 MB per generation on the ESP rather than one shared store
    # path. At the systemd-boot configurationLimit of 10 that is ~150
    # MB of a 512 MB partition. It fits, and it is the reason not to
    # raise that limit on a machine with a smaller one.
    cpu = {
      intel.updateMicrocode = mkDefault true;
      amd.updateMicrocode = mkDefault true;
    };

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

  # ── Energy/Performance Bias (nanoDesktop.energyPerfBias) ────
  # 4 is "balance-performance"; see the option for why not 0, and why
  # this is a separate axis from the governor rather than a substitute
  # for setting one.
  #
  # A udev rule rather than a service because the cpu subsystem emits
  # an add event per CPU, so this covers hotplug and the late-onlined
  # siblings without a loop. Unlike the hdparm rule in storage.nix it
  # needs no counterpart in powerManagement.resumeCommands: EPB is an
  # MSR, and the kernel's own intel_epb driver saves and restores it
  # across suspend and CPU offline, so the value set here survives.
  #
  # ATTR{} is relative to the device's syspath, i.e.
  # /sys/devices/system/cpu/cpuN/power/energy_perf_bias. The attribute
  # only exists where the CPU advertises the EPB feature, so on AMD —
  # and on Intel parts predating it — the rule matches nothing and
  # costs a failed lookup per CPU at boot.
  services.udev.extraRules = mkIf (cfg.energyPerfBias == "performance") ''
    ACTION=="add", SUBSYSTEM=="cpu", ATTR{power/energy_perf_bias}=="?*", ATTR{power/energy_perf_bias}="4"
  '';

  services.udisks2.enable = mkDefault true;
  services.upower.enable = mkDefault true;
}
