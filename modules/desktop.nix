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

  # sfwbar volume control, spliced into ../config/sfwbar/sfwbar.config at the
  # @VOLUME_DEFS@ (top-level) and @VOLUME_WIDGET@ (in the bar) markers.
  # Both backends use sfwbar's own volume interface — native, themed,
  # icon + slider popup — keyed off features.audioServer:
  #  - server on  → the bundled volume.widget (loads pulsectl+alsactl);
  #    with PipeWire running it drives the pulse backend: per-sink,
  #    follows Bluetooth output, full multi-device popup.
  #  - server off → a slim alsactl-only button + popup. apulse/
  #    pressureaudio has no server, and the bundled widget also loads
  #    pulsectl (which would bind to apulse's stub libpulse), so here we
  #    load ONLY module("alsactl") and vendor a single-sink mini-mixer.
  #    It drives the hardware Master over ALSA and shares the "volume"
  #    trigger, so it stays in sync with nano-osd's amixer media keys.
  #    Left-click opens the slider popup, scroll adjusts, right mutes.
  #    Popup look: the #nanovol_* rules in ../config/sfwbar/sfwbar.css.
  sfwbarVolumeDefs =
    if cfg.features.audioServer then
      ""
    else
      ''
        module("alsactl")

        Var nanovol_thresholds = [67, 34, 0];
        Var nanovol_icons = ["audio-volume-high", "audio-volume-medium", "audio-volume-low"];

        PopUp "NanoVolumeWindow" {
          style = "nanovol_popup"
          image {
            value = If(Volume("sink-mute"), "audio-volume-muted",
              ArrayLookup(Volume("sink-volume"), nanovol_thresholds, nanovol_icons, "audio-volume-muted"))
            style = "nanovol_mute"
            tooltip = "Toggle mute"
            action = VolumeCtl("sink-mute toggle")
            trigger = "volume"
            loc(1,1,1,1)
          }
          scale "nanovol_slider" {
            style = "nanovol_scale"
            value = Volume("sink-volume") / 100
            action[1] = VolumeCtl("sink-volume " + Str(GtkEvent("dir") * 100))
            trigger = "volume"
            loc(2,1,1,1)
          }
          label {
            value = Str(Volume("sink-volume"), 0) + "%"
            style = "nanovol_pct"
            trigger = "volume"
            loc(3,1,1,1)
          }
        }'';
  sfwbarVolumeWidget =
    if cfg.features.audioServer then
      ''
        widget "volume.widget" {
            simple_icon = False
            volume_thresholds = [80, 50, 0]
            volume_icons = ["audio-volume-high", "audio-volume-medium", "audio-volume-low"]
            volume_muted = "audio-volume-muted"
          }''
    else
      # Inline button (like the start/launcher buttons) — NOT
      # `widget "name"`, which is sfwbar's file-include syntax. Uses the
      # alsactl module loaded in @VOLUME_DEFS@; left-click opens the
      # NanoVolumeWindow slider popup defined there.
      ''
        button {
            style = "module"
            value = If(Volume("sink-mute"), "audio-volume-muted",
              ArrayLookup(Volume("sink-volume"), nanovol_thresholds, nanovol_icons, "audio-volume-muted"))
            tooltip = "Volume " + Str(Volume("sink-volume"), 0) + "%" + If(Volume("sink-mute"), " (muted)", "")
            trigger = "volume"
            action[LeftClick] = PopUp("NanoVolumeWindow")
            action[RightClick] = VolumeCtl("sink-mute toggle")
            action[ScrollUp] = VolumeCtl("sink-volume +5")
            action[ScrollDown] = VolumeCtl("sink-volume -5")
          }'';
  sfwbarConfig =
    builtins.replaceStrings
      [ "@VOLUME_DEFS@" "@VOLUME_WIDGET@" ]
      [ sfwbarVolumeDefs sfwbarVolumeWidget ]
      (builtins.readFile ../config/sfwbar/sfwbar.config);

  # Wayland desktop config lives in static project files under ../config/labwc
  # and ../config/sfwbar, installed into /etc/xdg and loaded explicitly
  # (`labwc -C /etc/xdg/labwc`, `sfwbar -f /etc/xdg/sfwbar/sfwbar.config`).
  # They reference executables via /run/current-system/sw/bin/ rather
  # than /nix/store/ paths, so menu/panel entries keep resolving across
  # package updates / GC. Edit those files to change the desktop.
in
{
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
      # No menu.xml: the desktop has no right-click root menu. rc.xml
      # unbinds all three of labwc's default Root presses, and the
      # applications, lock and power entries the menu used to duplicate
      # now live in the one launcher menu on the panel.
      "xdg/labwc/rc.xml".source = ../config/labwc/rc.xml;
      "xdg/labwc/themerc-override".source = ../config/labwc/themerc-override;
      # System-wide Sfwbar panel, loaded via `sfwbar -f`. The sibling
      # sfwbar.css is auto-loaded by Sfwbar from the same directory.
      # sfwbar.config is spliced (not copied) so the volume widget can
      # follow features.audioServer — see sfwbarConfig in the let block.
      "xdg/sfwbar/sfwbar.config".text = sfwbarConfig;
      "xdg/sfwbar/sfwbar.css".source = ../config/sfwbar/sfwbar.css;
      # foot terminal — Adwaita Mono + GNOME/Adwaita dark palette. foot
      # reads it from XDG_CONFIG_DIRS (/etc/xdg), like the gtk configs.
      "xdg/foot/foot.ini".source = ../config/foot/foot.ini;
      # fuzzel launcher (Super+Space + F12/Alt-F2), Adwaita-dark.
      "xdg/fuzzel/fuzzel.ini".source = ../config/fuzzel/fuzzel.ini;
      # PCManFM/libfm: point "Open Terminal" and open-in-terminal
      # actions at foot (libfm defaults to an unset terminal → the
      # "terminal emulator is not set" error). foot is not in libfm's
      # terminals.list, so libfm falls back to `foot -e <cmd>`; foot
      # accepts and ignores -e, so this works for both
      # bare "Open Terminal" and execute-in-terminal.
      "xdg/libfm/libfm.conf".text = ''
        [config]
        terminal=foot
      '';
      # mako notifications — Adwaita-dark, GNOME-style. mako only
      # auto-reads ~/.config/mako/config, so the service loads this
      # explicitly with `--config` (see systemd.user.services.mako).
      "xdg/mako/config".source = ../config/mako/config;
      # GTK3/GTK4 system-wide settings. /etc/xdg is on XDG_CONFIG_DIRS,
      # so GTK apps pick up the theme/icon/cursor/font from here. The
      # modern-Adwaita-dark default: GTK3 → adw-gtk3-dark, GTK4 → the
      # built-in Adwaita forced dark via prefer-dark. The locked dconf
      # profile (programs.dconf below) is the authoritative source for
      # GNOME/libadwaita apps; these files cover non-dconf GTK apps.
      "xdg/gtk-3.0/settings.ini".source = ../config/gtk-3.0/settings.ini;
      "xdg/gtk-4.0/settings.ini".source = ../config/gtk-4.0/settings.ini;
      # gtklock's own config.ini is NOT here — programs.gtklock
      # (session.nix) generates /etc/xdg/gtklock/config.ini from its
      # `config` option, and a second entry for the same path would
      # collide.
    };
    # Desktop launch is no longer wired through the login shell — a
    # dedicated systemd service (systemd.services.nano-desktop) owns tty1
    # and starts the session. See session.nix.
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
    variables = {
      EDITOR = "/run/current-system/sw/bin/gnome-text-editor";
      BROWSER = "/run/current-system/sw/bin/firefox";
      TERMINAL = "/run/current-system/sw/bin/foot";
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
    }
    # Pin the VA-API driver when the machine's generation is known.
    # Left unset under "auto" on purpose: libva's own probe tries the
    # candidates in order, and naming one here would defeat that.
    // optionalAttrs (cfg.hardwareVideo == "intel-modern") {
      LIBVA_DRIVER_NAME = "iHD";
    }
    // optionalAttrs (cfg.hardwareVideo == "intel-legacy") {
      LIBVA_DRIVER_NAME = "i965";
    };
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
    # Conditional on gvfs actually being enabled. Naming the package
    # unconditionally put it — and Samba behind it — in the closure of
    # every machine, 123 MB, including the ones that had switched
    # features.virtualFilesystems off precisely to avoid it. A feature
    # flag that leaves its subject in the store is not off, it is only
    # not running.
    "GIO_EXTRA_MODULES=${
      concatStringsSep ":" (
        [ "${pkgs.dconf.lib}/lib/gio/modules" ]
        ++ optional config.services.gvfs.enable "${config.services.gvfs.package}/lib/gio/modules"
      )
    }"
    "PATH=/run/wrappers/bin:/etc/profiles/per-user/%u/bin:/nix/var/nix/profiles/default/bin:/run/current-system/sw/bin"
  ];

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

  # dconf/GSettings backend — GNOME apps need it to
  # persist settings. It is also the authoritative
  # source of the modern-Adwaita-dark look for GNOME/libadwaita apps:
  # a locked system-wide profile pins the dark color-scheme, adw-gtk3
  # GTK3 theme, Colloid-Dark icons, Adwaita cursor and Adwaita Sans/Mono
  # fonts. lockAll enforces Nano's "global default, no user config"
  # model — users cannot override these keys.
  programs.dconf = {
    enable = mkDefault true;
    profiles.user.databases = [
      {
        lockAll = true;
        settings."org/gnome/desktop/interface" = {
          color-scheme = "prefer-dark";
          gtk-theme = "adw-gtk3-dark";
          icon-theme = "Colloid-Dark";
          cursor-theme = "Adwaita";
          cursor-size = lib.gvariant.mkInt32 24;
          font-name = "Adwaita Sans 11";
          document-font-name = "Adwaita Sans 11";
          monospace-font-name = "Adwaita Mono 11";
        };
      }
    ];
  };

  # ── XDG ─────────────────────────────────────────────────────
  xdg = {
    autostart.enable = mkDefault true;
    icons.enable = mkDefault true;
    menus.enable = mkDefault true;
    # Off by default on this lite target (features.desktopPortal) —
    # the native paths cover file dialogs / notifications / OpenURI /
    # dark mode without it. The GTK-portal wiring below applies only
    # when it is turned back on.
    portal = {
      enable = mkDefault cfg.features.desktopPortal;
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
}
