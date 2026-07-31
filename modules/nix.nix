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
    settings = {
      # Left on under both diskTypes, which is worth stating because
      # the hard-linking pass is random I/O and a platter is where
      # random I/O hurts. It stays because it and compression save
      # different things, and neither substitutes for the other:
      # compression shrinks a file, hard-linking removes the second
      # and third copy of one. A Nix store carries a great many
      # byte-identical files across generations and packages, and no
      # compression ratio touches a duplicate.
      auto-optimise-store = true;
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

  programs.git = {
    enable = true;
    config.safe.directory = [ "/etc/nixos" ];
  };

  # ── Automatic background upgrades ───────────────────────────
  # Daily (was hourly — a full flake eval transiently costs hundreds
  # of MB, which matters on small-RAM machines): refresh the flake
  # inputs and `nixos-rebuild switch` (via systemUpgradeScript). A
  # root oneshot, gated only on network-online.target. There used to
  # be a metered-connection check here (nmcli GENERAL.METERED); it
  # went with NetworkManager, and it was already inert — nothing in
  # this desktop could ever set the flag once nm-applet was dropped,
  # so NM only ever reported "no (guessed)". Neither iwd nor networkd
  # has the concept at all. Mirrors the micro desktop. NixOS's own
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
      Nice = mkDefault 19;
    };
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    path = with pkgs; [
      nix
      git
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
