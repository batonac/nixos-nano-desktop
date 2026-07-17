{
  description = "NixOS Nano Desktop";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nixos-install-helper = {
      url = "github:Avunu/nixos-install-helper";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.disko.follows = "disko";
    };
  };

  outputs =
    { self, nixpkgs, ... }@inputs:
    let
      lib = nixpkgs.lib;
      system = "x86_64-linux";

      # Public-facing installer: derives its menu from nanoDesktop.* and ships
      # unattended / guided ISOs plus a nixos-anywhere deploy. The whole
      # installer surface is this one call.
      ih = inputs.nixos-install-helper.lib.mkProject {
        inherit nixpkgs system self;
        installModules = [ self.nixosModules.nanoDesktop ];
        optionRoots = [ "nanoDesktop" ];
        flakeStyle = "local";
        upstream = "github:batonac/nixos-nano-desktop";
        diskName = "main";
        hints = {
          diskDevice = "disk-device";
        };
      };
    in
    {
      devShells.x86_64-linux.default =
        let
          pkgs = nixpkgs.legacyPackages.x86_64-linux;
        in
        pkgs.mkShell {
          packages = [
            pkgs.mcp-nixos
          ];
        };
      nixosModules.nanoDesktop =
        {
          config,
          lib,
          pkgs,
          ...
        }:
        with lib;
        let
          cfg = config.nanoDesktop;
          # Wayland desktop config lives in static project files under ./labwc
          # and ./sfwbar, installed into /etc/xdg and loaded explicitly
          # (`labwc -C /etc/xdg/labwc`, `sfwbar -f /etc/xdg/sfwbar/sfwbar.config`).
          # They reference executables via /run/current-system/sw/bin/ rather
          # than /nix/store/ paths, so menu/panel entries keep resolving across
          # package updates / GC. Edit those files to change the desktop.

          # Screenshot helper: grim (+ slurp for a region) → save to Pictures
          # and copy to the clipboard. Bound to Print / Shift-Print in labwc
          # (labwc's Execute has no shell, so the grim+slurp pipe needs a script).
          nano-screenshot = pkgs.writeShellApplication {
            name = "nano-screenshot";
            runtimeInputs = with pkgs; [
              grim
              slurp
              wl-clipboard
              libnotify
              coreutils
            ];
            text = ''
              mode="''${1:-full}"
              dir="''${XDG_PICTURES_DIR:-$HOME/Pictures}"
              mkdir -p "$dir"
              file="$dir/screenshot-$(date +%Y%m%d-%H%M%S).png"
              if [ "$mode" = "region" ]; then
                grim -g "$(slurp)" "$file"
              else
                grim "$file"
              fi
              wl-copy < "$file"
              notify-send "Screenshot saved" "$file"
            '';
          };

          # Minimal system upgrade script (no timers, manual invocation only)
          systemUpgradeScript = pkgs.writeShellApplication {
            name = "system-upgrade";
            runtimeInputs = with pkgs; [
              coreutils
              git
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
              else
                echo "Flake lock unchanged, skipping rebuild" >&2
              fi
            '';
          };
        in
        {
          imports = [
            inputs.disko.nixosModules.disko
          ];

          options.nanoDesktop = {
            hostName = mkOption {
              type = types.str;
              description = "Hostname for the system";
            };
            diskDevice = mkOption {
              type = types.str;
              default = "/dev/sda";
              description = "Disk device for installation";
            };
            bootMode = mkOption {
              type = types.enum [
                "uefi"
                "legacy"
              ];
              default = "uefi";
              description = "Boot mode: uefi (systemd-boot) or legacy (GRUB)";
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
              description = "Primary user name";
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
            extraPackages = mkOption {
              type = types.listOf types.package;
              default = [ ];
              description = "Additional packages to install";
            };
            enableSsh = mkOption {
              type = types.bool;
              default = false;
              description = "Enable SSH server";
            };
            sshPasswordAuth = mkOption {
              type = types.bool;
              default = true;
              description = "Allow password authentication for SSH";
            };
            sshRootLogin = mkOption {
              type = types.str;
              default = "yes";
              description = "Permit root login via SSH";
            };
          };

          config = {
            # ── Boot ────────────────────────────────────────────────────
            boot = {
              initrd = {
                availableKernelModules = [
                  "ahci"
                  "ehci_pci"
                  "nvme"
                  "uhci_hcd"
                ];
                systemd.enable = mkDefault true;
                verbose = mkDefault false;
              };
              kernelPackages = mkDefault pkgs.linuxPackages_latest;
              kernelParams = [
                "boot.shell_on_fail"
                "console=tty0"
                "loglevel=3"
                "mem_sleep_default=deep"
                "pcie_aspm.policy=powersupersave"
                "quiet"
                "rd.systemd.show_status=false"
                "systemd.show_status=false"
                "rd.udev.log_level=3"
                "udev.log_priority=3"
              ];
              kernel.sysctl = {
                "vm.swappiness" = mkDefault 100;
                "vm.vfs_cache_pressure" = mkDefault 50;
                "vm.page-cluster" = mkDefault 0;
              };
              consoleLogLevel = mkDefault 0;
              loader = mkMerge [
                (mkIf (cfg.bootMode == "uefi") {
                  efi.canTouchEfiVariables = mkDefault true;
                  systemd-boot = {
                    configurationLimit = mkDefault 10;
                    enable = mkDefault true;
                  };
                })
                (mkIf (cfg.bootMode == "legacy") {
                  grub = {
                    enable = mkDefault true;
                  };
                })
                ({ timeout = mkDefault 2; })
              ];
              supportedFilesystems = {
                ext3 = mkDefault false;
                ntfs3 = mkDefault false;
                xfs = mkDefault false;
                zfs = mkDefault false;
              };
              swraid.enable = mkDefault false;
              tmp = {
                useTmpfs = mkDefault true;
                tmpfsSize = mkDefault "50%";
              };
            };

            # ── Console ─────────────────────────────────────────────────
            console = {
              keyMap = mkDefault "us";
              packages = [ pkgs.terminus_font ];
            };

            # ── Disk Layout (disko) ─────────────────────────────────────
            disko.devices = mkDefault {
              disk.main = {
                device = cfg.diskDevice;
                type = "disk";
                content = mkMerge [
                  (mkIf (cfg.bootMode == "uefi") {
                    type = "gpt";
                    partitions = {
                      ESP = {
                        size = "512M";
                        type = "EF00";
                        content = {
                          type = "filesystem";
                          format = "vfat";
                          mountpoint = "/boot";
                          mountOptions = [
                            "noatime"
                            "umask=0077"
                          ];
                          extraArgs = [
                            "-n"
                            "ESP"
                          ];
                        };
                      };
                      swap = {
                        size = "8G";
                        content = {
                          type = "swap";
                          resumeDevice = true;
                        };
                      };
                      root = {
                        size = "100%";
                        content = {
                          type = "filesystem";
                          format = "f2fs";
                          mountpoint = "/";
                          mountOptions = [
                            "atgc"
                            "compress_algorithm=zstd:1" # Level 1: minimal CPU overhead, reduces I/O bandwidth
                            "compress_cache" # Cache decompressed pages for hot data (SQLite, desktop apps)
                            "compress_chksum"
                            "compress_extension=*" # Compress all files by default
                            # ...except frequently-rewritten small WAL/journal/lock files: recompressing
                            # a whole cluster on every tiny in-place-ish rewrite (SQLite/LevelDB WAL,
                            # systemd journal) is a known GC/checkpoint stall pattern under f2fs, worst
                            # when the volume is mostly full. See linux-f2fs-devel deadlock reports.
                            # f2fs mount options are comma-split at the top level, so each excluded
                            # extension needs its own repeated nocompress_extension=... entry — a single
                            # comma-joined value gets torn into unrecognized tokens and fails root mount.
                            # Each extension is also capped at 7 chars (F2FS_EXTENSION_LEN=8 incl. NUL) —
                            # "sqlite-wal"/"sqlite-shm" (10 chars) overflow that and get rejected with
                            # "invalid extension length/number", failing the mount entirely. Omitted below;
                            # rely on the shorter db-wal/db-shm convention instead.
                            "nocompress_extension=db"
                            "nocompress_extension=db-wal"
                            "nocompress_extension=db-shm"
                            "nocompress_extension=sqlite"
                            "nocompress_extension=ldb"
                            "nocompress_extension=log"
                            "nocompress_extension=journal"
                            "nocompress_extension=lock"
                            "gc_merge"
                            "noatime"
                            "nodiscard" # Use scheduled fstrim instead of synchronous discard
                          ];
                          extraArgs = [
                            "-O"
                            "extra_attr,compression"
                            "-l"
                            "root"
                          ];
                        };
                      };
                    };
                  })
                  (mkIf (cfg.bootMode == "legacy") {
                    type = "gpt";
                    partitions = {
                      boot = {
                        size = "1M";
                        type = "EF02";
                      };
                      # GRUB's f2fs driver cannot read f2fs transparent
                      # compression, so /boot/grub must not live on the
                      # compressed f2fs root. A small ext4 /boot keeps GRUB's
                      # modules on a filesystem it can read natively.
                      esp = {
                        size = "512M";
                        type = "EF00";
                        content = {
                          type = "filesystem";
                          format = "ext4";
                          mountpoint = "/boot";
                          mountOptions = [ "noatime" ];
                        };
                      };
                      swap = {
                        size = "8G";
                        content = {
                          type = "swap";
                          resumeDevice = true;
                        };
                      };
                      root = {
                        size = "100%";
                        content = {
                          type = "filesystem";
                          format = "f2fs";
                          mountpoint = "/";
                          mountOptions = [
                            "atgc"
                            "compress_algorithm=zstd:1"
                            "compress_extension=*"
                            "gc_merge"
                            "noatime"
                            "nodiscard"
                          ];
                          extraArgs = [
                            "-O"
                            "extra_attr,compression"
                            "-l"
                            "root"
                          ];
                        };
                      };
                    };
                  })
                ];
              };
            };

            # ── Documentation ───────────────────────────────────────────
            documentation = {
              enable = mkDefault false;
              doc.enable = mkDefault false;
              man.enable = mkDefault false;
              nixos.enable = mkDefault false;
            };

            # ── Environment ─────────────────────────────────────────────
            environment = {
              etc = {
                # System-wide labwc config, loaded via `labwc -C /etc/xdg/labwc`
                # (labwc's only other source is the immutable in-store default,
                # so we point it at /etc explicitly). autostart must be +x.
                "xdg/labwc/rc.xml".source = ./labwc/rc.xml;
                "xdg/labwc/menu.xml".source = ./labwc/menu.xml;
                "xdg/labwc/environment".source = ./labwc/environment;
                "xdg/labwc/themerc-override".source = ./labwc/themerc-override;
                "xdg/labwc/autostart" = {
                  source = ./labwc/autostart;
                  mode = "0755";
                };
                # System-wide Sfwbar panel, loaded via `sfwbar -f`. The sibling
                # sfwbar.css is auto-loaded by Sfwbar from the same directory.
                "xdg/sfwbar/sfwbar.config".source = ./sfwbar/sfwbar.config;
                "xdg/sfwbar/sfwbar.css".source = ./sfwbar/sfwbar.css;
                # GTK3/GTK4 system-wide settings. /etc/xdg is on XDG_CONFIG_DIRS,
                # so GTK apps pick up the icon/cursor/font theme from here.
                "xdg/gtk-3.0/settings.ini".text = ''
                  [Settings]
                  gtk-theme-name=Adwaita
                  gtk-icon-theme-name=Papirus
                  gtk-cursor-theme-name=Vanilla-DMZ
                  gtk-cursor-theme-size=24
                  gtk-font-name=Sans 10
                '';
                "xdg/gtk-4.0/settings.ini".text = ''
                  [Settings]
                  gtk-theme-name=Adwaita
                  gtk-icon-theme-name=Papirus
                  gtk-cursor-theme-name=Vanilla-DMZ
                  gtk-cursor-theme-size=24
                  gtk-font-name=Sans 10
                '';
                # Allow unfree by default
                "nix/nixpkgs-config.nix".text = lib.mkDefault ''
                  { allowUnfree = true; }
                '';
              };
              # Puppy-style instant desktop: auto-launch labwc on the tty1
              # autologin. NixOS does NOT source /etc/profile.d/*.sh, so this must
              # go through loginShellInit (appended to /etc/profile). The tty1 +
              # empty-WAYLAND_DISPLAY guard keeps it from firing on SSH/pty logins
              # or inside the session's own terminals. No `exec`: when labwc exits
              # we stop the session target (clean teardown of the helper services)
              # and drop the login shell, so getty re-logs-in and relaunches it.
              loginShellInit = ''
                if [ -z "$WAYLAND_DISPLAY" ] && [ "$(tty)" = "/dev/tty1" ]; then
                  ${pkgs.labwc}/bin/labwc -C /etc/xdg/labwc
                  ${pkgs.systemd}/bin/systemctl --user stop graphical-session.target
                  exit
                fi
              '';
              pathsToLink = [
                "/share/applications"
                "/share/icons"
                "/share/pixmaps"
                "/share/sfwbar"
              ];
              shells = with pkgs; [ bash ];
              variables = {
                EDITOR = "${lib.getExe pkgs.geany}";
                BROWSER = "${lib.getExe pkgs.epiphany}";
                TERMINAL = "${lib.getExe pkgs.foot}";
                NIXPKGS_ALLOW_UNFREE = "1";
                SQLITE_TMPDIR = "/tmp";
              };
              # Wayland enforcement + appearance. GDK_BACKEND=wayland removes the
              # X fallback, so any X-only GTK app hard-fails instead of silently
              # spinning up XWayland — the behaviour we want on a Wayland-only box.
              sessionVariables = {
                NIXOS_OZONE_WL = "1";
                GDK_BACKEND = "wayland";
                QT_QPA_PLATFORM = "wayland";
                SDL_VIDEODRIVER = "wayland";
                CLUTTER_BACKEND = "wayland";
                MOZ_ENABLE_WAYLAND = "1";
                XDG_CURRENT_DESKTOP = "labwc";
                XCURSOR_THEME = "Vanilla-DMZ";
                XCURSOR_SIZE = "24";
                _JAVA_AWT_WM_NONREPARENTING = "1";
              };
              systemPackages =
                with pkgs;
                [
                  # ── Compositor + panel ──
                  labwc
                  sfwbar

                  # ── Terminal + launcher ──
                  foot
                  fuzzel

                  # ── Browser (Epiphany / GNOME Web, WebKitGTK) ──
                  epiphany

                  # ── Text editor (GTK3) ──
                  geany

                  # ── File management ──
                  pcmanfm
                  xarchiver # GTK3 in nixpkgs — Wayland-native
                  file

                  # ── Media / images / documents ──
                  mpv
                  imv
                  zathura # top-level attr bundles the mupdf backend

                  # ── Notifications ──
                  mako

                  # ── Screenshot / clipboard / lock ──
                  grim
                  slurp
                  wl-clipboard
                  swaylock
                  nano-screenshot

                  # ── Volume / brightness ──
                  swayosd
                  pavucontrol
                  brightnessctl

                  # ── Tray applets (StatusNotifierItem) ──
                  networkmanagerapplet
                  blueman

                  # ── System tools ──
                  lxtask
                  htop
                  galculator
                  which
                  pciutils
                  usbutils

                  # ── Cursor / icons / MIME / XDG ──
                  # Papirus supplies the full-colour named icons the labwc menu /
                  # Sfwbar panel reference. Vanilla-DMZ is the cursor theme —
                  # Wayland has no server-side default cursor.
                  vanilla-dmz
                  papirus-icon-theme
                  hicolor-icon-theme
                  shared-mime-info
                  xdg-user-dirs
                  xdg-utils

                  # ── Upgrade script ──
                  systemUpgradeScript
                ]
                ++ cfg.extraPackages;
            };

            # ── Filesystems ─────────────────────────────────────────────
            fileSystems."/".noCheck = mkDefault true;

            # ── Fonts (minimal, fast) ───────────────────────────────────
            fonts = {
              enableDefaultPackages = mkForce false;
              fontDir.enable = mkDefault true;
              packages = with pkgs; [
                dejavu_fonts
                liberation_ttf
                noto-fonts-color-emoji
                source-code-pro
              ];
              fontconfig = {
                enable = true;
                defaultFonts = {
                  sansSerif = [
                    "DejaVu Sans"
                    "Liberation Sans"
                  ];
                  serif = [
                    "DejaVu Serif"
                    "Liberation Serif"
                  ];
                  monospace = [
                    "DejaVu Sans Mono"
                    "Liberation Mono"
                    "Source Code Pro"
                  ];
                  emoji = [ "Noto Color Emoji" ];
                };
              };
            };

            # ── Power Management ────────────────────────────────────────
            powerManagement = {
              enable = mkDefault true;
              powertop.enable = mkDefault false;
            };

            # ── Hardware ────────────────────────────────────────────────
            hardware = {
              bluetooth.enable = mkDefault true;
              enableRedistributableFirmware = mkDefault true;
              graphics = {
                enable = true;
                extraPackages = with pkgs; [ mesa ];
              };
              sane = {
                enable = mkDefault true;
                extraBackends = with pkgs; [
                  sane-airscan
                  sane-backends
                ];
              };
              sensor.iio.enable = mkDefault false;
            };

            # ── Networking ──────────────────────────────────────────────
            networking = {
              hostName = cfg.hostName;
              networkmanager = {
                enable = mkDefault true;
              };
              firewall = {
                enable = mkDefault false;
                allowedTCPPorts = [
                  7236
                  7250
                ];
                allowedUDPPorts = [
                  7236
                  5353
                ];
              };
            };

            # ── Nix Configuration ───────────────────────────────────────
            nix = {
              gc = {
                automatic = mkDefault true;
                dates = mkDefault "weekly";
                options = mkDefault "--delete-older-than 7d";
              };
              settings = {
                auto-optimise-store = true;
                experimental-features = [
                  "nix-command"
                  "flakes"
                  "cgroups"
                ];
                substituters = [
                  "https://cache.nixos.org?priority=40"
                ];
                trusted-public-keys = [
                  "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
                ];
                trusted-users = [
                  "root"
                  cfg.username
                  "@wheel"
                ];
                use-cgroups = true;
                use-xdg-base-directories = true;
              };
            };

            # ── nixpkgs ─────────────────────────────────────────────────
            nixpkgs.config = {
              allowBroken = true;
              allowUnfree = true;
              allowUnfreePredicate = _: true;
            };

            # ── Programs ────────────────────────────────────────────────
            programs = {
              # dconf/GSettings backend — GNOME apps (Epiphany) need it to
              # persist settings (bookmarks, prefs).
              dconf.enable = mkDefault true;
              git = {
                enable = true;
                config.safe.directory = [ "/etc/nixos" ];
              };
              nix-ld = {
                enable = mkDefault true;
                package = pkgs.nix-ld;
                libraries = with pkgs; [
                  glib
                  libxkbcommon
                  openssl
                  zstd
                ];
              };
            };

            # ── Services ────────────────────────────────────────────────
            services = {
              accounts-daemon.enable = mkDefault true;
              avahi = {
                enable = mkDefault true;
                nssmdns4 = mkDefault true;
                nssmdns6 = mkDefault true;
                publish = {
                  addresses = mkDefault true;
                  enable = mkDefault true;
                  workstation = mkDefault true;
                };
              };
              blueman.enable = mkDefault true;
              bpftune.enable = mkDefault false;
              dbus = {
                implementation = mkDefault "broker";
                packages = with pkgs; [ ];
              };
              fstrim = {
                enable = mkDefault true;
                interval = mkDefault "daily";
              };
              gvfs = {
                enable = mkDefault true;
                package = mkDefault pkgs.gnome.gvfs;
              };
              pipewire = {
                enable = mkDefault true;
                alsa.enable = mkDefault true;
                pulse.enable = mkDefault true;
              };
              power-profiles-daemon.enable = mkDefault true;
              printing = {
                enable = mkDefault true;
                browsed.enable = mkDefault true;
                webInterface = mkDefault false;
              };
              samba-wsdd.discovery = mkDefault true;
              # brightnessctl udev rules so the video group can set backlight
              # (and swayosd/media keys work without root).
              udev.packages = with pkgs; [ brightnessctl ];
              udisks2.enable = mkDefault true;
              upower.enable = mkDefault true;
            };

            # ── SSH ─────────────────────────────────────────────────────
            services.openssh = mkIf cfg.enableSsh {
              enable = true;
              settings = {
                PermitRootLogin = cfg.sshRootLogin;
                PasswordAuthentication = cfg.sshPasswordAuth;
              };
            };

            # ── Security ────────────────────────────────────────────────
            security = {
              # swaylock needs a PAM service to authenticate the unlock.
              pam.services.swaylock = { };
              polkit = {
                enable = mkDefault true;
                enablePkexecWrapper = mkDefault true;
              };
              rtkit.enable = mkDefault true;
              tpm2.enable = mkDefault false;
            };

            # ── Wayland session ─────────────────────────────────────────
            # No display-server config: labwc is launched directly from the tty1
            # login shell (see environment.loginShellInit). labwc's autostart
            # imports the Wayland env into D-Bus + the systemd user manager and
            # starts nano-session.target, which BindsTo graphical-session.target
            # (the sway-session.target pattern): it pulls in the helper user
            # services below and tears them down cleanly when labwc exits.
            systemd.user.targets.nano-session = {
              description = "Nano desktop session";
              documentation = [ "man:systemd.special(7)" ];
              bindsTo = [ "graphical-session.target" ];
              wants = [ "graphical-session-pre.target" ];
              after = [ "graphical-session-pre.target" ];
            };

            # Panel / tray / notification / OSD helpers as systemd user services
            # bound to graphical-session.target: restart-on-crash, ordering and
            # clean teardown (vs the old `& … kill 0` juggling). nm-applet runs
            # with --indicator so it exposes a StatusNotifierItem for Sfwbar's SNI
            # tray (there is no XEmbed system tray under Wayland).
            systemd.user.services =
              let
                sessionService = description: exec: {
                  inherit description;
                  partOf = [ "graphical-session.target" ];
                  after = [ "graphical-session.target" ];
                  wantedBy = [ "graphical-session.target" ];
                  serviceConfig = {
                    ExecStart = exec;
                    Restart = "on-failure";
                    RestartSec = 1;
                  };
                };
              in
              {
                sfwbar = sessionService "Sfwbar panel" "${pkgs.sfwbar}/bin/sfwbar -f /etc/xdg/sfwbar/sfwbar.config";
                mako = sessionService "Mako notification daemon" "${pkgs.mako}/bin/mako";
                swayosd = sessionService "SwayOSD server (volume/brightness OSD)" "${pkgs.swayosd}/bin/swayosd-server";
                nm-applet = sessionService "NetworkManager tray applet" "${pkgs.networkmanagerapplet}/bin/nm-applet --indicator";
                blueman-applet = sessionService "Blueman tray applet" "${pkgs.blueman}/bin/blueman-applet";
              };

            # ── Puppy-style Auto-login: boot straight to desktop ────────
            services.getty.autologinUser = cfg.username;

            # ── System ──────────────────────────────────────────────────
            system = {
              stateVersion = cfg.stateVersion;
              autoUpgrade.enable = mkDefault false;
            };

            # ── Time & Locale ───────────────────────────────────────────
            time.timeZone = cfg.timeZone;
            i18n.defaultLocale = cfg.locale;

            # ── Users ───────────────────────────────────────────────────
            users = {
              defaultUserShell = pkgs.bash;
              users.${cfg.username} = {
                extraGroups = [
                  "input"
                  "networkmanager"
                  "wheel"
                  "audio"
                  "video"
                ];
                initialPassword = cfg.initialPassword;
                isNormalUser = true;
                useDefaultShell = true;
              };
            };

            # ── XDG ─────────────────────────────────────────────────────
            xdg = {
              autostart.enable = mkDefault true;
              icons.enable = mkDefault true;
              menus.enable = mkDefault true;
              mime.enable = mkDefault true;
              portal = {
                enable = mkDefault true;
                extraPortals = with pkgs; [
                  xdg-desktop-portal-gtk
                ];
                # Only the GTK portal is installed (FileChooser / Notification /
                # OpenURI / Settings). XDG_CURRENT_DESKTOP=labwc, so key the labwc
                # profile to gtk too — labwc ships a wlr-preferring default we
                # don't want here (no wlroots portal installed; screenshots use
                # grim/slurp directly, which need no portal).
                config = {
                  common = {
                    default = [ "gtk" ];
                    "org.freedesktop.impl.portal.FileChooser" = [ "gtk" ];
                    "org.freedesktop.impl.portal.Notification" = [ "gtk" ];
                    "org.freedesktop.impl.portal.OpenURI" = [ "gtk" ];
                  };
                  labwc = {
                    default = [ "gtk" ];
                  };
                };
              };
              sounds.enable = mkDefault true;
            };

            # ── zram ────────────────────────────────────────────────────
            zramSwap.enable = mkDefault true;
          };
        };

      # ── Installer (via nixos-install-helper) ─────────────────────────────────
      # install / installTemplate systems, the unattended + guided ISOs, and the
      # configure / install / deploy apps — all derived from nanoDesktop.*.
      nixosConfigurations = ih.nixosConfigurations;
      packages = ih.packages;
      apps = ih.apps;
    };
}
