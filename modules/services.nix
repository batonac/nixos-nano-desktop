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
  # ── Services ────────────────────────────────────────────────
  services = {
    # AccountsService has no consumer in this stack (no GDM / GNOME
    # Settings) — it only idled as a resident daemon. Off statically.
    accounts-daemon.enable = mkDefault false;
    # Per-application nice / ionice / cgroup / scheduling policy from
    # the CachyOS rule set, gated on features.processScheduling
    # (off by default — see the option).
    ananicy = {
      enable = mkDefault cfg.features.processScheduling;
      package = mkDefault pkgs.ananicy-cpp;
      rulesProvider = mkDefault pkgs.ananicy-rules-cachyos;
    };
    # Installs blueman-manager (app menu) + the blueman D-Bus
    # services. Nothing autostarts: the panel's bluez widget covers
    # status/pairing, and opening blueman-manager D-Bus-activates
    # what it needs on demand (org.blueman.Applet/.Manager both ship
    # activation files).
    blueman.enable = mkDefault cfg.features.bluetooth;
    bpftune.enable = mkDefault false;
    dbus = {
      implementation = mkDefault "broker";
      packages = with pkgs; [ ];
    };
    gvfs = {
      enable = mkDefault cfg.features.virtualFilesystems;
      package = mkDefault pkgs.gnome.gvfs;
    };
    # An hourly timer, on a machine engineered down to almost no
    # periodic wakeups, rotating two files it will never rotate.
    #
    # NixOS enables logrotate by default and ships it a generated
    # config, and on this system that config has exactly two stanzas in
    # it: /var/log/btmp and /var/log/wtmp, both "monthly", both
    # "minsize 1M". Nothing else here writes to /var/log at all —
    # journald keeps its own directory and does its own rotation
    # (SystemMaxUse below), there is no syslog, no web server, no
    # cron. So the timer fires every hour, forever, to stat two login
    # records that on a single-user laptop take years to reach a
    # megabyte, and then does nothing.
    #
    # The same unit also costs a checkconf at every boot and at every
    # nixos-rebuild switch. Off is the honest setting; a host that adds
    # something which genuinely writes to /var/log should set
    # services.logrotate.enable = true and get the timer back with it.
    logrotate.enable = mkDefault false;
    # Bound the journal. journald's default SystemMaxUse is 10% of the
    # filesystem (up to 4 GB), which is the single largest resource
    # this desktop consumes on a small disk — measured at 256 MB of
    # mostly-stale archived boots on a laptop that had been up for
    # days. Storage stays persistent (crash forensics across a reboot
    # is worth more than the space, and volatile journals also fill
    # tmpfs, i.e. RAM); the caps just stop it drifting. 16 MB files
    # keep rotation granular enough that the cap evicts in useful
    # increments instead of dropping one huge file at a time.
    #
    # mkDefault on a lines-typed option is wholesale, not per-line: a
    # host that sets services.journald.extraConfig at normal priority
    # replaces this block entirely rather than appending to it, so
    # such a host has to restate any cap it still wants.
    #
    # nanoDesktop.disableLogging picks the other branch instead of
    # adding a second definition, and that is deliberate for the same
    # reason: types.lines CONCATENATES definitions rather than letting
    # one win, so a second block would leave both sets of keys in the
    # file and make the result depend on which one systemd read last.
    # One option, one definition, two possible values.
    journald.extraConfig = mkDefault (
      if cfg.disableLogging then
        ''
          ReadKMsg=no
          ForwardToKMsg=no
          ForwardToConsole=no
          ForwardToWall=no
          MaxLevelStore=emerg
          MaxLevelSyslog=emerg
          MaxLevelKMsg=emerg
          MaxLevelConsole=emerg
          MaxLevelWall=emerg
        ''
      else
        ''
          SystemMaxUse=64M
          SystemMaxFileSize=16M
        ''
    );
    # Storage and the rate limit go through their own options rather
    # than the extraConfig above, because NixOS writes Storage=,
    # RateLimitInterval= and RateLimitBurst= into journald.conf from
    # them BEFORE appending extraConfig. Setting them in the block
    # would leave the file carrying each key twice and rely on systemd
    # taking the last one — true, but not a thing to build on when the
    # option that avoids it already exists.
    #
    # Rate limiting is tightened here, not switched off. Turning it off
    # is the intuitive move for "stop logging" and it is backwards:
    # RateLimitBurst=0 means unlimited, so a service in a crash loop
    # gets to hand journald every message it generates. The limit is
    # what stops the work happening at all, and with Storage=none there
    # is no disk-space multiplier inflating it either.
    journald.storage = mkDefault (if cfg.disableLogging then "none" else "persistent");
    journald.rateLimitBurst = mkDefault (if cfg.disableLogging then 100 else 10000);
    #
    # ReadKMsg=no above is the other half of not doing the work rather
    # than doing it and discarding: journald imports every kernel
    # message off /dev/kmsg by default, parses it, and under
    # Storage=none throws it away. This stops it at the read.
    #
    # Audit is deliberately left at NixOS's "keep". Turning it off
    # looks like it belongs in this list and buys nothing — "keep"
    # already means journald does not switch kernel auditing ON, so
    # with no auditd on this system there are no audit messages
    # arriving to suppress. Setting it false would reach out and
    # disable kernel auditing for everyone else, which NixOS's own
    # option documentation calls definitely the wrong thing to do.
    printing = {
      enable = mkDefault cfg.features.printing;
      # cups-browsed idled ~17 MB resident and its event
      # subscriptions kept cupsd itself permanently awake (~18 MB
      # more). Without it cupsd stays socket-activated (below) and
      # printers are added once via system-config-printer, which
      # still discovers network printers at add time. Turn browsed
      # back on only if you want remote queues to appear in print
      # dialogs automatically.
      browsed.enable = mkDefault false;
      # Only start cupsd when something actually talks to it.
      startWhenNeeded = mkDefault true;
      webInterface = mkDefault false;
    };
    tumbler.enable = mkDefault cfg.features.thumbnails;
  };

  # GVFS starts a volume monitor per device class, and one of them
  # monitors something this desktop cannot have. GNOME Online Accounts
  # is not installed here and there is nothing that could install it —
  # no gnome-control-center, no GNOME session, no way to add an
  # account — so gvfs-goa-volume-monitor comes up at login to watch a
  # list whose length is permanently zero.
  #
  # Same reasoning as accounts-daemon above, and the same size of win:
  # measured at 89 kB PSS, which is small enough that the point is the
  # process rather than the memory. The others stay, because each of
  # them is a device class features.virtualFilesystems actually
  # advertises — udisks2 for removable disks, mtp and gphoto2 for
  # phones and cameras, afc for Apple devices.
  #
  # Masking the systemd unit is enough despite these being D-Bus
  # activated: every monitor's .service file names a SystemdService=,
  # so the broker hands activation to systemd, and systemd refuses. The
  # client treats a monitor that will not start the same way it treats
  # one that is not installed.
  systemd.user.units."gvfs-goa-volume-monitor.service".enable =
    mkIf config.services.gvfs.enable false;

  # ── Don't hand journald the data at all ─────────────────────
  # Storage=none makes journald throw everything away; this stops most
  # of it arriving. Service stdout and stderr go to /dev/null in the
  # child before exec, so there is no stream socket, no parse, no rate
  # limit check and no discard — the daemon simply never hears about
  # it.
  #
  # This is also the honest answer to "why not just mask journald".
  # systemd's own behaviour when it cannot reach the journal is, quite
  # literally, this: connect_logger_as() fails, it logs "Failed to
  # connect stdout to the journal socket, ignoring" and calls
  # open_null_as() (src/core/exec-invoke.c). Setting it as policy gets
  # the same end state without a masked service under an active
  # socket, without the trigger-limit failure that produces, and
  # without a warning on every service start.
  #
  # journald itself stays, and there is no version of this where it
  # does not. NixOS exposes no enable option for it, and upstream
  # builds it to survive: DefaultDependencies=no, Before=sysinit.
  # target, Restart=always with RestartSec=0, OOMScoreAdjust=-250,
  # IgnoreOnIsolate=yes on both the service and its socket — whose
  # unit file carries the comment "Mount and swap units need this."
  # It is part of the boot's structure, not a logging feature that can
  # be removed. What it costs when idle and fed nothing is its ~9 MB.
  #
  # The coupling to watch: this is keyed on disableLogging, not on
  # journald.storage. Someone who flips storage back to "volatile" to
  # debug a problem, while leaving disableLogging on, gets a working
  # journal with nothing in it. Turn the option off instead.
  systemd.settings.Manager.DefaultStandardOutput = mkIf cfg.disableLogging "null";

  # ── Empty the ring buffer once the desktop is up ────────────
  # The second half of nanoDesktop.disableLogging, and the half that is
  # about disclosure rather than churn — worth saying plainly, because
  # it is easy to file this under "less writing" and it is not.
  # dmesg --clear empties the buffer's CONTENTS; the 256 KB itself is
  # allocated at boot from CONFIG_LOG_BUF_SHIFT and stays allocated.
  # Nothing is written less often because of this unit. What changes is
  # that everything the kernel said on the way up stops being readable
  # afterwards.
  #
  # Which is the point on a machine that has also just been told to
  # keep no journal: with both halves on, a box that has been up for a
  # week has no account of its own boot in either place.
  #
  # Ordered after nano-desktop.service rather than after the
  # multi-user target the obvious way would use. WantedBy= a target
  # you are also After= is the classic way to end up arguing with
  # systemd about when that target counts as reached; anchoring to the
  # last real unit in the boot chain says the same thing — the desktop
  # came up, so the boot worked — and leaves the ordering unambiguous.
  # It also means the buffer survives a boot that never got that far,
  # which is exactly when somebody will want to read it.
  systemd.services.clear-dmesg = mkIf cfg.disableLogging {
    description = "Empty the kernel ring buffer once the session is up";
    wantedBy = [ "multi-user.target" ];
    after = [ "nano-desktop.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      # dmesg --clear needs CAP_SYSLOG, which a root service already
      # has. util-linux is in the closure either way.
      ExecStart = "${pkgs.util-linux}/bin/dmesg --clear";
    };
  };
}
