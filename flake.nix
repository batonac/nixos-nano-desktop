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
          # GLib searches <dir>/glib-2.0/schemas/gschemas.compiled along
          # XDG_DATA_DIRS; nixpkgs relocates schemas to this per-package prefix
          # (wrapped apps get it injected by wrapGAppsHook, unwrapped ones need
          # it in the environment — see sessionVariables / DefaultEnvironment).
          gsettingsSchemaDir = "${pkgs.gsettings-desktop-schemas}/share/gsettings-schemas/${pkgs.gsettings-desktop-schemas.name}";
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

          # Clipboard-history picker with paste-on-select (bound to Super+V in
          # labwc rc.xml). cursor-clip's overlay exits identically (code 0) for
          # both "picked an entry" and "dismissed", so selection is detected by
          # comparing clipboard content before/after the overlay: a change means
          # an entry was chosen, and wtype synthesizes Ctrl+V (labwc implements
          # the virtual-keyboard protocol) into the refocused window. Dismissing
          # pastes nothing. Picking the entry that already IS the clipboard also
          # pastes nothing (no change to detect) — plain Ctrl+V covers that.
          nano-clipboard = pkgs.writeShellApplication {
            name = "nano-clipboard";
            runtimeInputs = with pkgs; [
              coreutils
              cursor-clip
              wl-clipboard
              wtype
            ];
            text = ''
              before=$( (wl-paste 2>/dev/null || true) | sha256sum)
              cursor-clip
              # Let the daemon re-announce the picked entry and labwc refocus
              # the previous window before reading + pasting.
              sleep 0.15
              after=$( (wl-paste 2>/dev/null || true) | sha256sum)
              if [ "$before" != "$after" ]; then
                wtype -M ctrl v -m ctrl
              fi
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
          };

          # tty1 desktop launcher (run by the nano-desktop systemd service). Pulls
          # in the NixOS session environment (environment.variables +
          # sessionVariables — GDK_BACKEND, cursor/theme vars, …) via
          # /etc/set-environment, then starts labwc. No autostart script: labwc
          # natively pushes the runtime session vars (WAYLAND_DISPLAY, DISPLAY,
          # XDG_CURRENT_DESKTOP, XDG_SESSION_TYPE, XCURSOR_*) into the D-Bus
          # activation environment and the systemd user manager at startup, and
          # the static remainder is declared once in
          # systemd.user.settings.Manager.DefaultEnvironment (see below). `-s`
          # runs after the compositor (and that env push) is up: it starts
          # nano-session.target, which pulls in the panel/tray/notification
          # helpers; it re-runs on every respawn (Restart=always), same as the
          # old autostart. No `exec`: the trailing stop is the clean-teardown
          # step when labwc exits.
          nanoDesktopLauncher = pkgs.writeShellScript "nano-desktop-launch" ''
            if [ -r /etc/set-environment ]; then
              . /etc/set-environment
            fi
            ${pkgs.labwc}/bin/labwc -C /etc/xdg/labwc \
              -s "/run/current-system/sw/bin/systemctl --user start nano-session.target"
            ${pkgs.systemd}/bin/systemctl --user stop graphical-session.target
          '';

          # labwc titlebar theme carrying the GNOME/Adwaita window-button icons.
          # labwc finds button images by theme name on XDG_DATA_DIRS/themes, so
          # the SVGs must live in share/themes (linked via pathsToLink) rather
          # than /etc/xdg. rc.xml references it as <theme><name>NanoAdwaita.
          # Inactive-window buttons are derived from the active SVGs by dimming
          # (white → the inactive label grey), so only the active icons are
          # kept in-tree under ./labwc/theme.
          nanoLabwcTheme = pkgs.runCommand "nano-labwc-theme" { } ''
            dst=$out/share/themes/NanoAdwaita/labwc
            mkdir -p "$dst"
            cp ${./labwc/theme/NanoAdwaita/labwc}/themerc "$dst/"
            for f in ${./labwc/theme/NanoAdwaita/labwc}/*-active.svg; do
              base=$(basename "$f" -active.svg)
              cp "$f" "$dst/$base-active.svg"
              sed -e 's/#ffffff/#9a9a9a/g' \
                  -e 's/fill-opacity="0.09"/fill-opacity="0.05"/g' \
                  "$f" > "$dst/$base-inactive.svg"
            done
          '';
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
                # so we point it at /etc explicitly). No autostart/environment
                # files anymore: session startup is the launcher's `-s` flag,
                # runtime env comes from labwc's native import, and static env
                # is declared in systemd.user.settings.Manager.DefaultEnvironment.
                # XKB layout defaults to "us" inside xkbcommon; set
                # environment.sessionVariables.XKB_DEFAULT_LAYOUT to change it.
                "xdg/labwc/rc.xml".source = ./labwc/rc.xml;
                "xdg/labwc/menu.xml".source = ./labwc/menu.xml;
                "xdg/labwc/themerc-override".source = ./labwc/themerc-override;
                # System-wide Sfwbar panel, loaded via `sfwbar -f`. The sibling
                # sfwbar.css is auto-loaded by Sfwbar from the same directory.
                "xdg/sfwbar/sfwbar.config".source = ./sfwbar/sfwbar.config;
                "xdg/sfwbar/sfwbar.css".source = ./sfwbar/sfwbar.css;
                # foot terminal — Adwaita Mono + GNOME/Adwaita dark palette. foot
                # reads it from XDG_CONFIG_DIRS (/etc/xdg), like the gtk configs.
                "xdg/foot/foot.ini".source = ./foot/foot.ini;
                # fuzzel launcher (Super+Space + F12/Alt-F2), Adwaita-dark.
                "xdg/fuzzel/fuzzel.ini".source = ./fuzzel/fuzzel.ini;
                # PCManFM/libfm: point "Open Terminal" and open-in-terminal
                # actions at foot (libfm defaults to an unset terminal → the
                # "terminal emulator is not set" error). foot is not in libfm's
                # terminals.list, so libfm falls back to `foot -e <cmd>`; foot
                # accepts and ignores -e (xterm compat), so this works for both
                # bare "Open Terminal" and execute-in-terminal.
                "xdg/libfm/libfm.conf".text = ''
                  [config]
                  terminal=foot
                '';
                # mako notifications — Adwaita-dark, GNOME-style. mako only
                # auto-reads ~/.config/mako/config, so the service loads this
                # explicitly with `--config` (see systemd.user.services.mako).
                "xdg/mako/config".source = ./mako/config;
                # GTK3/GTK4 system-wide settings. /etc/xdg is on XDG_CONFIG_DIRS,
                # so GTK apps pick up the theme/icon/cursor/font from here. The
                # modern-Adwaita-dark default: GTK3 → adw-gtk3-dark, GTK4 → the
                # built-in Adwaita forced dark via prefer-dark. The locked dconf
                # profile (programs.dconf below) is the authoritative source for
                # GNOME/libadwaita apps; these files cover non-dconf GTK apps.
                "xdg/gtk-3.0/settings.ini".text = ''
                  [Settings]
                  gtk-theme-name=adw-gtk3-dark
                  gtk-icon-theme-name=Papirus-Dark
                  gtk-cursor-theme-name=Adwaita
                  gtk-cursor-theme-size=24
                  gtk-font-name=Adwaita Sans 11
                  gtk-application-prefer-dark-theme=1
                '';
                "xdg/gtk-4.0/settings.ini".text = ''
                  [Settings]
                  gtk-theme-name=Adwaita
                  gtk-icon-theme-name=Papirus-Dark
                  gtk-cursor-theme-name=Adwaita
                  gtk-cursor-theme-size=24
                  gtk-font-name=Adwaita Sans 11
                  gtk-application-prefer-dark-theme=1
                '';
                # Allow unfree by default
                "nix/nixpkgs-config.nix".text = lib.mkDefault ''
                  { allowUnfree = true; }
                '';
              };
              # Desktop launch is no longer wired through the login shell — a
              # dedicated systemd service (systemd.services.nano-desktop) owns tty1
              # and starts the session. See the "Wayland session" block below.
              pathsToLink = [
                "/share/applications"
                "/share/icons"
                "/share/pixmaps"
                "/share/sfwbar"
                # GTK themes (adw-gtk3-dark). Sfwbar runs as a systemd user
                # service whose XDG_DATA_DIRS is /run/current-system/sw/share;
                # without this link the adw-gtk3-dark theme is absent there and
                # GTK falls back to the built-in *light* Adwaita. Its popup
                # menus (Start / window-ops / tray) then render light while the
                # panel CSS forces label text white — white-on-light = an
                # unreadable "blank" menu. Linking themes lets the settings.ini
                # gtk-theme-name (adw-gtk3-dark) resolve for GTK3 services.
                "/share/themes"
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
                # gsettings-desktop-schemas first: unwrapped GTK/libadwaita apps
                # (e.g. image-roll — a bare binary, no wrapGAppsHook) need the
                # org.gnome.* compiled schemas findable on XDG_DATA_DIRS, else
                # GLib's default schema source is NULL and every GSettings
                # lookup logs "g_settings_schema_source_lookup: assertion
                # 'source != NULL' failed".
                XDG_DATA_DIRS = "${gsettingsSchemaDir}:/run/current-system/sw/share";
                XDG_ICON_DIRS = "/run/current-system/sw/share/icons";
                XCURSOR_THEME = "Adwaita";
                XCURSOR_SIZE = "24";
                # Select lxmenu-data's lxde-applications.menu for menu-cache
                # (PCManFM's "Open With" app list). menu-cache reads
                # ''${XDG_MENU_PREFIX}applications.menu from XDG_CONFIG_DIRS/menus,
                # and lxmenu-data installs it as lxde-applications.menu.
                XDG_MENU_PREFIX = "lxde-";
                # NO GTK_THEME here — deliberately. GTK_THEME does NOT only
                # affect GTK3: libadwaita defers to the named theme instead of
                # applying its own color-scheme-aware stylesheet, and since
                # adw-gtk3 ships no gtk-4.0 CSS, GTK4/libadwaita apps then fall
                # back to the default *light* Adwaita (verified with image-roll:
                # light with GTK_THEME set, dark without). GTK3 apps already get
                # adw-gtk3-dark from /etc/xdg/gtk-3.0/settings.ini; GTK4/
                # libadwaita apps get dark from the settings portal
                # (color-scheme=prefer-dark via the locked dconf profile).
                _JAVA_AWT_WM_NONREPARENTING = "1";
              };
              systemPackages =
                with pkgs;
                [
                  # ── Compositor + panel ──
                  labwc
                  nanoLabwcTheme # Adwaita titlebar-button icons for labwc
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
                  image-roll
                  atril
                  
                  # ── Notifications ──
                  mako

                  # ── Screenshot / clipboard / lock ──
                  grim
                  slurp
                  wl-clipboard
                  # Clipboard history: GTK4/libadwaita overlay (Windows-11-style).
                  # The --daemon side runs as a user service; Super+V (labwc
                  # rc.xml) runs nano-clipboard, which shows the overlay and
                  # auto-pastes the picked entry into the focused window.
                  cursor-clip
                  nano-clipboard
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

                  # ── Theme / cursor / icons / MIME / XDG ──
                  # adw-gtk3 gives GTK3 apps the libadwaita look; GTK4/libadwaita
                  # apps follow the dark color-scheme directly. Papirus-Dark (in
                  # papirus-icon-theme) supplies the full-colour + symbolic named
                  # icons the labwc menu / Sfwbar panel reference; hicolor carries
                  # each app's own branded icon. adwaita-icon-theme is kept purely
                  # for the Adwaita cursor — Wayland has no server-side default
                  # cursor.
                  adw-gtk3
                  adwaita-icon-theme
                  papirus-icon-theme
                  hicolor-icon-theme
                  # NixOS snowflake (hicolor: nix-snowflake, nix-snowflake-white)
                  # — the Sfwbar Start-button icon. Papirus-Dark has no copy and
                  # inherits breeze-dark/hicolor, so hicolor is what resolves it.
                  nixos-icons
                  shared-mime-info
                  xdg-user-dirs
                  xdg-utils
                  # lxmenu-data ships the freedesktop application menu
                  # (lxde-applications.menu) plus its category .directory files.
                  # PCManFM/libfm's "Open With → Choose an application" dialog
                  # builds its installed-apps list from menu-cache, which reads
                  # this menu; without it the dialog lists nothing. Selected via
                  # XDG_MENU_PREFIX = "lxde-" (see sessionVariables).
                  lxmenu-data

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
                # Adwaita Sans (Inter-based) + Adwaita Mono (Iosevka-based) are the
                # modern GNOME UI/mono fonts and the global default here. DejaVu /
                # Liberation stay as metric-compatible fallbacks; Noto for emoji.
                adwaita-fonts
                dejavu_fonts
                liberation_ttf
                noto-fonts-color-emoji
              ];
              fontconfig = {
                enable = true;
                defaultFonts = {
                  sansSerif = [
                    "Adwaita Sans"
                    "DejaVu Sans"
                    "Liberation Sans"
                  ];
                  serif = [
                    "DejaVu Serif"
                    "Liberation Serif"
                  ];
                  monospace = [
                    "Adwaita Mono"
                    "DejaVu Sans Mono"
                    "Liberation Mono"
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
              # persist settings (bookmarks, prefs). It is also the authoritative
              # source of the modern-Adwaita-dark look for GNOME/libadwaita apps:
              # a locked system-wide profile pins the dark color-scheme, adw-gtk3
              # GTK3 theme, Papirus-Dark icons, Adwaita cursor and Adwaita Sans/Mono
              # fonts. lockAll enforces Nano's "global default, no user config"
              # model — users cannot override these keys.
              dconf = {
                enable = mkDefault true;
                profiles.user.databases = [
                  {
                    lockAll = true;
                    settings."org/gnome/desktop/interface" = {
                      color-scheme = "prefer-dark";
                      gtk-theme = "adw-gtk3-dark";
                      icon-theme = "Papirus-Dark";
                      cursor-theme = "Adwaita";
                      cursor-size = lib.gvariant.mkInt32 24;
                      font-name = "Adwaita Sans 11";
                      document-font-name = "Adwaita Sans 11";
                      monospace-font-name = "Adwaita Mono 11";
                    };
                    # Epiphany (GNOME Web) shows a "set as default browser"
                    # infobar on every launch while ask-for-default is true and
                    # it does not see itself as the default. Epiphany is already
                    # the http/https handler (xdg.mime.defaultApplications below),
                    # so silence the recurring prompt for good. Locked, matching
                    # Nano's global-default / no-user-config model.
                    settings."org/gnome/epiphany".ask-for-default = false;
                  }
                ];
              };
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
              # PAM service for the nano-desktop tty1 unit. systemd opens only the
              # account + session phases here (no auth prompt — the service already
              # runs as the user), and startSession registers a logind session via
              # pam_systemd, giving labwc its seat, VT and XDG_RUNTIME_DIR.
              pam.services.nano-desktop.startSession = true;
              polkit = {
                enable = mkDefault true;
                enablePkexecWrapper = mkDefault true;
              };
              rtkit.enable = mkDefault true;
              tpm2.enable = mkDefault false;
            };

            # ── Wayland session ─────────────────────────────────────────
            # No display-server / greeter: the nano-desktop system service (below)
            # owns tty1 and starts labwc as the user via a logind (pam_systemd)
            # session — the seat/DRM/XDG_RUNTIME_DIR setup a Wayland compositor
            # needs. labwc natively imports the runtime session env
            # (WAYLAND_DISPLAY, DISPLAY, XDG_CURRENT_DESKTOP, XDG_SESSION_TYPE,
            # XCURSOR_*) into D-Bus + the systemd user manager at startup, then
            # the launcher's `-s` flag starts nano-session.target, which BindsTo
            # graphical-session.target (the sway-session.target pattern): it
            # pulls in the helper user services below and tears them down
            # cleanly when labwc exits.
            systemd.user.targets.nano-session = {
              description = "Nano desktop session";
              documentation = [ "man:systemd.special(7)" ];
              bindsTo = [ "graphical-session.target" ];
              wants = [ "graphical-session-pre.target" ];
              after = [ "graphical-session-pre.target" ];
            };

            # Static session environment for ALL systemd user units, declared
            # once ([Manager] DefaultEnvironment in /etc/systemd/user.conf).
            # This is what the appmenu/`Open With` discovery needs
            # (XDG_DATA_DIRS/XDG_CONFIG_DIRS/XDG_MENU_PREFIX) plus theme vars.
            # %u/%h are systemd specifiers (user/home) — $VARS do NOT expand
            # here, and values must not contain spaces. PATH listed here covers
            # *packaged* units (portals, xdg-user-dirs, blueman's upstream
            # unit); NixOS-generated services get an injected Environment=PATH
            # that shadows it, which the session services' `path` option below
            # corrects. Runtime vars (WAYLAND_DISPLAY, DISPLAY) are pushed by
            # labwc itself and deliberately absent here.
            # No GTK_THEME here (breaks libadwaita dark — see sessionVariables);
            # GTK3 services read /etc/xdg/gtk-3.0/settings.ini via
            # XDG_CONFIG_DIRS instead. GIO_EXTRA_MODULES loads the dconf GIO
            # backend (so service-launched GSettings apps actually see the
            # locked dconf profile — color-scheme, fonts — rather than silently
            # falling back to a keyfile) and the gvfs module (trash/mtp/network
            # in pcmanfm).
            systemd.user.settings.Manager.DefaultEnvironment = toString [
              "XDG_CURRENT_DESKTOP=labwc"
              "XDG_DATA_DIRS=${gsettingsSchemaDir}:/run/current-system/sw/share:%h/.nix-profile/share:%h/.local/state/nix/profile/share:/etc/profiles/per-user/%u/share:/nix/var/nix/profiles/default/share"
              "XDG_CONFIG_DIRS=/etc/xdg:%h/.nix-profile/etc/xdg:%h/.local/state/nix/profile/etc/xdg:/etc/profiles/per-user/%u/etc/xdg:/nix/var/nix/profiles/default/etc/xdg:/run/current-system/sw/etc/xdg"
              "XDG_MENU_PREFIX=lxde-"
              "XDG_ICON_DIRS=/run/current-system/sw/share/icons"
              "GIO_EXTRA_MODULES=${pkgs.dconf.lib}/lib/gio/modules:${config.services.gvfs.package}/lib/gio/modules"
              "PATH=/run/wrappers/bin:/etc/profiles/per-user/%u/bin:/nix/var/nix/profiles/default/bin:/run/current-system/sw/bin"
            ];

            # xdg-user-dirs ships a packaged oneshot user unit
            # (Before=graphical-session-pre.target) that creates the standard
            # XDG user directories (~/Documents, ~/Downloads, ~/Pictures, …) and
            # ~/.config/user-dirs.dirs. systemd.packages links the unit; NixOS
            # does not process packaged [Install] sections, so the wants link is
            # added under systemd.user.services below. Ordering guarantees the
            # dirs exist before the panel/session helpers start.
            systemd.packages = [ pkgs.xdg-user-dirs ];

            # Panel / tray / notification / OSD helpers as systemd user services
            # bound to graphical-session.target: restart-on-crash, ordering and
            # clean teardown (vs the old `& … kill 0` juggling). nm-applet runs
            # with --indicator so it exposes a StatusNotifierItem for Sfwbar's SNI
            # tray (there is no XEmbed system tray under Wayland).
            systemd.user.services =
              let
                sessionDefaults = {
                  partOf = [ "graphical-session.target" ];
                  after = [ "graphical-session.target" ];
                  wantedBy = [ "graphical-session.target" ];
                  # NixOS injects a minimal Environment=PATH (coreutils & co.)
                  # into every generated service, shadowing both the user
                  # manager's PATH and DefaultEnvironment. That breaks more than
                  # launching: GLib's GDesktopAppInfo REJECTS any .desktop file
                  # whose Exec= binary is not findable in $PATH, so sfwbar's
                  # appmenu (and pcmanfm's "Open With" list in apps spawned from
                  # the bar) enumerate NOTHING under the stripped PATH. Putting
                  # the wrappers + system profile first fixes discovery and
                  # launching in one stroke ("path" strings render as <dir>/bin,
                  # prepended to the injected default).
                  path = [
                    "/run/wrappers"
                    "/run/current-system/sw"
                  ];
                  # Never bounce the visible session on nixos-rebuild switch
                  # (switch-to-configuration honors this for user units): the
                  # running session keeps its current binaries; new versions
                  # apply at the next session restart / reboot.
                  restartIfChanged = false;
                };
                sessionService =
                  description: exec:
                  sessionDefaults
                  // {
                    inherit description;
                    serviceConfig = {
                      ExecStart = exec;
                      Restart = "on-failure";
                      RestartSec = 1;
                    };
                  };
              in
              {
                sfwbar = sessionService "Sfwbar panel" "${pkgs.sfwbar}/bin/sfwbar -f /etc/xdg/sfwbar/sfwbar.config";
                mako = sessionService "Mako notification daemon" "${pkgs.mako}/bin/mako --config /etc/xdg/mako/config";
                swayosd = sessionService "SwayOSD server (volume/brightness OSD)" "${pkgs.swayosd}/bin/swayosd-server";
                nm-applet = sessionService "NetworkManager tray applet" "${pkgs.networkmanagerapplet}/bin/nm-applet --indicator";
                # Clipboard-history recorder. Takes ownership of new selections
                # (the default), so clipboard contents survive the source app
                # closing; the Super+V overlay (labwc rc.xml) is the frontend,
                # talking to this daemon over its socket.
                cursor-clip = sessionService "Cursor Clip clipboard daemon" "${pkgs.cursor-clip}/bin/cursor-clip --daemon";
                # blueman ships its own Type=dbus user unit (via services.blueman
                # → systemd.packages), so this definition becomes a drop-in over
                # it and MUST NOT set ExecStart — a second ExecStart on a
                # non-oneshot unit is a bad-setting that refuses to load (the
                # previous full definition left the applet permanently dead).
                blueman-applet = sessionDefaults // {
                  description = "Blueman tray applet";
                  serviceConfig = {
                    Restart = "on-failure";
                    RestartSec = 1;
                  };
                };
                # Wire the packaged xdg-user-dirs oneshot (see systemd.packages
                # above) into the session: NixOS ignores packaged [Install]
                # sections, so declare the wants link here. Runs Before=
                # graphical-session-pre.target, i.e. before the helpers above.
                xdg-user-dirs.wantedBy = [ "graphical-session-pre.target" ];
              };

            # ── Puppy-style desktop service: boot straight to labwc on tty1 ──
            # A dedicated systemd service (modelled on nixos-install-helper's
            # install service + NixOS's own services.cage) replaces getty +
            # login-shell autostart: findable (`systemctl status nano-desktop`),
            # journal-logged, with proper process/lifecycle management. It claims
            # tty1 by conflicting getty@tty1, runs labwc as the user through a
            # pam_systemd session (PAMName below → seat0, XDG_RUNTIME_DIR, DRM
            # master), and relaunches on exit (Restart=always) for the always-on
            # desktop. No getty autologin anywhere: tty2…6 keep normal logins.
            #
            # getty@tty1 is additionally MASKED (autovt@tty1 is its alias):
            # switch-to-configuration re-starts every active target on every
            # switch, and getty.target carries Wants=autovt@tty1.service when no
            # display manager is enabled — un-masked, each `nixos-rebuild switch`
            # would start getty@tty1, whose Conflicts= tears down the whole
            # running desktop session (~50 s outage + races that left helpers
            # dead). Wants= on a masked unit is a harmless no-op, and the
            # Conflicts= below stays as belt-and-braces for first boot.
            systemd.units."getty@tty1.service".enable = false;
            systemd.units."autovt@tty1.service".enable = false;
            systemd.services.nano-desktop = {
              description = "Nano Desktop (labwc Wayland session on tty1)";
              after = [
                "systemd-user-sessions.service"
                "plymouth-quit-wait.service"
                "getty@tty1.service"
              ];
              wants = [ "dbus.socket" ];
              wantedBy = [ "multi-user.target" ];
              conflicts = [ "getty@tty1.service" ];
              restartIfChanged = false;
              unitConfig.ConditionPathExists = "/dev/tty1";
              serviceConfig = {
                ExecStart = nanoDesktopLauncher;
                User = cfg.username;
                Restart = "always";
                RestartSec = 1;
                IgnoreSIGPIPE = "no";
                # Log the user with utmp (w/who), since we replace (a)getty.
                UtmpIdentifier = "%n";
                UtmpMode = "user";
                # Own the virtual terminal; fail if it can't be controlled.
                TTYPath = "/dev/tty1";
                TTYReset = "yes";
                TTYVHangup = "yes";
                TTYVTDisallocate = "yes";
                StandardInput = "tty-fail";
                StandardOutput = "journal";
                StandardError = "journal";
                # Full logind user session (seat/DRM/XDG_RUNTIME_DIR), required to
                # run a Wayland compositor from a system service.
                PAMName = "nano-desktop";
              };
            };

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
              mime = {
                enable = mkDefault true;
                defaultApplications = {
                  # Web → Epiphany
                  "text/html" = "org.gnome.Epiphany.desktop";
                  "application/xhtml+xml" = "org.gnome.Epiphany.desktop";
                  "x-scheme-handler/http" = "org.gnome.Epiphany.desktop";
                  "x-scheme-handler/https" = "org.gnome.Epiphany.desktop";
                  # Plain text / code → Geany
                  "text/plain" = "geany.desktop";
                  "text/x-chdr" = "geany.desktop";
                  "text/x-csrc" = "geany.desktop";
                  "text/x-c++hdr" = "geany.desktop";
                  "text/x-c++src" = "geany.desktop";
                  "text/x-java" = "geany.desktop";
                  "text/x-pascal" = "geany.desktop";
                  "text/x-perl" = "geany.desktop";
                  "text/x-python" = "geany.desktop";
                  "text/css" = "geany.desktop";
                  "text/x-diff" = "geany.desktop";
                  # Images → image-roll
                  "image/png" = "com.github.weclaw1.ImageRoll.desktop";
                  "image/x-png" = "com.github.weclaw1.ImageRoll.desktop";
                  "image/jpeg" = "com.github.weclaw1.ImageRoll.desktop";
                  "image/jpg" = "com.github.weclaw1.ImageRoll.desktop";
                  "image/gif" = "com.github.weclaw1.ImageRoll.desktop";
                  "image/bmp" = "com.github.weclaw1.ImageRoll.desktop";
                  "image/x-bmp" = "com.github.weclaw1.ImageRoll.desktop";
                  "image/svg+xml" = "com.github.weclaw1.ImageRoll.desktop";
                  "image/webp" = "com.github.weclaw1.ImageRoll.desktop";
                  "image/tiff" = "com.github.weclaw1.ImageRoll.desktop";
                  "image/avif" = "com.github.weclaw1.ImageRoll.desktop";
                  "image/heif" = "com.github.weclaw1.ImageRoll.desktop";
                  "image/jxl" = "com.github.weclaw1.ImageRoll.desktop";
                  # Audio → mpv
                  "audio/mpeg" = "mpv.desktop";
                  "audio/mp3" = "mpv.desktop";
                  "audio/ogg" = "mpv.desktop";
                  "audio/x-ogg" = "mpv.desktop";
                  "audio/vorbis" = "mpv.desktop";
                  "audio/flac" = "mpv.desktop";
                  "audio/x-flac" = "mpv.desktop";
                  "audio/wav" = "mpv.desktop";
                  "audio/x-wav" = "mpv.desktop";
                  "audio/aac" = "mpv.desktop";
                  "audio/mp4" = "mpv.desktop";
                  "audio/x-m4a" = "mpv.desktop";
                  "audio/opus" = "mpv.desktop";
                  # Video → mpv
                  "video/mp4" = "mpv.desktop";
                  "video/x-matroska" = "mpv.desktop";
                  "video/webm" = "mpv.desktop";
                  "video/ogg" = "mpv.desktop";
                  "video/mpeg" = "mpv.desktop";
                  "video/quicktime" = "mpv.desktop";
                  "video/x-msvideo" = "mpv.desktop";
                  "video/x-flv" = "mpv.desktop";
                  "video/x-ms-wmv" = "mpv.desktop";
                  "video/3gpp" = "mpv.desktop";
                  "video/3gpp2" = "mpv.desktop";
                  "video/x-ogm+ogg" = "mpv.desktop";
                  # Documents / comics → atril
                  "application/pdf" = "atril.desktop";
                  "application/epub+zip" = "atril.desktop";
                  "application/postscript" = "atril.desktop";
                  "image/vnd.djvu" = "atril.desktop";
                  "application/x-cbr" = "atril.desktop";
                  "application/x-cbz" = "atril.desktop";
                  "application/x-cb7" = "atril.desktop";
                  "application/x-cbt" = "atril.desktop";
                  # Archives → Xarchiver
                  "application/zip" = "xarchiver.desktop";
                  "application/x-tar" = "xarchiver.desktop";
                  "application/x-7z-compressed" = "xarchiver.desktop";
                  "application/vnd.rar" = "xarchiver.desktop";
                  "application/x-rar" = "xarchiver.desktop";
                  "application/gzip" = "xarchiver.desktop";
                  "application/x-bzip2" = "xarchiver.desktop";
                  "application/x-bzip-compressed-tar" = "xarchiver.desktop";
                  "application/x-compressed-tar" = "xarchiver.desktop";
                  "application/x-xz" = "xarchiver.desktop";
                  # Directories → PCManFM
                  "inode/directory" = "pcmanfm.desktop";
                };
              };
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
