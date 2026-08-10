{
  config,
  lib,
  pkgs,
  ...
}:
with lib;
let
  cfg = config.nanoDesktop;

  # The `system-upgrade` command the timer below runs. It is also on PATH for
  # manual runs — modules/applications.nix puts it in systemPackages.
  systemUpgradeScript = import ../pkgs/system-upgrade.nix { inherit lib pkgs; };
in
{
  # ── The nixpkgs source is not worth 201 MB here ─────────────
  # Building a system from a flake makes NixOS pin that flake's nixpkgs
  # into the machine, both in /etc/nix/registry.json (so `nixpkgs#foo`
  # resolves) and on NIX_PATH (so `<nixpkgs>` does). The pin is a store
  # path, so the whole nixpkgs *source tree* lands in the system
  # closure: 201 MB, the fourth largest thing on the machine, and
  # measurably larger than Firefox's own binaries.
  #
  # What it buys is offline *evaluation* of an ad-hoc `nix run
  # nixpkgs#gimp` or `nix-shell -p`. Which is the wrong half of the
  # problem: evaluating gimp offline does not build it, and the
  # download that follows needs the network the pin was meant to make
  # unnecessary. So the pin is only useful on a machine that already
  # has what it needs — where it is not needed.
  #
  # Both still work with this off; they resolve `nixpkgs` through the
  # global registry over the network instead, which is the same network
  # the packages come from. Nothing this desktop does for itself uses
  # either path: the upgrade script and the first-boot reconcile both
  # go through /etc/nixos/flake.nix, which names its own nixpkgs.
  #
  # Costs nothing to change — no package moves, only two strings in
  # /etc — which is exactly why it is worth doing.
  nixpkgs.flake = {
    setNixPath = mkDefault false;
    setFlakeRegistry = mkDefault false;
  };

  # ── Nix Configuration ───────────────────────────────────────
  nix = {
    gc = {
      automatic = mkDefault true;
      dates = mkDefault "weekly";
      options = mkDefault "--delete-older-than 7d";
    };
    # Store deduplication, moved off the interactive path. What it
    # saves is not in question — a Nix store carries a great many
    # byte-identical files across generations and packages, and no
    # compression ratio touches a duplicate, so this and the btrfs
    # zstd in storage.nix save different things and neither
    # substitutes for the other. The question is only when it runs.
    #
    # auto-optimise-store (set here until now) ran it inline: every
    # substituted path hashed and linked before nix would call the
    # build done, while someone was waiting. On a machine whose whole
    # design premise is that the pointer keeps moving, that is the one
    # place it should not be. The timer does the same work under the
    # same guards as everything else heavy here (see the service
    # below), and gc.dates already established weekly as the cadence
    # for store maintenance.
    #
    # The honest counter-argument, since it is a real one: inline
    # optimisation hashes files it has just written, so they are still
    # in page cache, whereas nix-store --optimise walks the whole store
    # cold. This trades more total I/O for I/O that happens when nobody
    # is typing. It also means the store runs un-deduplicated between
    # passes, which on a 16 GB disk is worth watching — that is what
    # the weekly cadence, rather than monthly, is for.
    #
    # NixOS's own unit is already scheduled the way this module would
    # have scheduled it — Nice = 19, CPUSchedulingPolicy = idle,
    # IOSchedulingClass = idle — and that last one is another thing the
    # BFQ rule in storage.nix quietly switched on: the idle I/O class
    # is honoured by BFQ and ignored by mq-deadline, so before that
    # rule this timer's politest setting was decorative on every SSD
    # machine. See services.nix-optimise below for the one piece of it
    # that does have to change.
    optimise = {
      automatic = mkDefault true;
      dates = mkDefault [ "weekly" ];
    };
    settings = {
      auto-optimise-store = mkDefault false;
      # Bound the local build fan-out. Both of these default to
      # "however many cores there are", which on the 2-core-plus-HT
      # parts this targets means nix may run 4 derivations at once,
      # each told it may use 4 cores. That is 4 concurrent compilers on
      # a machine with 4 GB, and the MemoryHigh ceiling below does not
      # prevent it — it throttles the cgroup once the damage is done,
      # which turns the fan-out into swap rather than into failure.
      #
      # Not hypothetical on this system in particular: it forces a
      # handful of local builds by construction (the trimmed
      # linux-firmware copy in hardware.nix, yt-dlp and the two Firefox
      # wrapper rebuilds), and any cache miss on a nixpkgs bump adds
      # more. One derivation at a time, using every core, finishes a
      # queue of small builds at about the same wall clock and never
      # has four peak memory footprints resident at once.
      max-jobs = mkDefault 1;
      # cores stays at 0 ("use every core"), which is already nix's own
      # default and is stated because it is what makes max-jobs = 1 a
      # reordering rather than a throttle: the parallelism moves inside
      # one derivation instead of across four.
      cores = mkDefault 0;
      experimental-features = [
        "nix-command"
        "flakes"
        "cgroups"
      ];
      # Nix substitutes up to 16 paths at once by default: sixteen
      # concurrent downloads, each feeding a zstd decompression and a
      # write into the store. On four cores and 4 GB that is not
      # throughput, it is a stampede — it is what pinned this laptop
      # for forty minutes fetching one large package (see "Resource
      # guards"). Four keeps a home link saturated without it.
      max-substitution-jobs = mkDefault 4;
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

  # ── Resource guards ─────────────────────────────────────────
  # Why this section exists, concretely: a single `nix build` that
  # substituted LibreOffice (1.5 GB unpacked) locked this 4 GB laptop
  # up for forty minutes. Input events arrived 20 seconds late,
  # journald could not write, and nothing was ever OOM-killed.
  #
  # Nothing was killed because nothing looked out of memory. Swap
  # stayed 98% free throughout — the pressure was not anonymous
  # pages. nix-daemon peaked at 944 MB while the kernel evicted
  # file-backed pages to make room, which on this machine means
  # everybody's executables and the store itself, and then had to
  # fault them straight back in. Its cgroup scanned ten million pages
  # doing it. The kernel counts that memory as reclaimable, so the
  # OOM killer never has grounds to fire and the machine just
  # thrashes. PSI for that boot: 20 minutes of memory stall, 13 of
  # them with nothing runnable at all, plus 36 minutes of I/O stall.
  #
  # That is also why there is no earlyoom here. A free-memory
  # watchdog cannot see this: memory and swap both read healthy right
  # through it. The guards are pressure- and cgroup-based instead,
  # and they are aimed at the offender rather than the victim.
  #
  # The victim's side of the same argument is in modules/session.nix,
  # where MemoryLow keeps reclaim off the compositor's pages — the
  # thing that was actually being evicted in the measurement above.

  # Build scratch off the tmpfs. /tmp is tmpfs at 50% of RAM
  # (boot.tmp in boot.nix) and nix unpacks sources into TMPDIR, so
  # every large build spends real memory on files it is about to
  # compile and throw away — on the machine least able to lend it.
  #
  # The cgroup makes this worse rather than better, which is the part
  # worth spelling out: tmpfs pages are charged to whoever allocated
  # them, so a build's scratch counts against nix-daemon's MemoryHigh
  # below, and reclaiming it pushes the scratch into zram. The result
  # is source trees being lz4-compressed into RAM by one part of the
  # system while another part is standing by to zstd-compress them onto
  # a disk that has room. /var/tmp is on the btrfs root, where the
  # compression is already paid for and the space is not RAM.
  systemd.services.nix-daemon.environment.TMPDIR = mkDefault "/var/tmp";

  systemd.services.nix-daemon.serviceConfig = {
    # A ceiling nix reclaims against *inside its own cgroup*, page
    # cache included — which is the whole point, since page cache is
    # what it was taking. MemoryHigh throttles, it does not kill: a
    # big build or a big download simply goes slower, and no
    # derivation fails because of it. nix.settings.use-cgroups above
    # puts each build in a child cgroup, so the ceiling covers builds
    # and substitutions alike. 40% is ~1.5 GB here, comfortably above
    # the 944 MB an ordinary large fetch peaked at.
    MemoryHigh = mkDefault "40%";
    # Interactive work wins the CPU when nix is busy.
    CPUWeight = mkDefault 50;
    # And the disk. This used to be pointless and is not any more: the
    # note in storage.nix explaining that io.weight is a no-op under
    # mq-deadline was correct for every machine except the ones with a
    # platter, because only BFQ implements it — and until the rule
    # added there, only the platter got BFQ. Now that every non-NVMe
    # device does, the guard this section wanted from the beginning is
    # available, and MemoryHigh no longer has to carry the whole
    # argument alone. 50 against the default 100 everything else runs
    # at halves nix's share of the disk, matching what CPUWeight does
    # to its share of the CPU.
    IOWeight = mkDefault 50;
    # Backstop, deliberately scoped to this one unit. systemd-oomd is
    # already running (NixOS enables it) but polices nothing by
    # default: every slice ships ManagedOOM*=auto and `oomctl`
    # reports zero monitored cgroups. Setting it here — rather than
    # via systemd.oomd.enableUserSlices — is what makes it safe on
    # this desktop, where labwc lives in the logind session scope and
    # apps started from the panel inherit sfwbar's cgroup: policing
    # the user slices would let oomd answer a nix storm by killing
    # the panel, the editor, or the whole session. This way the only
    # thing it can kill is the daemon that caused the pressure, and
    # nix-daemon is socket-activated, so it comes straight back.
    #
    # The cost is real and worth stating: this can kill a legitimate
    # local build of something enormous, which is why the threshold
    # is 80% rather than oomd's 60% default. At 80% of wall-clock
    # time stalled on memory for thirty seconds straight, the build
    # was not going to finish in any useful time anyway, and the
    # machine it is running on is unusable while it tries. The
    # upgrade timer's Restart=on-failure picks it up again.
    ManagedOOMMemoryPressure = mkDefault "kill";
    ManagedOOMMemoryPressureLimit = mkDefault "80%";
  };

  # The store optimiser (nix.optimise above), minus the one condition
  # NixOS ships that does not survive contact with this target. Its
  # unit carries ConditionACPower = true, which is a reasonable default
  # for a desktop and a trap for a laptop: a machine that spends its
  # week on battery has the timer fire, the condition fail, the run
  # recorded as satisfied, and the store never deduplicated at all.
  # Persistent = true does not rescue it either — that catches up runs
  # missed while the machine was powered OFF, not runs skipped while it
  # was powered by a battery. The failure is silent in both directions:
  # nothing errors, and `systemctl status` reports success.
  #
  # Dropping the condition is safe precisely because of how the unit is
  # otherwise scheduled: Nice = 19, idle CPU class, idle I/O class. It
  # yields to everything, the desktop included, and now that
  # storage.nix puts BFQ under every non-NVMe disk that idle I/O class
  # is enforced rather than advisory. What it costs is some battery,
  # once a week, on a machine idle enough for an idle-class job to get
  # anywhere at all.
  #
  # mkForce, and it has to be: nix-optimise.nix sets the condition at
  # normal priority, so mkDefault here loses silently — the option
  # merges, the eval succeeds, and the pass still never runs. Which is
  # this same failure arriving by a second route, and is why the eval
  # test for this reads the value back rather than trusting the write.
  systemd.services.nix-optimise.unitConfig.ConditionACPower = mkForce "";

  # ── nixpkgs ─────────────────────────────────────────────────
  nixpkgs.config = {
    allowBroken = true;
    allowUnfree = true;
    allowUnfreePredicate = _: true;
  };
  # Allow unfree by default
  environment.etc."nix/nixpkgs-config.nix".text = lib.mkDefault ''
    { allowUnfree = true; }
  '';

  # gitMinimal, not git. What git is here for is `nixos-rebuild --flake
  # /etc/nixos` and the flake update behind system-upgrade — plumbing,
  # not a development tool. Full git brings its Perl scripts (send-email,
  # svn, cvsimport), Tcl/Tk for gitk and git-gui, a Python interpreter and
  # 16 MB of HTML documentation, none of which a rebuild ever calls. The
  # porcelain and everything a flake touches is identical.
  programs.git = {
    enable = true;
    package = mkDefault pkgs.gitMinimal;
    config.safe.directory = [ "/etc/nixos" ];
  };

  # ── Automatic background upgrades ───────────────────────────
  # Daily (was hourly — a full flake eval transiently costs hundreds
  # of MB, which matters on small-RAM machines): refresh the flake
  # inputs and `nixos-rebuild switch` (via systemUpgradeScript). A
  # root oneshot, gated only on network-online.target — there is no
  # metered-connection check, because neither iwd nor networkd has the
  # concept, so there is nothing to read. NixOS's own
  # system.autoUpgrade stays
  # off (below) — this timer is the mechanism, and features.autoUpgrade
  # is the switch (the manual system-upgrade command always works).
  # The live session keeps its binaries (session user services carry
  # restartIfChanged=false), so an upgrade never pulls the desktop out
  # from under the user mid-session; session updates land on next login.
  systemd.services.system-upgrade = mkIf cfg.features.autoUpgrade {
    restartIfChanged = false;
    unitConfig = {
      Description = "Update flake inputs and switch NixOS configuration";
      StartLimitIntervalSec = 300;
      StartLimitBurst = 5;
    };
    serviceConfig = {
      Type = "oneshot";
      User = "root";
      Environment = "HOME=/root";
      ExecStart = lib.getExe systemUpgradeScript;
      Restart = "on-failure";
      RestartSec = "120s";
      # The same guards as nix-daemon, for the same reason and then
      # some: this is the one thing on the machine that runs a full
      # flake eval (hundreds of MB) and a rebuild unattended, on a
      # timer, while someone is presumably in the middle of using the
      # desktop. It should always be the process that yields. The
      # eval and the rebuild driver run here; the fetching and
      # building they trigger runs in nix-daemon, under its own
      # ceiling. See "Resource guards" above.
      MemoryHigh = mkDefault "25%";
      CPUWeight = mkDefault 20;
      IOWeight = mkDefault 20;
      Nice = mkDefault 19;
    };
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    path = with pkgs; [
      nix
      gitMinimal
    ];
  };

  systemd.timers.system-upgrade = mkIf cfg.features.autoUpgrade {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "daily";
      Persistent = true;
      Unit = "system-upgrade.service";
    };
  };
}
