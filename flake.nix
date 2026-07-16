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
          # System-wide JWM configuration with styling and keybinds. Installed
          # to /etc/jwm/system.jwmrc and loaded via `jwm -f`. Kept as a static
          # project file that references executables via /run/current-system/sw/bin/
          # instead of /nix/store/ paths, so menu/tray entries keep resolving
          # across package updates / GC. Edit ./jwm/system.jwmrc to change it.
          jwm-config = ./jwm/system.jwmrc;

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
                # System-wide JWM config. JWM doesn't look in /etc on its own
                # (its system fallback is the immutable ${pkgs.jwm}/etc/system.jwmrc),
                # so the WM session launches it with `-f /etc/jwm/system.jwmrc`.
                "jwm/system.jwmrc".source = jwm-config;
                # No .xinitrc is deployed: startx.generateScript builds the
                # system-wide /etc/X11/xinit/xinitrc from windowManager.session.
                # GTK2 system-wide settings
                "gtk-2.0/gtkrc".text = ''
                  gtk-theme-name="Raleigh"
                  gtk-icon-theme-name="Papirus"
                  gtk-font-name="Sans 10"
                  gtk-toolbar-style=GTK_TOOLBAR_ICONS
                  gtk-menu-images=1
                  gtk-button-images=1
                '';
                # Allow unfree by default
                "nix/nixpkgs-config.nix".text = lib.mkDefault ''
                  { allowUnfree = true; }
                '';
              };
              # Puppy-style instant desktop: auto-launch X on the tty1 autologin.
              # NixOS does NOT source /etc/profile.d/*.sh, so this must go through
              # loginShellInit (appended to /etc/profile) to actually run. The
              # tty1 + empty-DISPLAY guard keeps it from firing on SSH/pty logins
              # or inside the X session's own terminals. Use `startx` (not bare
              # `xinit`) so it runs the generated /etc/X11/xinit/xinitrc, which
              # sets up the systemd user session and launches windowManager.session.
              loginShellInit = ''
                if [ -z "$DISPLAY" ] && [ "$(tty)" = "/dev/tty1" ]; then
                  exec ${lib.getExe' pkgs.xinit "startx"} -- -nolisten tcp vt1
                fi
              '';
              pathsToLink = [
                "/share/applications"
                "/share/icons"
                "/share/pixmaps"
              ];
              shells = with pkgs; [ bash ];
              variables = {
                EDITOR = "${lib.getExe pkgs.geany}";
                BROWSER = "${lib.getExe pkgs.netsurf-browser}";
                TERMINAL = "${lib.getExe pkgs.sakura}";
                NIXPKGS_ALLOW_UNFREE = "1";
                SQLITE_TMPDIR = "/tmp";
              };
              systemPackages =
                with pkgs;
                [
                  # ── Core Desktop ──
                  jwm
                  rox-filer
                  gmrun
                  picom
                  dunst

                  # ── Terminal ──
                  sakura
                  rxvt-unicode

                  # ── Browsers (NetSurf + FLTK Dillo) ──
                  netsurf-browser
                  dillo

                  # ── Text Editors (GTK2) ──
                  geany

                  # ── File Management ──
                  xarchiver
                  file

                  # ── Media ──
                  mpv
                  volumeicon

                  # ── Images ──
                  feh
                  maim
                  viewnior
                  xclip

                  # ── Documents ──
                  mupdf

                  # ── System Tools ──
                  lxtask
                  htop
                  galculator
                  networkmanagerapplet
                  blueman
                  lxappearance
                  slock
                  which
                  pciutils
                  usbutils

                  # ── Icons & Shared MIME & XDG ──
                  # Papirus supplies the full-colour named icons the JWM menu /
                  # taskbar reference (modern Adwaita dropped most of them); it's
                  # linked into /run/current-system/sw/share/icons via xdg.icons.
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
              libinput.enable = mkDefault true;
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
              polkit = {
                enable = mkDefault true;
                enablePkexecWrapper = mkDefault true;
              };
              rtkit.enable = mkDefault true;
              tpm2.enable = mkDefault false;
            };

            # ── X11 Server ──────────────────────────────────────────────
            services.xserver = {
              enable = true;
              displayManager.startx = {
                enable = mkDefault true;
                # Synthesize /etc/X11/xinit/xinitrc from windowManager.session
                # below, so no ~/.xinitrc has to be copied into user homes.
                generateScript = mkDefault true;
                # Merge user Xresources before the session starts, if present.
                extraCommands = ''
                  [ -f "$HOME/.Xresources" ] && ${lib.getExe pkgs.xrdb} -merge "$HOME/.Xresources"
                '';
              };
              # JWM session. The tray/desktop helper daemons (picom, dunst,
              # nm-applet, volumeicon, rox pinboard) are systemd user services
              # bound to graphical-session.target (see systemd.user.services
              # below), which the generated xinitrc activates before this runs.
              # Here we only launch the window manager — the process the xinitrc
              # `wait`s on; JWM's config lives at /etc/jwm/system.jwmrc (it never
              # reads /etc on its own, so pass it explicitly with -f).
              windowManager.session = [
                {
                  name = "jwm";
                  start = ''
                    ${lib.getExe pkgs.jwm} -f /etc/jwm/system.jwmrc &
                    waitPID=$!
                  '';
                }
              ];
              xkb.layout = "us";
              xkb.variant = "";
            };

            # ── Desktop session services ────────────────────────────────
            # Tray/desktop helpers run as systemd user services tied to
            # graphical-session.target (activated by the generated xinitrc via
            # nixos-fake-graphical-session.target, which BindsTo it). This gives
            # them restart-on-crash, ordering and clean teardown on session exit
            # instead of the old `& … kill 0` juggling. DISPLAY is imported into
            # the user manager by the xinitrc, and startx registers the X cookie
            # in the default ~/.Xauthority, so no extra env import is needed.
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
                picom = sessionService "Picom compositor (transparency & vsync)" "${lib.getExe pkgs.picom} --config /dev/null";
                dunst = sessionService "Dunst notification daemon" (lib.getExe pkgs.dunst);
                nm-applet = sessionService "NetworkManager tray applet" (lib.getExe pkgs.networkmanagerapplet);
                volumeicon = sessionService "Volume control tray icon" (lib.getExe pkgs.volumeicon);
                # ROX-Filer manages the desktop pinboard (desktop icons).
                rox-pinboard = sessionService "ROX-Filer desktop pinboard" "${lib.getExe pkgs.rox-filer} -p default";
              };

            # ── Puppy-style Auto-login: boot straight to desktop ────────
            services.getty.autologinUser = cfg.username;

            # ── User nano config activation ─────────────────────────────
            # X startup no longer needs a per-user ~/.xinitrc (startx uses the
            # generated /etc/X11/xinit/xinitrc); this just seeds ROX-Filer's
            # config dir so the pinboard/desktop is writable on first login.
            system.activationScripts.nanoUserConfig = ''
              USER_HOME="/home/${cfg.username}"
              if [ -d "$USER_HOME" ]; then
                mkdir -p "$USER_HOME/.config/rox.sourceforge.net/ROX-Filer"
                chown -R ${cfg.username}:users "$USER_HOME/.config"
              fi
            '';

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
                config = {
                  common = {
                    default = [ "gtk" ];
                    "org.freedesktop.impl.portal.FileChooser" = "gtk";
                    "org.freedesktop.impl.portal.Notification" = "gtk";
                    "org.freedesktop.impl.portal.OpenURI" = "gtk";
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
