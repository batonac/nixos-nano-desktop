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

  # ── The accent ──────────────────────────────────────────────
  # Five of the programs in this session draw their own chrome and take a
  # colour rather than a theme: labwc's menus and OSD, the panel, the
  # launcher, the notifications and the terminal's selection. Each of their
  # config files carries the accent as @ACCENT@ where the value goes, and
  # gets it substituted here — the same shape as the volume widget below,
  # for the same reason: one source of truth, spliced rather than restated.
  #
  # Bare six hex digits, no leading #, because the five files disagree about
  # the format (#rrggbb, rrggbb, rrggbbaa) and each writes its own prefix
  # around the marker.
  accents = import ../pkgs/accent.nix { inherit lib; };
  accent = removePrefix "#" accents.palette.${cfg.accentColor};
  withAccent = path: builtins.replaceStrings [ "@ACCENT@" ] [ accent ] (builtins.readFile path);

  # Backend for the server-free panel volume widget: one script holding
  # every amixer invocation the panel makes, so the flags stay in one
  # place and match nano-osd's media keys (applications.nix) exactly —
  # same -M mapped scale, same "unmute on volume up", same Master
  # control. Because both sides poke the same hardware control and the
  # widget refreshes off ALSA's own event stream (below), the panel
  # tracks the media keys with no wiring between them.
  #
  # `state` prints VOL=/MUTE= rather than letting sfwbar regex amixer's
  # own output: sfwbar scanner variables are numeric, so a RegEx that
  # captures "on"/"off" yields a value that compares equal to neither
  # (upstream's bundled alsa.widget has exactly this bug in its mute
  # test). Two integers sidestep the whole question.
  #
  # No reading (no card, amixer gone) prints nothing at all, leaving
  # both variables unset so Ident() is false and the widget can say
  # "unavailable" instead of inventing a level.
  nano-volume = pkgs.writeShellApplication {
    name = "nano-volume";
    runtimeInputs = with pkgs; [
      alsa-utils
      coreutils
      gnugrep
    ];
    text = ''
      case "''${1:-}" in
        events)
          # amixer sevents blocks and prints a line per mixer change.
          # Filtered to Master because amixer announces every control on
          # the card at startup (~50 lines here) and reports traffic on
          # unrelated ones after that, each of which would otherwise
          # re-run `state`. The startup burst still names Master, so the
          # widget populates immediately rather than waiting for the
          # first volume change.
          #
          # The retry loop is the point of this backend. amixer exits
          # when no card is there, and that is precisely what the sfwbar
          # alsactl module could not survive: it probes ALSA once, in
          # sfwbar_module_init, and if snd_card_next() comes back empty
          # it never registers Volume()/VolumeCtl() at all — so a panel
          # that lost the boot race showed a permanently muted icon and
          # a dead slider until sfwbar itself was restarted. Here a card
          # that appears late just means the next iteration connects,
          # and its add-event burst repopulates the widget.
          while :; do
            stdbuf -oL amixer sevents 2>/dev/null | grep --line-buffered "'Master'," || true
            sleep 2
          done
          ;;
        state)
          out=$(amixer -M sget Master 2>/dev/null) || exit 0
          vol=$(printf '%s\n' "$out" | grep -m1 -oE '[0-9]+%' | tr -d '%') || exit 0
          [ -n "$vol" ] || exit 0
          if printf '%s\n' "$out" | grep -q '\[off\]'; then mute=1; else mute=0; fi
          printf 'VOL=%s\nMUTE=%s\n' "$vol" "$mute"
          ;;
        up) amixer -M -q sset Master 5%+ unmute ;;
        down) amixer -M -q sset Master 5%- ;;
        mute-toggle) amixer -q sset Master toggle ;;
        set) amixer -M -q sset Master "''${2:-0}%" unmute ;;
        *)
          echo "usage: nano-volume events|state|up|down|mute-toggle|set <0-100>" >&2
          exit 1
          ;;
      esac
    '';
  };

  # sfwbar volume control, spliced into ../config/sfwbar/sfwbar.config at the
  # @VOLUME_DEFS@ (top-level) and @VOLUME_WIDGET@ (in the bar) markers.
  # Same look either way — icon + slider popup — but the backend is
  # keyed off features.audioServer:
  #  - server on  → the bundled volume.widget, which uses sfwbar's own
  #    volume interface; with PipeWire running it drives the pulse
  #    backend: per-sink, follows Bluetooth output, full multi-device
  #    popup.
  #  - server off → a scanner-driven button + popup over nano-volume
  #    above. apulse/pressureaudio has no server, and the bundled widget
  #    also loads pulsectl (which would bind to apulse's stub libpulse).
  #    sfwbar's own alsactl module is not used either, deliberately: it
  #    decides once at startup whether ALSA exists and has no path back
  #    if that probe loses to the sound card appearing (see the retry
  #    loop in nano-volume). A scanner re-reads on every event, so the
  #    widget converges on the truth no matter what order things start.
  #    Left-click opens the slider popup, scroll adjusts, right mutes.
  #    Popup look: the #nanovol_* rules in ../config/sfwbar/sfwbar.css.
  sfwbarVolumeDefs =
    if cfg.features.audioServer then
      ""
    else
      ''
        ExecClient("${getExe nano-volume} events", "nanovol") {}

        Exec("${getExe nano-volume} state") {
          NanoVolLevel = RegEx("VOL=([0-9]+)", First)
          NanoVolMute = RegEx("MUTE=([0-9]+)", First)
        }

        Var nanovol_thresholds = [67, 34, 0];
        Var nanovol_icons = ["audio-volume-high", "audio-volume-medium", "audio-volume-low"];

        PopUp "NanoVolumeWindow" {
          style = "nanovol_popup"
          image {
            value = If(NanoVolMute, "audio-volume-muted",
              ArrayLookup(NanoVolLevel, nanovol_thresholds, nanovol_icons, "audio-volume-muted"))
            style = "nanovol_mute"
            tooltip = "Toggle mute"
            action = Exec("${getExe nano-volume} mute-toggle")
            trigger = "nanovol"
            loc(1,1,1,1)
          }
          scale "nanovol_slider" {
            style = "nanovol_scale"
            value = NanoVolLevel / 100
            action[1] = Exec("${getExe nano-volume} set " + Str(GtkEvent("dir") * 100, 0))
            trigger = "nanovol"
            loc(2,1,1,1)
          }
          label {
            value = Str(NanoVolLevel, 0) + "%"
            style = "nanovol_pct"
            trigger = "nanovol"
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
      # `widget "name"`, which is sfwbar's file-include syntax. Reads the
      # scanner variables declared in @VOLUME_DEFS@; left-click opens the
      # NanoVolumeWindow slider popup defined there.
      #
      # The tooltip, not the icon, is what distinguishes "no reading" from
      # "muted": ArrayLookup's default fires when NanoVolLevel is unset,
      # and the honest icon for that state would be a sixth glyph nobody
      # would recognise. With the scanner re-reading on every ALSA event
      # the unset state is transient anyway — it is the tooltip that has
      # to be truthful if it ever does persist.
      ''
        button {
            style = "module"
            value = If(NanoVolMute, "audio-volume-muted",
              ArrayLookup(NanoVolLevel, nanovol_thresholds, nanovol_icons, "audio-volume-muted"))
            tooltip = If(Ident(NanoVolLevel),
              "Volume " + Str(NanoVolLevel, 0) + "%" + If(NanoVolMute, " (muted)", ""),
              "Volume unavailable")
            trigger = "nanovol"
            action[LeftClick] = PopUp("NanoVolumeWindow")
            action[RightClick] = Exec("${getExe nano-volume} mute-toggle")
            action[ScrollUp] = Exec("${getExe nano-volume} up")
            action[ScrollDown] = Exec("${getExe nano-volume} down")
          }'';
  sfwbarConfig =
    builtins.replaceStrings
      [ "@VOLUME_DEFS@" "@VOLUME_WIDGET@" ]
      [ sfwbarVolumeDefs sfwbarVolumeWidget ]
      (builtins.readFile ../config/sfwbar/sfwbar.config);

  # Shim that puts a panel-launched program into its own transient
  # systemd scope, so it lands under app.slice instead of inheriting the
  # panel's cgroup. See the sfwbar overlay below for why.
  #
  # writeShellScript rather than writeShellApplication on purpose: the
  # latter prepends its runtimeInputs to PATH, and since this exec's into
  # the application, that PATH would follow every program started from
  # the panel. This has to be transparent — the app must see exactly the
  # environment sfwbar would have handed it.
  #
  # Both guards matter. Without a user manager to ask (a panel run by
  # hand, a session outside systemd) there is no scope to create, and
  # systemd-run would simply fail and take the application down with it;
  # falling through to a plain exec keeps launching working everywhere
  # and costs only the cgroup separation where it was never available.
  nanoAppLaunch = pkgs.writeShellScript "nano-app-launch" ''
    if [ -n "''${XDG_RUNTIME_DIR:-}" ] && [ -S "$XDG_RUNTIME_DIR/systemd/private" ] &&
       command -v systemd-run >/dev/null 2>&1; then
      exec systemd-run --user --scope --collect --quiet -- "$@"
    fi
    exec "$@"
  '';

  # Wayland desktop config lives in static project files under ../config/labwc
  # and ../config/sfwbar, installed into /etc/xdg and loaded explicitly
  # (`labwc -C /etc/xdg/labwc`, `sfwbar -f /etc/xdg/sfwbar/sfwbar.config`).
  # They reference executables via /run/current-system/sw/bin/ rather
  # than /nix/store/ paths, so menu/panel entries keep resolving across
  # package updates / GC. Edit those files to change the desktop.
in
{
  # ── Panel-launched apps get their own cgroups ───────────────
  #
  # Everything sfwbar starts — the quick-launch buttons, every .desktop
  # entry in the application menu, the wifi and bluetooth helpers — ends
  # up in exec_cmd() in src/exec.c, which g_spawn_async()s the child
  # directly. A direct child inherits sfwbar.service's cgroup, and
  # systemd's default KillMode=control-group kills the whole cgroup on
  # stop: restarting the panel takes down every application launched
  # from it. That is a bad trade on its own, and a worse one because
  # restarting the panel is the standard fix when a panel module wedges
  # — the recovery step costs the user their session.
  #
  # sfwbar has no launch-prefix setting to do this from the config file
  # (exec_api_set() is C-only, and exists for the compositor IPC
  # backends), so this patches the single function all of those paths
  # reach. --replace-fail is the point of doing it this way: if upstream
  # restructures exec_cmd, the build fails loudly here instead of
  # silently going back to killing the desktop on restart.
  #
  # This does take sfwbar off the binary cache and build it locally, but
  # sfwbar is a small C project with a closure this system already has —
  # nothing else in nixpkgs depends on it, so the rebuild stops here.
  nixpkgs.overlays = [
    (final: prev: {
      sfwbar = prev.sfwbar.overrideAttrs (previous: {
        postPatch = (previous.postPatch or "") + ''
          substituteInPlace src/exec.c \
            --replace-fail \
              'void exec_cmd ( const gchar *cmd )' \
              'static gboolean exec_scope_parse ( const gchar *cmd, gint *argc,
                gchar ***argv )
          {
            gboolean result;
            gchar *scoped;

            scoped = g_strconcat("${nanoAppLaunch} ", cmd, NULL);
            result = g_shell_parse_argv(scoped, argc, argv, NULL);
            g_free(scoped);

            return result;
          }

          void exec_cmd ( const gchar *cmd )' \
            --replace-fail \
              'else if(g_shell_parse_argv(clean_cmd, &argc, &argv, NULL))' \
              'else if(exec_scope_parse(clean_cmd, &argc, &argv))'
        '';
      });
    })
  ];

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
      "xdg/labwc/themerc-override".text = withAccent ../config/labwc/themerc-override;
      # System-wide Sfwbar panel, loaded via `sfwbar -f`. The sibling
      # sfwbar.css is auto-loaded by Sfwbar from the same directory.
      # sfwbar.config is spliced (not copied) so the volume widget can
      # follow features.audioServer — see sfwbarConfig in the let block.
      "xdg/sfwbar/sfwbar.config".text = sfwbarConfig;
      "xdg/sfwbar/sfwbar.css".text = withAccent ../config/sfwbar/sfwbar.css;
      # foot terminal — Adwaita Mono + GNOME/Adwaita dark palette. foot
      # reads it from XDG_CONFIG_DIRS (/etc/xdg), like the gtk configs.
      "xdg/foot/foot.ini".text = withAccent ../config/foot/foot.ini;
      # fuzzel launcher (Super+Space + F12/Alt-F2), Adwaita-dark.
      "xdg/fuzzel/fuzzel.ini".text = withAccent ../config/fuzzel/fuzzel.ini;
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
      "xdg/mako/config".text = withAccent ../config/mako/config;
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
      # affect GTK3: libadwaita treats it as "the user picked a theme,
      # get out of the way" and stops applying its own
      # color-scheme-aware stylesheet, and since adw-gtk3 ships no
      # gtk-4.0 CSS, libadwaita apps then fall back to the default
      # *light* Adwaita. The three toolkits get dark by three different
      # routes instead, none of them this variable: GTK3 from
      # /etc/xdg/gtk-3.0/settings.ini, plain GTK4 from
      # gtk-application-prefer-dark-theme in the gtk-4.0 one, and
      # libadwaita from the dconf color-scheme — see ADW_DISABLE_PORTAL
      # below, which is what lets it read that at all.
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
    }
    # The one thing that makes libadwaita apps dark on a desktop with
    # no xdg-desktop-portal, and it is not optional — without it they
    # are light, on a system where every other toolkit is dark.
    #
    # libadwaita has three sources for the system colour scheme, tried
    # in order: the settings portal, GSettings, and legacy GtkSettings.
    # The GSettings one looks like the obvious fallback and is not:
    # adw-settings-impl-gsettings.c gates the color-scheme key behind
    # adw_get_disable_portal(), so unless this variable is set to 1,
    # libadwaita will only ever take the colour scheme from a portal.
    # With features.desktopPortal off there is no portal to answer, so
    # nothing sets it and ADW_COLOR_SCHEME_DEFAULT means light.
    #
    # The same function reads document-font-name and
    # monospace-font-name from GSettings with no such gate, which is
    # what makes this so confusing to look at: the app comes up with
    # the right fonts and the wrong colours, and looks like it is
    # ignoring one specific setting rather than missing a whole
    # mechanism.
    #
    # Skipped when the portal IS enabled — then the portal is the
    # better source (it is what the app would use on any other desktop,
    # and it signals changes at runtime).
    // optionalAttrs (!cfg.features.desktopPortal) {
      ADW_DISABLE_PORTAL = "1";
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
  systemd.user.settings.Manager.DefaultEnvironment = toString (
    [
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
    ]
    # Also here, not only in sessionVariables: an app started from a
    # user service inherits this and not /etc/set-environment, and a
    # colour scheme that depended on which of the two launched you
    # would be worse than one that was simply wrong. See the long note
    # in sessionVariables for what it does.
    ++ optional (!cfg.features.desktopPortal) "ADW_DISABLE_PORTAL=1"
  );

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
  # GTK3 theme, MoreWaita icons, Adwaita cursor and Adwaita Sans/Mono
  # fonts. lockAll enforces Nano's "global default, no user config"
  # model — users cannot override these keys.
  programs.dconf = {
    enable = mkDefault true;
    profiles.user.databases = [
      {
        lockAll = true;
        settings."org/gnome/desktop/interface" = {
          color-scheme = "prefer-dark";
          # Read by libadwaita 1.6+ through exactly the same gate as
          # color-scheme above — GSettings only when ADW_DISABLE_PORTAL=1,
          # which sessionVariables sets when no portal is running.
          # Verified rather than assumed: with this key set and that
          # variable, AdwStyleManager:accent-color follows it.
          #
          # GTK3 apps do not read it. They get the accent from the theme
          # instead, which modules/applications.nix rebuilds around the
          # same option.
          accent-color = cfg.accentColor;
          gtk-theme = "adw-gtk3-dark";
          icon-theme = "MoreWaita";
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
    # Off, and this is a correction rather than a tightening. Several
    # comments in this repo state that nothing autostarts — that the
    # blueman applet, the iwgtk indicator and the CUPS print applet are
    # installed but never started, because the panel does their jobs
    # itself and the trio cost ~150 MB resident between them. That was
    # true. It was not, however, true for the reason given.
    #
    # With this on, systemd-xdg-autostart-generator reads every
    # .desktop file in /etc/xdg/autostart and writes a user unit for
    # it. On this system it generates exactly the three above, wanted
    # by xdg-desktop-autostart.target — and the only thing keeping them
    # off the machine is that nothing ever starts that target, because
    # session.nix pulls in nano-session.target and never mentions it.
    # `systemctl --user is-active xdg-desktop-autostart.target` says
    # inactive, and the three units sit there generated and idle.
    #
    # Which is a trap rather than a design. Wiring that target into the
    # session is an ordinary thing to want — it is how autostart is
    # supposed to work, and a future change that adds it for one
    # application would silently switch on all three applets and undo a
    # deliberate 150 MB decision with no line of the diff mentioning
    # them. Turning the generator off states the intent where the
    # intent is, and costs nothing today: it masks the generator, so
    # the units stop being written at all.
    #
    # If something here ever does need to autostart, it belongs in
    # systemd.user.services next to sfwbar and mako (see session.nix),
    # where it is declared, ordered against graphical-session.target
    # and torn down with it — which is what every other resident piece
    # of this session already does.
    autostart.enable = mkDefault false;
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
