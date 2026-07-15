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
          # JWM session startup script
          jwm-session = pkgs.writeShellScriptBin "jwm-session" ''
            # Compositor for transparency and vsync
            ${lib.getExe pkgs.picom} --config /dev/null &
            # Notification daemon
            ${lib.getExe pkgs.dunst} &
            # Network Manager tray applet
            ${lib.getExe pkgs.networkmanagerapplet} &
            # Volume control tray icon
            ${lib.getExe pkgs.volumeicon} &
            # ROX-Filer manages the desktop pinboard and file management
            ${lib.getExe pkgs.rox-filer} -p default &
            # Start JWM window manager
            exec ${lib.getExe pkgs.jwm}
          '';

          # System-wide JWM configuration with styling and keybinds
          jwm-config = pkgs.writeText "system.jwmrc" ''
            <?xml version="1.0"?>
            <JWM>

              <!-- Root Menu (right-click desktop or click Menu button) -->
              <RootMenu onroot="129">
                <Program label="Terminal">${lib.getExe pkgs.sakura}</Program>
                <Program label="NetSurf">${lib.getExe pkgs.netsurf-browser}</Program>
                <Program label="Dillo">${lib.getExe pkgs.dillo}</Program>
                <Program label="Files">${lib.getExe pkgs.rox-filer}</Program>
                <Separator/>
                <Program label="Geany">${lib.getExe pkgs.geany}</Program>
                <Program label="Image Viewer">${lib.getExe pkgs.viewnior}</Program>
                <Program label="PDF Viewer">${lib.getExe pkgs.mupdf}</Program>
                <Separator/>
                <Program label="Media Player">${lib.getExe pkgs.mpv}</Program>
                <Program label="DeaDBeeF">${lib.getExe pkgs.deadbeef}</Program>
                <Separator/>
                <Program label="Archiver">${lib.getExe pkgs.xarchiver}</Program>
                <Program label="Calculator">${lib.getExe pkgs.galculator}</Program>
                <Program label="Task Manager">${lib.getExe pkgs.lxtask}</Program>
                <Program label="Htop">${lib.getExe pkgs.sakura} -e ${lib.getExe pkgs.htop}</Program>
                <Separator/>
                <Program label="Lock Screen">${lib.getExe pkgs.slock}</Program>
                <Restart label="Restart JWM"/>
                <Exit label="Exit Session" confirm="true"/>
              </RootMenu>

              <!-- Bottom Tray / Panel -->
              <Tray x="0" y="-1" height="30" autohide="off" layout="left">
                <TrayButton label="Menu">root:1</TrayButton>
                <Spacer width="4"/>
                <TrayButton label="Term">exec:${lib.getExe pkgs.sakura}</TrayButton>
                <TrayButton label="WWW">exec:${lib.getExe pkgs.netsurf-browser}</TrayButton>
                <TrayButton label="Files">exec:${lib.getExe pkgs.rox-filer}</TrayButton>
                <Spacer width="8"/>
                <TaskList maxwidth="256"/>
                <Spacer/>
                <Dock/>
                <Pager/>
                <Spacer/>
                <Clock format="%H:%M"/>
                <Spacer width="4"/>
                <TrayButton label="Lock">exec:${lib.getExe pkgs.slock}</TrayButton>
              </Tray>

              <!-- Visual Style: clean blue theme -->
              <WindowStyle>
                <Font>Sans-10</Font>
                <Width>4</Width>
                <Height>24</Height>
                <Active>
                  <Text>white</Text>
                  <Title>#4a6a9b</Title>
                  <Corner>#3a5a8b</Corner>
                  <Outline>#2a4a7b</Outline>
                </Active>
                <Inactive>
                  <Text>#aaaaaa</Text>
                  <Title>#888888</Title>
                  <Corner>#777777</Corner>
                  <Outline>#666666</Outline>
                </Inactive>
              </WindowStyle>

              <TrayStyle>
                <Font>Sans-9</Font>
                <Active>
                  <Foreground>white</Foreground>
                  <Background>#4a6a9b</Background>
                </Active>
              </TrayStyle>

              <TaskListStyle>
                <Font>Sans-10</Font>
                <Active>
                  <Foreground>white</Foreground>
                  <Background>#4a6a9b</Background>
                </Active>
                <Inactive>
                  <Foreground>white</Foreground>
                  <Background>#888888</Background>
                </Inactive>
              </TaskListStyle>

              <PopupStyle>
                <Font>Sans-10</Font>
                <Outline>#2a4a7b</Outline>
                <Active>
                  <Foreground>white</Foreground>
                  <Background>#4a6a9b</Background>
                </Active>
                <Inactive>
                  <Foreground>#333333</Foreground>
                  <Background>#f0f0f0</Background>
                </Inactive>
              </PopupStyle>

              <!-- Key bindings -->
              <Key key="F12">exec:${lib.getExe pkgs.gmrun}</Key>
              <Key mask="A" key="F2">exec:${lib.getExe pkgs.gmrun}</Key>
              <Key mask="A" key="F4">close</Key>
              <Key mask="A" key="Tab">nextstacked</Key>
              <Key mask="A" key="space">window</Key>
              <Key mask="CA" key="Right">rdesktop</Key>
              <Key mask="CA" key="Left">ldesktop</Key>
              <Key mask="CA" key="Up">udesktop</Key>
              <Key mask="CA" key="Down">ddesktop</Key>

              <!-- Desktop count -->
              <Desktops width="2" height="2"/>
            </JWM>
          '';

          # Default .xinitrc for startx — deploys to /etc/skel for new users
          xinitrc = pkgs.writeText "xinitrc" ''
            # Load Xresources if present
            [ -f "$HOME/.Xresources" ] && ${lib.getExe pkgs.xorg.xrdb} -merge "$HOME/.Xresources"
            # Start the JWM session
            exec ${lib.getExe jwm-session}
          '';

          # Profile snippet — auto-launch X on tty1 (Puppy-style instant desktop)
          autoX-profile = pkgs.writeText "autoX.sh" ''
            if [ -z "$DISPLAY" ] && [ "$(tty)" = "/dev/tty1" ]; then
              exec ${lib.getExe pkgs.xorg.xinit} -- -nolisten tcp vt1
            fi
          '';

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
                # JWM system-wide config
                "jwm/system.jwmrc".source = jwm-config;
                # Default .xinitrc for new users (via /etc/skel)
                "skel/.xinitrc".source = xinitrc;
                # Auto-start X on tty1 (profile.d snippet)
                "profile.d/autoX.sh".source = autoX-profile;
                # GTK2 system-wide settings
                "gtk-2.0/gtkrc".text = ''
                  gtk-theme-name="Raleigh"
                  gtk-icon-theme-name="Adwaita"
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
                  deadbeef
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

                  # ── Shared MIME & XDG ──
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
              displayManager.startx.enable = mkDefault true;
              xkb.layout = "us";
              xkb.variant = "";
              libinput.enable = mkDefault true;
            };

            # ── Puppy-style Auto-login: boot straight to desktop ────────
            services.getty.autologinUser = cfg.username;

            # ── User nano config activation ─────────────────────────────
            system.activationScripts.nanoUserConfig = ''
              USER_HOME="/home/${cfg.username}"
              if [ -d "$USER_HOME" ]; then
                mkdir -p "$USER_HOME/.config/rox.sourceforge.net/ROX-Filer"
                cp ${xinitrc} "$USER_HOME/.xinitrc"
                chown ${cfg.username}:users "$USER_HOME/.xinitrc"
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
