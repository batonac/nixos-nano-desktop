{
  config,
  lib,
  pkgs,
  ...
}:
with lib;
let
  cfg = config.nanoDesktop;

  # ── Storage profile (diskType / swapSizeGiB) ─────────────────
  # Everything that has to be decided before the disk exists, keyed on
  # nanoDesktop.diskType. The counterpart to this is the udev block
  # under services.udev.extraRules, which tunes the block layer per
  # device off queue/rotational instead — see the note there for why
  # the split is deliberate.
  #
  # What it costs is copy-on-write: fragmentation wherever something
  # rewrites in place (autodefrag answers that on the platter, where it
  # matters), more metadata churn than f2fs, and the near-full
  # behaviour btrfs is known for — the one real risk on a small
  # soldered disk with no second device to add. Halving the store is
  # also the best defence against ever arriving there.
  #
  # GRUB never reads this filesystem: legacy boot gets an ext4 /boot
  # and UEFI a vfat ESP. So none of the usual "will the bootloader cope
  # with compression, or with this mkfs feature" caution applies.

  # ── Root compression (compressionLevel) ──────────────────────
  # btrfs zstd takes 1-15 and compresses in fixed 128KB extents, so
  # unlike f2fs — where the cluster size had to move with the level —
  # there is one number to pick. The fixed extent is worth knowing
  # about on the read side: any read decompresses the whole extent it
  # lands in, which is coarser than f2fs's 16-64KB clusters were. The
  # page cache is what absorbs that.
  compressionLevel =
    {
      fast = 1;
      balanced = 6;
      max = 12;
    }
    .${cfg.compressionLevel};

  # compress-force, not compress: btrfs's heuristic samples the *first*
  # blocks of a file and, if they look incompressible, marks the whole
  # file to skip compression permanently. For an ELF binary behind an
  # incompressible header that is the wrong call, made once, for the
  # life of the file. Forcing it only costs attempts — btrfs still
  # stores the extent raw whenever compressing it would not be smaller.
  rootCompression = "compress-force=zstd:${toString compressionLevel}";

  # Neither profile names ssd/nossd: btrfs picks that up from
  # queue/rotational, the same flag the udev rules key on, so it is
  # right even on a machine whose diskType is wrong. space_cache=v2 is
  # likewise the kernel default now and goes unstated.
  diskProfile =
    {
      ssd = {
        rootMountOptions = [
          rootCompression
          # Async discard batches freed extents and trickles them out.
          # It replaces the nodiscard + daily fstrim posture the f2fs
          # root carried, because on cheap eMMC a batched
          # whole-filesystem trim is precisely the multi-second stall
          # the rest of this module works to avoid. Also btrfs's own
          # default since 6.2 — stated anyway, since the fstrim timer
          # it displaces has to be switched off by hand (see
          # services.fstrim).
          "discard=async"
          # Store small files inside the metadata b-tree rather than
          # giving each one a 4KB block of its own. A Nix store is
          # mostly small files, so this is not a rounding error.
          #
          # It is only correct next to -m single below. Inline data
          # lives in metadata, so under the DUP metadata mkfs.btrfs
          # defaults to, every inlined byte is written twice and
          # anything past ~2KB costs more inlined than it would as a
          # plain block — which is exactly why the kernel's own
          # default is 2048 and not the sectorsize. Raise one without
          # the other and small files get bigger.
          "max_inline=4096"
          "noatime"
        ];
        rootExtraArgs = [
          "-L"
          "root"
          "-d"
          "single"
          # single, not the DUP that mkfs.btrfs has defaulted to for
          # single-device filesystems since 5.15 (it dropped the older
          # "single on non-rotational" detection). Two reasons: it is
          # what makes max_inline=4096 pay, and the redundancy DUP buys
          # is aimed at bad sectors, which is how a platter fails, not
          # flash. The man page asks for both profiles to be stated
          # explicitly rather than inferred, which is why -d is here
          # too even though single is already its default.
          "-m"
          "single"
        ];
        # fstrim(8) walks mounted filesystems and never touches a swap
        # partition, so swapon's own discard is the only thing that
        # ever trims this area — and now that the fstrim timer is off
        # entirely, the only thing at all. "once" does it at swapon and
        # then leaves the device alone, rather than issuing a discard
        # on every page freed.
        swapDiscardPolicy = "once";
      };
      hdd = {
        rootMountOptions = [
          # A capability the platter gains rather than a tax it pays:
          # the disk is the bottleneck there by a wide margin, so bytes
          # not written are seeks not taken. The XFS root this replaced
          # had no equivalent at all.
          rootCompression
          # CoW scatters in-place rewrites across new extents, which on
          # a platter is the seek storm the XFS root existed to avoid.
          # This is btrfs's answer: small random writes (under ~64KB)
          # are detected and queued for rewriting contiguously. It
          # breaks reflinks, which costs nothing here —
          # auto-optimise-store deduplicates with hard links, and a
          # hard link is not a reflink.
          "autodefrag"
          # The same crash-window-for-seeks trade the XFS root made
          # with logbsize=256k, doubling the default 30s commit so that
          # metadata batches into fewer, larger writes. It widens the
          # window of data not yet on the platter if the power goes;
          # fsync is still honoured, so what is traded is that window,
          # not a durability guarantee.
          "commit=60"
          "noatime"
        ];
        rootExtraArgs = [
          "-L"
          "root"
          "-d"
          "single"
          # DUP here, unlike on flash: metadata redundancy is aimed at
          # bad sectors and that is how platters fail. It is also why
          # max_inline is left at its 2048 default on this side —
          # under DUP, inlining past that writes more than it saves.
          "-m"
          "dup"
        ];
        # Nothing to trim on a platter.
        swapDiscardPolicy = null;
      };
    }
    .${cfg.diskType};

  # Partitions shared by both boot modes. Defined once here because the
  # uefi and legacy tables differ only in what comes *before* them (an
  # ESP, versus a BIOS boot partition plus an ext4 /boot) — and because
  # keeping two copies is how the legacy branch ended up silently
  # missing compress_cache and the whole nocompress_extension list.
  swapPartition = {
    size = "${toString cfg.swapSizeGiB}G";
    content = {
      type = "swap";
      resumeDevice = true;
      discardPolicy = diskProfile.swapDiscardPolicy;
    };
  };
  rootPartition = {
    size = "100%";
    content = {
      type = "filesystem";
      format = "btrfs";
      mountpoint = "/";
      mountOptions = diskProfile.rootMountOptions;
      extraArgs = diskProfile.rootExtraArgs;
    };
  };
  # Ordering is disko's job, not the attribute names': it sorts by the
  # partition's `priority`, which defaults to 9001 for size = "100%".
  # Root is therefore created last whether or not swap is present, so
  # dropping the swap partition at swapSizeGiB = 0 needs nothing else.
  diskPartitions =
    optionalAttrs (cfg.swapSizeGiB > 0) {
      swap = swapPartition;
    }
    // {
      root = rootPartition;
    };
in
{
  # ── Disk Layout (disko) ─────────────────────────────────────
  # Only the leading partitions differ between the boot modes — an
  # ESP, versus a BIOS boot partition plus an ext4 /boot. Swap and
  # root are the same table either way and come from diskPartitions
  # in the let block above, which is also where diskType picks the
  # root filesystem and swapSizeGiB sizes (or removes) the swap.
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
          }
          // diskPartitions;
        })
        (mkIf (cfg.bootMode == "legacy") {
          type = "gpt";
          partitions = {
            boot = {
              size = "1M";
              type = "EF02";
            };
            # GRUB reads ext4 natively and completely, which is not
            # something to lean on for a zstd-compressed btrfs root
            # whose mkfs features this module picks freely. A small
            # ext4 /boot keeps GRUB's modules somewhere it is certain
            # to reach them, and means the root filesystem is never
            # the bootloader's problem — which is what lets the
            # storage profiles above choose compression and metadata
            # layout on the merits.
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
          }
          // diskPartitions;
        })
      ];
    };
  };

  # ── Filesystems ─────────────────────────────────────────────
  fileSystems."/".noCheck = mkDefault true;

  # Off under both, and switched off rather than merely not
  # switched on, because NixOS enables it by default. Under "ssd"
  # the btrfs root carries discard=async, which releases extents as
  # they are freed instead of walking the whole filesystem on a
  # timer — steadier, and it spares a cheap eMMC the multi-second
  # trim stall that a batched pass can produce. Under "hdd" there
  # is nothing to trim at all. Note this is also why the swap
  # partition carries discardPolicy = "once" under "ssd": fstrim
  # only ever walked mounted filesystems, so swap was never covered
  # by it even when it did run.
  services.fstrim.enable = mkDefault false;

  # Block-layer tuning, per device class. This is the runtime half
  # of the storage story whose eval-time half is nanoDesktop.
  # diskType: everything here keys off the kernel's own
  # queue/rotational flag rather than the option, so it is also
  # correct for a second or external drive of the other kind, and
  # stays correct on a machine whose diskType is set wrong. The
  # kernel's own default is mq-deadline for everything, which is
  # the wrong answer at both ends of the range this desktop runs on.
  #
  # The two queue-attribute rules deliberately do not restrict
  # KERNEL=: a partition has no queue/ directory at all, so it
  # simply fails the match, and dropping the old sd[a-z] pattern
  # picks up sdaa+, USB and virtio disks it silently missed. The
  # hdparm rule below does keep the pattern, because that one is
  # sending an ATA command rather than writing a sysfs attribute.
  services.udev.extraRules = ''
    # NVMe reorders in hardware across deep queues; a software
    # scheduler in front of it is pure overhead.
    ACTION=="add|change", SUBSYSTEM=="block", KERNEL=="nvme[0-9]n[0-9]", ATTR{queue/scheduler}="none"
    # Spinning disks get BFQ, the one scheduler that will hold a
    # background writer off the head long enough for an interactive
    # read to land — the difference between "the machine is copying
    # a file" and "the machine is unusable until it finishes".
    ACTION=="add|change", SUBSYSTEM=="block", ATTR{queue/rotational}=="1", ATTR{queue/scheduler}="bfq"
    # And so does everything else that is not an NVMe — which in
    # practice means the SATA SSDs and the soldered eMMC that most of
    # this fleet actually boots from. They matched neither rule above
    # and fell through to the kernel's mq-deadline, which is precisely
    # the default the comment at the top of this block calls the wrong
    # answer; the two ends of the range were covered and the middle,
    # quietly, was not.
    #
    # eMMC is the case that decides it. One shallow queue, no command
    # reordering worth the name, and read latency that collapses the
    # moment a write is in flight — a Chromebook writing a browser
    # cache while someone is scrolling is the whole reason the
    # compressionLevel = "max" tier exists. mq-deadline's write
    # starvation window does nothing for that; BFQ's per-cgroup
    # accounting does.
    #
    # It is not free on a fast SATA SSD: BFQ spends CPU per request,
    # and these are not fast cores, so peak sequential throughput is
    # measurably lower than mq-deadline or none. That is the same trade
    # this module makes everywhere else — preempt=full, the writeback
    # bounds, the nix-daemon ceiling — and it is made the same way
    # here. A machine doing bulk I/O rather than desktop work wants
    # "kyber" or "none" instead, set by overriding this rule.
    #
    # BFQ is also the only mq scheduler that implements io.weight, so
    # this is what makes systemd's IOWeight= mean anything at all: the
    # guards under "Resource guards" in nix.nix now set it, and before
    # this rule they would have been writing to a file the block layer
    # ignored on every SSD machine.
    #
    # KERNEL!= rather than a rotational match, so NVMe keeps the
    # scheduler the rule above gives it. Devices with no queue/
    # directory (partitions) and no scheduler attribute (zram, which
    # is bio-based) fail the match and are left alone. Writing the
    # name is enough to load the module — bfq.ko carries the
    # bfq-iosched alias the block layer asks request_module for.
    ACTION=="add|change", SUBSYSTEM=="block", KERNEL!="nvme[0-9]n[0-9]", ATTR{queue/rotational}=="0", ATTR{queue/scheduler}=="?*", ATTR{queue/scheduler}="bfq"
    # Readahead, up from the 128 KB default. A platter charges the
    # same seek whether it then reads 128 KB or 1 MB, so the larger
    # window is close to free on the sequential reads that dominate
    # startup and file copies. It is a ceiling and not a floor:
    # Linux readahead is adaptive and only ramps to it once it has
    # actually detected a sequential pattern, so random small reads
    # do not start paying for page cache they will not use.
    ACTION=="add|change", SUBSYSTEM=="block", ATTR{queue/rotational}=="1", ATTR{bdi/read_ahead_kb}="1024"
    # Stop the heads parking. Laptop drives of this vintage ship
    # with APM aggressive enough to unload after a few seconds idle;
    # every read after that pays a ~1s load, and each cycle spends
    # one of a rated ~600k — which drives have exhausted inside a
    # year on Linux, since the desktop wakes the disk far more often
    # than the firmware's idle heuristic assumes. 254 is maximum
    # performance with APM still enabled (255 disables it outright,
    # which some firmware handles badly). The cost is real: no
    # automatic head unload means measurably more idle power, so
    # this is a laptop trading battery for the disk's lifetime and
    # for latency it would otherwise pay on every idle read.
    #
    # -q because drives and USB bridges that do not implement APM
    # answer with an error, and this is best-effort by nature.
    ACTION=="add", SUBSYSTEM=="block", ENV{DEVTYPE}=="disk", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="1", RUN+="${pkgs.hdparm}/bin/hdparm -q -B 254 /dev/%k"
  '';

  # ── zram ────────────────────────────────────────────────────
  zramSwap = {
    enable = mkDefault true;
    # lz4 rather than the zstd default. For a swap device the number
    # that matters is how long a fault takes to come back, not how
    # small the page got: zstd compresses perhaps 30% better and
    # costs several times as much CPU to decompress, and on these
    # machines that CPU is the scarce resource. Compressed swap is
    # only worth having while reading it back stays cheaper than
    # reading the disk it replaces.
    algorithm = mkDefault "lz4";
    # Explicit because the ordering carries weight: zram has to
    # outrank the disk swap partition disko creates (which lands at
    # priority -1), or the kernel will page out to the disk while
    # compressed RAM sits unused.
    priority = mkDefault 100;
    # 50% is the NixOS default and stays that on flash, where falling
    # through to the disk swap partition is merely slow. On a platter
    # it is the difference between a pause and a machine that has
    # stopped answering, so buy more headroom in compressed RAM before
    # anything reaches the disk at all.
    #
    # This is a capacity, not an allocation: the figure is how much
    # *uncompressed* anonymous memory the device will accept, and the
    # real RAM it occupies is that divided by the compression ratio,
    # only as it fills. At 75% with lz4 doing its usual 2-3x on
    # desktop anon pages, a full device is holding roughly three
    # quarters of RAM worth of pages in something like a quarter of
    # it. Distributions ship 100% at this point; 75% keeps a margin
    # for the case where the pages compress badly.
    memoryPercent = mkDefault (if cfg.diskType == "hdd" then 75 else 50);
  };
}
