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
    journald.extraConfig = mkDefault ''
      SystemMaxUse=64M
      SystemMaxFileSize=16M
    '';
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
}
