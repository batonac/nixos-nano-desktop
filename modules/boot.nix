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
      # Zeroing every page on allocation and on free is a nixpkgs
      # default (CONFIG_INIT_ON_ALLOC_DEFAULT_ON), not an upstream
      # one — Debian, Fedora and Arch all ship the kernel's own
      # setting, which is off, and which is what these two restore.
      # It buys back a memset on every allocation, and the memory
      # bandwidth it is spending belongs to a 2012 laptop.
      #
      # What it gives up is hardening rather than a fix for any
      # particular hole: uninitialised heap and page contents stop
      # being reliably zero, which makes some info-leak and
      # use-after-free bugs easier to turn into exploits. The larger
      # lever of the same kind is nanoDesktop.cpuMitigations, and
      # that one is deliberately left at the safe setting.
      "init_on_alloc=0"
      "init_on_free=0"
      "loglevel=3"
      "mem_sleep_default=deep"
      # No lockup detector: one armed perf counter and one timer per
      # CPU, permanently, to catch a class of kernel bug this desktop
      # can do nothing about anyway. It is also what prints "perf:
      # interrupt took too long" once the machine is already in
      # trouble. Cost of turning it off: a hard lockup hangs quietly
      # instead of panicking with a backtrace.
      "nmi_watchdog=0"
      "nowatchdog"
      "pcie_aspm.policy=powersupersave"
      # CONFIG_PREEMPT_DYNAMIC makes this a boot-time choice instead
      # of a kernel rebuild. Full preemption lets the scheduler
      # interrupt the kernel itself: a little throughput for the one
      # thing this desktop cares about, which is that the pointer
      # keeps moving while something heavy is running.
      "preempt=full"
      "quiet"
      "rd.systemd.show_status=false"
      "systemd.show_status=false"
      "rd.udev.log_level=3"
      # Huge pages only where a program asks for one. The kernel
      # default ("always") has khugepaged compacting memory in the
      # background to manufacture 2 MB pages, and compaction on a
      # small, fragmented, already-tight machine is precisely the
      # latency spike the reclaim tuning below exists to avoid.
      "transparent_hugepage=madvise"
      "udev.log_priority=3"
    ]
    ++ optional (!cfg.cpuMitigations) "mitigations=off"
    # nanoDesktop.cpuBufferClears. Narrower than mitigations=off above
    # and, on the right machine, free: VERW clears the CPU's internal
    # buffers only where microcode taught it to, and this drops the
    # instruction on the parts where it never was. PTI, retpolines and
    # L1TF's PTE inversion all stay. The option carries the argument
    # and, more to the point, the one file to read before setting it.
    ++ optional (!cfg.cpuBufferClears) "mds=off";
    kernel.sysctl = {
      # High on purpose, and it stays high: with zram the cheap thing
      # to evict is anonymous memory (compressed, still in RAM), and
      # the expensive thing is file-backed pages, which have to be
      # read back off the disk. See the reclaim note under "Resource
      # guards" in nix.nix — the stall this machine actually suffers is
      # refaulting executables, not swapping. Note this argument
      # gets *stronger* under diskType = "hdd", not weaker: the
      # refault it is avoiding costs a seek there.
      "vm.swappiness" = mkDefault 100;
      "vm.vfs_cache_pressure" = mkDefault 50;
      # No swap-in readahead. Right for zram, which is the tier that
      # is actually hot — reading one compressed page back is cheap
      # and guessing at neighbours is not. Deliberately not raised
      # for diskType = "hdd", even though batched readahead would
      # suit the platter: the disk swap there sits below zram at a
      # priority the kernel only reaches under real pressure, and
      # tuning for it would tax every zram fault to help the case
      # where the machine has already lost.
      "vm.page-cluster" = mkDefault 0;
      # kswapd wakes when free memory drops to 0.1% of the zone —
      # on a 4 GB machine that is a runway of a few MB, so a burst of
      # allocation overruns it and lands in *direct* reclaim, which
      # stalls the allocating thread instead of a background kernel
      # thread. 2% gives kswapd room to keep ahead. Costs a little
      # memory kept free that could have been cache.
      "vm.watermark_scale_factor" = mkDefault 200;
      # Bound the writeback backlog. The defaults (20% hard, 10%
      # background) let ~750 MB of dirty pages queue up here before
      # anything is forced out, and this desktop has no fast way to
      # drain that: every page goes through zstd compression on the
      # way out under either diskType, and under "hdd" it then has a
      # platter to reach. Either way the queue empties slowly and
      # whoever hits
      # the hard limit blocks until it does. Starting earlier keeps
      # each stall short, which is why one pair of values covers both.
      "vm.dirty_ratio" = mkDefault 10;
      "vm.dirty_background_ratio" = mkDefault 5;
      # Background CPU spent keeping high-order pages available. With
      # transparent_hugepage=madvise almost nothing on this desktop
      # asks for one, so it is work done for nobody.
      "vm.compaction_proactiveness" = mkDefault 0;
      # Boosting temporarily multiplies the reclaim watermark after a
      # fragmentation event, which on a 4 GB machine arrives as a
      # burst of eviction. The steady, higher watermark set above is
      # the behaviour wanted here instead of a spiky one.
      "vm.watermark_boost_factor" = mkDefault 0;
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
    # The root filesystem in use is added to this set automatically —
    # nixpkgs derives it from `fileSystems` at normal priority, which
    # would quietly override an mkDefault false here — so btrfs would
    # arrive on its own regardless, and is stated only to say what
    # this system mounts. The false entries are the point: they keep
    # drivers, initrd modules and userspace tools off a machine that
    # will never mount one. f2fs and XFS are named explicitly because
    # this module used to install one or the other, and a leftover
    # f2fs-tools closure is exactly the kind of thing that survives a
    # refactor unnoticed. ext3 is covered by the ext4 driver either
    # way, and ext4 itself stays because legacy boot puts /boot on it.
    supportedFilesystems = {
      btrfs = mkDefault true;
      ext3 = mkDefault false;
      f2fs = mkDefault false;
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
}
