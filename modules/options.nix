# Every nanoDesktop.* option. Kept in one file because the installer
# (nixos-install-helper, see flake.nix) derives its whole menu from this
# schema, so this is also the user-facing documentation of the desktop.
{ lib, ... }:
with lib;
{
  options.nanoDesktop = {
    hostName = mkOption {
      type = types.str;
      default = "nano-desktop";
      description = ''
        Hostname for the system.

        The default is a placeholder, and it exists for the guided
        ISO's sake. That ISO is generic — it bakes this module
        evaluated with NO settings at all, and asks for the identity on
        the target box — so an option with no default has nothing to
        fall back on and the whole image fails to evaluate. The guided
        installer prompts for a hostname and seeds it into
        /etc/nixos/nanoDesktop-settings.json, which the first boot
        applies; the unattended path asks for it up front and bakes the
        answer in. Either way this value is what a machine gets only
        when nobody said otherwise.
      '';
    };
    diskDevice = mkOption {
      type = types.str;
      default = "/dev/sda";
      description = "Disk device for installation";
    };
    diskType = mkOption {
      type = types.enum [
        "ssd"
        "hdd"
      ];
      default = "ssd";
      description = ''
        What kind of drive this machine installs onto. A fair share of
        the hardware this desktop targets still boots off a platter, and
        a platter wants a different set of mkfs and mount choices, a
        different set of background services and a different swap
        posture than flash does — so it is one switch rather than five.

        Both settings put btrfs on the root, with zstd compression
        (see compressionLevel) either way. What differs:

        - "ssd": async discard, small files inlined into metadata
          (max_inline=4096) on a single-profile metadata tree that
          makes that pay, and swapon --discard=once on the swap
          partition.
        - "hdd": autodefrag against CoW fragmentation, batched 60s
          commits, DUP metadata for bad sectors, no discard anywhere,
          and more zram before anything reaches the platter.

        Note what this option is NOT. It is an install-time decision:
        disko derives the mkfs arguments and mount options from it, and
        the metadata profile in particular cannot be changed by editing
        this afterwards. It migrates nothing and reformats nothing. Get
        it right at install time, or reinstall.

        Only the choices that must be made before the disk exists live
        here. The block-layer tuning that can be decided at runtime —
        I/O scheduler, readahead, ATA head parking — is keyed on the
        kernel's own queue/rotational flag in services.udev.extraRules
        instead, so it is also right for a second or external drive of
        the other kind, and stays right even if this option is wrong.
      '';
    };
    compressionLevel = mkOption {
      type = types.enum [
        "fast"
        "balanced"
        "max"
      ];
      default = "fast";
      description = ''
        How hard the btrfs root compresses. Applies under both
        diskTypes: the platter wants this as much as the flash does,
        because there the disk is the bottleneck and a byte not written
        is a seek not taken.

        - "fast": zstd level 1. Close to free on the CPU, and already
          most of the win — measured on a real store, level 1 alone
          accounts for about half the bytes in the files large enough
          to compress. The right answer on any machine whose disk is
          not the binding constraint.
        - "balanced": zstd level 6.
        - "max": zstd level 12. For the case this option exists for —
          a jailbroken Chromebook or similar, 16-32 GB of soldered
          eMMC, where the disk runs out long before the patience does.

        What the tiers trade is write throughput, and on these CPUs
        that is the part to think about: zstd's own figures put level 12
        at well under a tenth of level 1's compression speed, and these
        are not fast cores. "max" suits a machine that substitutes its
        packages from the binary cache; it is a poor fit for one that
        builds them. Reads cost the same at every level.

        Unlike diskType, safe to change on an installed machine.
        Compression is recorded per extent, so what is already written
        keeps decompressing exactly as before and the new level applies
        from the next write on. Nothing is recompressed in place — a
        changed tier shows up as the store turns over, or immediately
        on a fresh install. To force the issue on an existing
        filesystem, btrfs filesystem defragment -r -czstd rewrites what
        is already there.

        Note that this is genuinely free space, not merely fewer bytes
        written: btrfs returns what compression saves, so df moves.
        That is the one thing f2fs would not do, and the reason this
        module is on btrfs at all.
      '';
    };
    swapSizeGiB = mkOption {
      type = types.ints.unsigned;
      default = 8;
      description = ''
        Size of the disk swap partition, in GiB. 0 leaves it out
        entirely.

        This is the second swap tier, not the first: zram sits above it
        at priority 100 (see zramSwap in storage.nix), so the kernel fills
        compressed RAM before it touches the disk. What the partition
        actually buys is hibernation, which needs a resume device at
        least as large as RAM, plus somewhere to go when zram is full
        instead of the OOM killer.

        Which makes 8 GiB a default, not a recommendation. Size it
        against the machine in front of you: at least RAM if you want
        hibernation to work, and rather less than 8 GiB is reasonable
        on a small disk where the space is worth more than a tier that
        is only reached under real pressure. At 0 there is no swap
        partition, no swapDevices entry, no boot.resumeDevice and no
        hibernation — zram alone.

        Install-time, like diskType, but harmless to change afterwards
        rather than dangerous: nothing repartitions on rebuild, so a new
        value simply has no effect on an installed machine. The one
        exception is 0, which drops the swapDevices entry and so stops
        activating a partition that is still sitting on the disk.
      '';
    };
    bootMode = mkOption {
      type = types.enum [
        "uefi"
        "legacy"
      ];
      default = "uefi";
      description = "Boot mode: uefi (systemd-boot) or legacy (GRUB)";
    };
    cpuMitigations = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Keep the kernel's CPU vulnerability mitigations (Meltdown page
        table isolation, Spectre retpolines, MDS/L1TF buffer clears).
        Setting this false adds mitigations=off, which is a security
        decision, not a tuning knob — so it is spelled out here rather
        than buried in kernelParams.

        It is worth understanding what the trade actually is on the
        hardware this desktop targets, because it is not the same trade
        as on a current machine. Mitigations cost the most on exactly
        the oldest CPUs: pre-Skylake parts pay for Meltdown in software
        (PTI flushes the TLB on every syscall) instead of in silicon,
        and the bill lands on syscall- and context-switch-heavy work —
        compiling, unpacking, file managers, browsers — which is most
        of what a desktop does. Reported figures run from a few percent
        to well over 30% depending on the workload; measure yours
        rather than trusting a number.

        And on a machine old enough that Intel has stopped shipping
        microcode for it, some of that is protection you are not
        getting anyway. The Ivy Bridge laptop this was written on
        reports "mds: Vulnerable: Clear CPU buffers attempted, no
        microcode" and "srbds: Vulnerable: No microcode" — it pays for
        PTI and retpolines in full while remaining exposed to the
        classes that need a microcode update to fix. Check
        /sys/devices/system/cpu/vulnerabilities/ on the machine in
        front of you before deciding.

        What you keep by leaving this on: the mitigations that do work
        without microcode, PTI being the important one — Meltdown is
        trivially exploitable and reads kernel memory from any
        unprivileged process. What you give up by turning it off is
        real on a machine that runs a browser. The default is therefore
        the kernel's own; a single-user machine doing local work on
        trusted data is a reasonable place to flip it.
      '';
    };
    hardwareVideo = mkOption {
      type = types.enum [
        "auto"
        "intel-modern"
        "intel-legacy"
        "none"
      ];
      default = "auto";
      description = ''
        VA-API hardware video decoding. Probably the largest single
        win available to this class of machine: a 1080p stream decoded
        on the GPU costs a few percent of one core, and the same stream
        decoded in software will hold an old dual-core at the ceiling,
        heat it until it throttles, and drop frames anyway.

        AMD and older Intel-with-Mesa paths come from mesa, which is
        installed either way; the choice here is which Intel VA-API
        driver to add, and it is a choice because the two do not
        overlap:

        - "auto": install both. libva asks the DRM driver what it is
          and tries the candidates in turn, so the wrong one failing to
          initialise falls through to the right one. Costs the closure
          of both drivers and is the only option that needs no
          knowledge of the machine.
        - "intel-modern": intel-media-driver (iHD), Broadwell and
          newer.
        - "intel-legacy": intel-vaapi-driver (i965), roughly GMA 4500
          through Skylake. The Ivy Bridge and Sandy Bridge laptops this
          desktop is aimed at need this one; iHD does not support them.
        - "none": mesa only.

        vainfo (from libva-utils) is installed with any setting other
        than "none", because "is acceleration actually being used" is
        otherwise unanswerable. Note that Firefox decides separately
        and per-codec, and mpv/Celluloid need hardware decoding turned
        on in their own settings.
      '';
    };
    firmwareProfile = mkOption {
      type = types.enum [
        "laptop"
        "full"
      ];
      default = "laptop";
      description = ''
        How much of linux-firmware to install.

        The full package is 770 MB — the largest thing on this system
        after LibreOffice, larger than the kernel and its modules
        together, and larger than Firefox. On the 16-32 GB disks this
        desktop is aimed at, that is a meaningful fraction of the
        machine spent on firmware for hardware it does not have.

        - "laptop": everything except six directories that are not
          laptop hardware in any configuration —

            qcom       168 MB  Qualcomm SoCs (phones, Windows-on-ARM)
            nvidia     104 MB  nouveau / GSP
            mellanox   102 MB  datacentre NICs
            qed         10 MB  QLogic FastLinQ, datacentre NICs
            netronome    5 MB  SmartNICs
            dpaa2        5 MB  NXP embedded networking

          Everything a laptop actually loads is kept, including the
          parts it would be easy to drop by accident: Intel and AMD
          graphics, all the Wi-Fi families (iwlwifi, ath9k/10k/11k/12k,
          rtw88/89, brcm, mwifiex, mediatek), Bluetooth, wired NICs,
          SOF and HDA audio, and the 103 loose files at the top of
          lib/firmware that no directory covers.

        - "full": stock linux-firmware, nothing removed. The answer if
          this machine has an Nvidia GPU you intend to drive with
          nouveau, or if it is not really a laptop.

        Cheap either way — the trimmed set is a tree of symlinks into
        the same store path, so it is not a second copy and not a
        rebuild of anything.
      '';
    };
    timeZone = mkOption {
      type = types.str;
      default = "America/New_York";
      description = "System timezone";
    };
    locale = mkOption {
      type = types.str;
      default = "en_US.UTF-8";
      description = "System locale";
    };
    username = mkOption {
      type = types.str;
      default = "user";
      description = ''
        Primary user name.

        A placeholder default, for the same reason as hostName: the
        guided ISO evaluates this module with no settings at all, so
        every option it touches needs something to fall back on.

        Unlike hostName, though, the guided installer does not
        currently ask for this one — it collects the disk, the hostname
        and any secret assets, and nothing else — so a guided install
        lands on this name. It is changed the same way as anything else
        here afterwards: edit /etc/nixos/nanoDesktop-settings.json and
        run nixos-rebuild switch --flake /etc/nixos. Note that this
        creates the new account rather than renaming the old one, so
        the home directory does not come with it. The unattended path
        asks for the name up front and bakes it in, which is the way to
        get it right the first time.
      '';
    };
    initialPassword = mkOption {
      type = types.str;
      default = "password";
      description = "Initial password for the user";
    };
    stateVersion = mkOption {
      type = types.str;
      default = "25.11";
      description = "NixOS state version";
    };
    officeSuite = mkOption {
      type = types.enum [
        "libreoffice"
        "gnome"
        "none"
      ];
      default = "libreoffice";
      description = ''
        Office suite to install, and the suite the document MIME types
        are pointed at. An enum rather than a feature-flag bool because
        the choice is three-way, and because the installer builds its
        menu out of these options (see the nixos-install-helper call in
        flake.nix) — where an enum becomes a pick-list, like bootMode.

        - "libreoffice": libreoffice-fresh, the whole suite (Writer,
          Calc, Impress, Draw, Math, Base). By far the largest thing on
          the system — 1.5 GB unpacked, 2.7 GB of closure, most of it
          shared with nothing else here — and the only option that reads
          and writes .docx/.xlsx/.pptx faithfully enough to hand the file
          back to whoever sent it. Started with desktop defaults spliced
          into its configuration registry (currently the Sifr icon
          theme, dark variant, to match the rest of the desktop); they
          are defaults, not locks, so Tools > Options still wins.

        - "gnome": AbiWord and Gnumeric, the GNOME Office pair — about
          0.6 GB together, most of which is the GTK stack this desktop
          already carries, and quick to start on old hardware. Between
          them they cover ODT/DOC/RTF and ODS/XLS/XLSX/CSV. There is no
          presentation program, and AbiWord does not read .docx, so
          those types are deliberately left unassociated instead of
          being pointed at something that would mangle them.

        - "none": no office applications.

        Either suite is reachable from the panel's Start menu, which
        enumerates installed .desktop files; the labwc right-click menu
        is a fixed list and does not change with this option.

        Neither suite ships spell-check dictionaries. Add the ones you
        want through extraPackages (e.g. pkgs.hunspellDicts.en_US) —
        both find them in the system profile.
      '';
    };
    extraPackages = mkOption {
      type = types.listOf types.package;
      default = [ ];
      description = "Additional packages to install";
    };

    # Feature flags — every desktop service that costs idle RAM or disk
    # but is not essential to a working desktop sits behind one of
    # these. Most default on (the featureful desktop) and can be
    # switched off per machine; the two that default OFF (audioServer,
    # desktopPortal) are the heavier choices this lite / old-hardware
    # target deliberately skips — turn them on where they are wanted.
    # They set the underlying NixOS options with mkDefault, so
    # overriding those options directly still works too.
    features = {
      audioServer = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Full PipeWire/WirePlumber audio server. Needed for Bluetooth
          audio output (A2DP), automatic device routing (auto-switch to
          headphones on plug-in), and per-application volume.

          When off, the desktop drops the server entirely and uses
          apulse/pressureaudio instead: a PulseAudio-API-compatible
          shim implemented directly over ALSA (dmix/dsnoop/plug), with
          NO daemon — the lowest-footprint option. It drives only local
          ALSA devices (built-in speakers, headphone jack, HDMI, USB);
          there is no Bluetooth audio and no server-side mixer, so
          pavucontrol is replaced by amixer/alsamixer and the panel
          volume widget talks to the hardware Master control. Firefox
          (which has no ALSA fallback) is pointed at libpressureaudio
          via a wrapper-scoped overlay; mpv/Celluloid and other clients
          fall back to ALSA on their own. Only the small Firefox wrapper
          rebuilds — firefox-unwrapped and the pipewire/gstreamer closure
          stay on the binary cache (see the nixpkgs.overlays note in
          audio.nix).
        '';
      };
      autoUpgrade = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Daily automatic background upgrade timer (flake update +
          nixos-rebuild switch). The manual `system-upgrade` command
          remains available either way.
        '';
      };
      bluetooth = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Bluetooth support: bluetoothd (backing the panel's bluetooth
          widget) plus blueman-manager for on-demand management.
          Disable on machines without bluetooth hardware.

          Note the interaction with features.audioServer: A2DP audio
          output is a PipeWire feature, so with audioServer off there is
          no bluetooth sound and this flag buys only input devices
          (mice, keyboards, controllers) and file transfer. On a machine
          with neither, turning it off drops bluetoothd (~4.4 MB) and
          keeps the bluetooth kernel module and its six drivers
          (~1.2 MB plus their dependents) unloaded.
        '';
      };
      clipboardHistory = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Clipboard history (Super+V) and unicode/emoji search
          (Super+.), both presented through fuzzel and typed back into
          the focused window with wtype.

          The only resident cost is a wl-paste watcher feeding cliphist,
          around 1-2 MB; the pickers themselves exist only for as long
          as their window is open. This replaced an fcitx5-based
          implementation that cost ~20 MB PSS and, because it worked by
          being the session's input method, sat in the path of every
          keystroke on the machine.

          Note what that means if you need a real input method: this
          desktop no longer ships one. Latin layouts are unaffected
          (labwc/xkbcommon handle them — see
          environment.sessionVariables.XKB_DEFAULT_LAYOUT), but CJK and
          other composed scripts need fcitx5 or ibus added back through
          nanoDesktop.extraPackages plus a user service to run it.
        '';
      };
      desktopPortal = mkOption {
        type = types.bool;
        default = false;
        description = ''
          xdg-desktop-portal plus the GTK backend. Portals broker file
          dialogs, notifications, OpenURI and the appearance/color-scheme
          signal for sandboxed and portal-using apps. On this Wayland-only,
          non-sandboxed desktop the native paths already cover all of it —
          GTK's own file chooser, mako for notifications, xdg-open for
          OpenURI, and dark mode from the locked dconf color-scheme, which
          libadwaita reads directly through its GSettings backend when no
          portal answers — so it defaults off to save the ~25-35 MB its
          two D-Bus services take up once a GTK app triggers them. Enable
          it for Flatpak/sandboxed apps, screen-casting portals, or if a
          GTK4 app ends up light without it.
        '';
      };
      networkDiscovery = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Avahi mDNS/DNS-SD: .local hostname resolution and the
          discovery that network printer/scanner setup relies on.
          Disabling it makes features.printing/scanning setup manual.
        '';
      };
      printing = mkOption {
        type = types.bool;
        default = true;
        description = ''
          CUPS printing stack plus system-config-printer. cupsd is
          socket-activated, so it only occupies memory once something
          prints (or the configuration tool is opened).
        '';
      };
      processScheduling = mkOption {
        type = types.bool;
        default = false;
        description = ''
          ananicy-cpp with the CachyOS rule set: nice, ionice, cgroup
          and scheduling policy applied per application, automatically,
          so that a compiler or an indexer cannot compete with the
          thing being typed into. It is the same idea as the resource
          guards this module already applies to nix-daemon, generalised
          to every program with a rule.

          Off by default because it is a resident daemon that polls
          /proc on an interval — modest memory, but a periodic wakeup
          on a laptop that is otherwise engineered down to almost none,
          which is the same reason audioServer and desktopPortal
          default off. Worth turning on for a machine that regularly
          runs something heavy in the background.
        '';
      };
      scanning = mkOption {
        type = types.bool;
        default = true;
        description = ''
          SANE scanner support, including driverless network scanning
          via sane-airscan (library-only: no resident cost, disk only).
        '';
      };
      thermalManagement = mkOption {
        type = types.bool;
        default = true;
        description = ''
          thermald, Intel's thermal daemon. On hardware this old the
          cooling is usually the most degraded part of the machine —
          dried paste, a fan full of a decade of dust — and the failure
          mode is a throttle spiral: the package hits its limit, the
          firmware cuts the multiplier hard, everything crawls. thermald
          steers with the thermal tables before it gets there.

          Intel only, and it means it: thermald checks CPUID at startup
          and exits on anything else, which would leave a failed unit
          on every boot. Turn this off on AMD.
        '';
      };
      thumbnails = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Tumbler thumbnailer (D-Bus activated on demand by the file
          manager; idle cost is zero until thumbnails are requested).
        '';
      };
      virtualFilesystems = mkOption {
        type = types.bool;
        default = true;
        description = ''
          GVFS virtual filesystems: trash, MTP/PTP devices (phones,
          cameras) and network shares in the file manager.

          gvfsd is D-Bus activated, not session-started, so it costs
          nothing until a GIO client asks for it. In practice something
          in the session pokes it once at startup and it then stays
          resident for the session — but the real cost is small: ~2.8 MB
          PSS for gvfsd plus under 2 MB for gvfsd-fuse, because most of
          its ~16 MB RSS is glib/gio already mapped by the panel. (An
          earlier revision of this note claimed ~20 MB; that was reading
          RSS and double-counting shared pages.)
        '';
      };
    };
  };
}
