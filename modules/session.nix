{
  config,
  lib,
  pkgs,
  ...
}:
with lib;
let
  cfg = config.nanoDesktop;

  # tty1 desktop launcher (run by the nano-desktop systemd service). Pulls
  # in the NixOS session environment (environment.variables +
  # sessionVariables — GDK_BACKEND, cursor/theme vars, …) via
  # /etc/set-environment, then starts labwc. No autostart script: labwc
  # natively pushes the runtime session vars (WAYLAND_DISPLAY, DISPLAY,
  # XDG_CURRENT_DESKTOP, XDG_SESSION_TYPE, XCURSOR_*) into the D-Bus
  # activation environment and the systemd user manager at startup, and
  # the static remainder is declared once in
  # systemd.user.settings.Manager.DefaultEnvironment (see desktop.nix).
  # `-s` runs after the compositor (and that env push) is up: it starts
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
in
{
  # ── Screen lock / login gate ────────────────────────────────
  # gtklock, a GTK lock screen for Wayland. It is both halves of the
  # security story on this box: the Super+L / menu lock, and — because
  # the gtklock user service starts with the session (below) — the
  # password prompt standing between a cold boot and the desktop.
  #
  # That gate is what makes booting straight to a session on tty1
  # acceptable. There is no display manager here and no greeter; the
  # desktop starts as the user, and until this the machine handed
  # anyone who opened the lid a logged-in desktop. Now labwc comes up,
  # gtklock takes the screen, and nothing is reachable until the user's
  # own password goes in — the thing a login screen actually does,
  # without the ~50 MB and the second session stack of one.
  #
  # It is a real lock, not a window that covers the screen: gtklock
  # holds the session through ext-session-lock-v1 (via gtk-session-lock,
  # labwc's side is wlr_session_lock_v1). The compositor, not the
  # client, owns the locked state, so a gtklock that crashes leaves the
  # session locked rather than open — the failure mode a layer-shell
  # overlay gets backwards.
  #
  # programs.gtklock installs the package, writes
  # /etc/xdg/gtklock/config.ini from `config` below, and declares
  # security.pam.services.gtklock, which is what authenticates the
  # unlock.
  programs.gtklock = {
    enable = mkDefault true;
    config.main = {
      # gtklock is GTK3, so it takes the same theme as the rest of the
      # GTK3 apps here. Named explicitly rather than left to
      # /etc/xdg/gtk-3.0/settings.ini: this window is the first thing
      # on screen at boot, and a light lock screen in front of a dark
      # desktop is exactly the flash we do not want if XDG_CONFIG_DIRS
      # is ever not what we expect.
      gtk-theme = "adw-gtk3-dark";
      time-format = "%-I:%M %p";
      # Fade the password form out after a minute of no input, leaving
      # the clock — the lock screen a laptop sits at all afternoon
      # should not be a text box with a caret in it. Any key or pointer
      # movement brings it back.
      idle-hide = true;
      idle-timeout = 60;
    };
    # Adwaita dark, matching fuzzel's window (see config/fuzzel).
    style = ''
      window {
        background-color: #1c1c1f;
      }
      #window-box {
        background-color: #242226;
        border: 1px solid #1c1c1f;
        border-radius: 12px;
        padding: 24px;
      }
      #clock-label {
        font-size: 48px;
        font-weight: bold;
      }
    '';
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

  # xdg-user-dirs ships a packaged oneshot user unit
  # (Before=graphical-session-pre.target) that creates the standard
  # XDG user directories (~/Documents, ~/Downloads, ~/Pictures, …) and
  # ~/.config/user-dirs.dirs. systemd.packages links the unit; NixOS
  # does not process packaged [Install] sections, so the wants link is
  # added under systemd.user.services below. Ordering guarantees the
  # dirs exist before the panel/session helpers start.
  systemd.packages = [ pkgs.xdg-user-dirs ];

  # Panel / notification / lock helpers as systemd user services bound
  # to graphical-session.target: restart-on-crash, ordering and clean
  # teardown. Network, bluetooth and volume status live inside sfwbar's
  # own modules (wifi-iwd / bluez / volume — pulse or amixer per
  # features.audioServer, see sfwbar/sfwbar.config), so no tray applets
  # autostart; that trio of applets cost ~150 MB of resident memory for
  # what the already-running panel now does itself. The SNI tray stays
  # for user-launched apps that ship status icons.
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
      # The login gate. Starting with the session is what turns a lock
      # screen into one: the desktop is behind a password from the
      # moment labwc is up, and the rest of the session loads behind it
      # while the user types, so unlocking is instant rather than the
      # start of a boot.
      #
      # Before= the other session services so the lock is requested
      # first. It is a request either way — the compositor grants the
      # lock when it processes it — but ordering keeps the unlocked
      # window at startup as small as systemd can make it.
      #
      # Restart differs from sessionDefaults in both directions.
      # Exiting 0 is a successful unlock, so on-failure (not always,
      # which would re-lock the screen the instant the user got in).
      # But a gtklock that fails to start leaves the desktop open, so
      # failure does retry — bounded by systemd's default start limit,
      # because a lock screen that cannot start is better than a boot
      # loop nobody can log in to fix.
      gtklock = sessionDefaults // {
        description = "Screen lock (session login gate)";
        before = [
          "sfwbar.service"
          "mako.service"
        ];
        serviceConfig = {
          ExecStart = "${config.programs.gtklock.package}/bin/gtklock";
          Restart = "on-failure";
          RestartSec = 1;
        };
      };
      # The only resident half of the clipboard feature: wl-paste
      # watches the selection through ext-/wlr-data-control and hands
      # each new entry to cliphist, which appends it to a small
      # on-disk store under $XDG_CACHE_HOME. The pickers (Super+V,
      # Super+.) are keybind-invoked scripts, so between keypresses
      # this watcher is all that is running — around 1-2 MB.
      #
      # --type text on purpose: without the filter every screenshot
      # copied to the clipboard would be written into the history
      # store at full size.
      #
      # wl-paste exits when the compositor goes away, and Restart plus
      # partOf=graphical-session.target (sessionDefaults) bring it back
      # with the next session rather than leaving a dead watcher.
      cliphist-store = mkIf cfg.features.clipboardHistory (
        sessionService "Clipboard history watcher (cliphist)" "${pkgs.wl-clipboard}/bin/wl-paste --type text --watch ${pkgs.cliphist}/bin/cliphist store"
      );
      # Wire the packaged xdg-user-dirs oneshot (see systemd.packages
      # above) into the session: NixOS ignores packaged [Install]
      # sections, so declare the wants link here. Runs Before=
      # graphical-session-pre.target, i.e. before the helpers above.
      xdg-user-dirs.wantedBy = [ "graphical-session-pre.target" ];
    };

  # ── Boot straight to labwc on tty1 ──────────────────────────
  # A dedicated systemd service (modelled on nixos-install-helper's
  # install service + NixOS's own services.cage) in place of getty +
  # login-shell autostart: findable (`systemctl status nano-desktop`),
  # journal-logged, with proper process/lifecycle management. It claims
  # tty1 by conflicting getty@tty1, runs labwc as the user through a
  # pam_systemd session (PAMName below → seat0, XDG_RUNTIME_DIR, DRM
  # master), and relaunches on exit (Restart=always) for the always-on
  # desktop. No getty autologin anywhere: tty2…6 keep normal logins.
  #
  # Booting to a session with no password is not what this does — the
  # gtklock gate at the top of this file is in front of it, and
  # Restart=always means quitting the session lands back at that
  # prompt rather than at a shell.
  #
  # getty@tty1 is additionally MASKED (autovt@tty1 is its alias):
  # switch-to-configuration re-starts every active target on every
  # switch, and getty.target carries Wants=autovt@tty1.service when no
  # display manager is enabled — un-masked, each `nixos-rebuild switch`
  # would start getty@tty1, whose Conflicts= tears down the whole
  # running desktop session (~50 s outage + races that left helpers
  # dead). Wants= on a masked unit is a harmless no-op, and the
  # Conflicts= below stays as belt-and-braces for first boot.
  #
  # tty2…tty6 join it when nanoDesktop.virtualTerminals is off. One
  # assignment covers both, because `systemd.units."x".enable` and
  # `systemd.units = …` in the same attrset is a duplicate-attribute
  # error in the language, not a merge the module system gets to do.
  #
  # Read that option before turning it off: it is a security change
  # with a real cost to recovery, and it frees no memory, because
  # logind never started a getty on any of those five to begin with.
  #
  # Masking them is the belt; services.logind below is the braces, and
  # it is the half that matters. Nothing is subscribed to these units
  # at boot — logind activates autovt@ttyN at the moment someone
  # switches to VT N, which is exactly why they cost nothing until then
  # and equally why masking alone would leave logind reaching for a
  # masked unit on every VT switch.
  systemd.units = {
    "getty@tty1.service".enable = false;
    "autovt@tty1.service".enable = false;
  }
  // optionalAttrs (!cfg.virtualTerminals) (
    listToAttrs (
      concatMap
        (n: [
          (nameValuePair "getty@tty${toString n}.service" { enable = false; })
          (nameValuePair "autovt@tty${toString n}.service" { enable = false; })
        ])
        [
          2
          3
          4
          5
          6
        ]
    )
  );

  # NAutoVTs = 0 stops logind reaching for those units at all;
  # ReserveVT = 0 gives up the VT it otherwise holds back for a getty
  # (6 by default), which would stay allocated for one that can no
  # longer start on it.
  services.logind.settings.Login = mkIf (!cfg.virtualTerminals) {
    NAutoVTs = 0;
    ReserveVT = 0;
  };

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

      # The other half of the guards in modules/nix.nix, and the half
      # that was missing. Those aim at the offender: nix-daemon gets a
      # MemoryHigh ceiling so it stops taking. This aims at the victim.
      #
      # Read the measurement written up under "Resource guards" there
      # and the shape of the failure is specific. Swap stayed 98% free;
      # nothing was ever OOM-killed; what actually happened was the
      # kernel evicting FILE-BACKED pages to make room, which on this
      # machine means the executables and libraries the session is
      # running out of, and then faulting them straight back in. The
      # pointer stopped moving because labwc's own text pages had been
      # reclaimed out from under it.
      #
      # MemoryLow is the exact counter to that. It marks this cgroup's
      # memory — page cache included, which is the point — as
      # protected, so reclaim walks past it and takes from somewhere
      # with less claim on staying resident. Under pressure the kernel
      # will still dip into a MemoryLow cgroup rather than OOM, which is
      # why it is the right knob and MemoryMin, a hard floor that
      # reclaim may not cross at all, is not: a floor here would turn a
      # memory squeeze into a kill somewhere else on a 4 GB machine.
      #
      # 200M covers labwc and the compositor's own mappings with room
      # to spare (labwc idles around 25 MB RSS, most of it shared), and
      # deliberately does not try to cover the applications — those
      # live in the user slice, and protecting everything protects
      # nothing.
      MemoryLow = mkDefault "200M";
      # The session outranks anything competing with it, which is the
      # same statement CPUWeight = 50 on nix-daemon makes from the
      # other side. Stated here too so it holds against whatever else
      # a host adds later, rather than only against nix.
      CPUWeight = mkDefault 200;
      IOWeight = mkDefault 200;
    };
  };

  # PAM service for the nano-desktop tty1 unit. systemd opens only the
  # account + session phases here (no auth prompt — the service already
  # runs as the user), and startSession registers a logind session via
  # pam_systemd, giving labwc its seat, VT and XDG_RUNTIME_DIR.
  security.pam.services.nano-desktop.startSession = true;
}
