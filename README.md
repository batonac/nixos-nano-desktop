# NixOS Nano Desktop

A complete Wayland desktop for hardware everyone else has given up on, as a
single NixOS module plus an installer.

The target is a machine like the one this was written on: a 2012 Ivy Bridge
laptop, dual core, 4 GB of RAM, a small disk. That constraint drives every
choice here — a compositor and panel that idle in single-digit megabytes, no
resident daemon that something else can do on demand, and cgroup guards so a
`nixos-rebuild` cannot make the pointer stop moving. It is a full desktop, not
a rescue environment: browser, office suite, printing, scanning, bluetooth,
media playback, hardware video decoding.

It runs fine on current hardware too. It is simply built as though it will not
get any.

## What you get

| | |
|---|---|
| Compositor | [labwc](https://labwc.github.io/) (Wayland, Openbox-like), boots straight to it on tty1 |
| Panel | [sfwbar](https://github.com/LBCrion/sfwbar) — app menu, taskbar, wifi, bluetooth, volume, battery, clock, SNI tray |
| Terminal / launcher | foot, fuzzel |
| Notifications / lock | mako (with volume + brightness OSD), swaylock |
| Browser / editor | Firefox, Geany |
| Files | PCManFM, Xarchiver |
| Media / documents | Celluloid, image-roll, Atril |
| Office | LibreOffice, or AbiWord + Gnumeric, or nothing — see `officeSuite` |
| Networking | iwd + systemd-networkd (no NetworkManager), iwgtk for the awkward cases |
| Printing / scanning | CUPS (socket-activated), SANE with driverless network scanning |
| Look | Adwaita dark throughout — adw-gtk3-dark, Papirus-Dark, Adwaita Sans/Mono, locked via a system dconf profile |

Storage is btrfs with zstd compression on the root, sized and tuned by
`diskType`; zram sits above the disk swap so compressed RAM fills first.

## Install

The installer is derived from the module's own options — the menu you see is
`nanoDesktop.*`, so it can never drift from what the desktop actually accepts.
It comes from [nixos-install-helper](https://github.com/Avunu/nixos-install-helper).

```sh
nix run github:batonac/nixos-nano-desktop     # wizard, straight from the flake
nix run .                                     # or from a checkout
nix run . -- root@<ip>                        # pre-seed a network-install target
```

The wizard walks you through settings and then a deployment path. The
individual steps are also exposed:

```sh
nix run .#configure            # questionnaire → installer/nanoDesktop-settings.json
nix run .#install              # unattended ISO | guided ISO | network install
nix run .#deploy -- root@<ip>  # nixos-anywhere to a reachable machine
```

| Path | Offline | Per-host config |
|---|:---:|---|
| Unattended ISO (`.#installerIso`) | yes | baked in at build time |
| Guided ISO (`.#guidedIso`) | yes | chosen on the machine at boot |
| Network install (`.#deploy`) | no | full |

`installer/` is deliberately **not** committed — per-host identity stays on
your machine. The wizard injects it by absolute path, so building an ISO
directly needs that done by hand:

```sh
IH_SETTINGS_DIR=$PWD/installer nix build --impure .#installerIso
```

Without it the ISO would silently bake the option defaults, and
`nanoDesktop.username` has none, so a plain `nix build .#installerIso` fails
rather than producing a wrong ISO.

### After installing

`/etc/nixos` gets a small synthesized flake that tracks this repo, applies your
`nanoDesktop-settings.json`, and imports `local.nix` if it exists — that last
file is yours, never rewritten by an upgrade, and the right place for anything
that is a Nix value rather than a JSON string (an extra package, an overlay, a
service).

```sh
sudo nixos-rebuild switch --flake /etc/nixos   # resolves by hostname
system-upgrade                                 # flake update + switch, in one
```

`system-upgrade` is also on a daily timer (`features.autoUpgrade`, on by
default). Either way the running session keeps its current binaries — session
services are marked `restartIfChanged = false`, so an upgrade never yanks the
desktop out from under you. Session-level changes land at the next login.

## Configuration

| Option | Type | Default | |
|---|---|---|---|
| `hostName` | string | *required* | |
| `username` | string | *required* | |
| `initialPassword` | string | `"password"` | **change this** |
| `diskDevice` | string | `/dev/sda` | install target |
| `diskType` | `ssd` \| `hdd` | `ssd` | mkfs + mount profile; install-time, migrates nothing |
| `compressionLevel` | `fast` \| `balanced` \| `max` | `fast` | zstd 1 / 6 / 12; safe to change later |
| `swapSizeGiB` | int | `8` | `0` omits the partition (and hibernation) |
| `bootMode` | `uefi` \| `legacy` | `uefi` | systemd-boot or GRUB |
| `cpuMitigations` | bool | `true` | `false` adds `mitigations=off` — a security decision |
| `hardwareVideo` | `auto` \| `intel-modern` \| `intel-legacy` \| `none` | `auto` | VA-API driver; the two Intel drivers cover disjoint generations |
| `officeSuite` | `libreoffice` \| `gnome` \| `none` | `libreoffice` | also sets the document MIME types |
| `timeZone` / `locale` | string | `America/New_York` / `en_US.UTF-8` | |
| `stateVersion` | string | `"25.11"` | |
| `extraPackages` | list of packages | `[ ]` | |
| `enableSsh` | bool | `false` | `sshPasswordAuth`, `sshRootLogin` apply when on |

Every desktop service that costs idle RAM or disk but is not essential sits
behind a feature flag. They set the underlying NixOS options with `mkDefault`,
so setting those directly still wins.

| `features.*` | Default | |
|---|:---:|---|
| `audioServer` | `off` | PipeWire/WirePlumber. Off means apulse/pressureaudio — PulseAudio API over bare ALSA, no daemon, but also no bluetooth audio and no per-app volume |
| `desktopPortal` | `off` | xdg-desktop-portal + GTK backend. The native paths already cover file dialogs, notifications, OpenURI and dark mode; turn on for Flatpak or screen casting |
| `processScheduling` | `off` | ananicy-cpp with the CachyOS rules |
| `autoUpgrade` | `on` | the daily upgrade timer (`system-upgrade` works either way) |
| `bluetooth` | `on` | bluetoothd + blueman-manager |
| `clipboardHistory` | `on` | Super+V history and Super+. unicode picker |
| `networkDiscovery` | `on` | Avahi mDNS — `.local` names, printer/scanner discovery |
| `printing` | `on` | CUPS + system-config-printer |
| `scanning` | `on` | SANE + sane-airscan |
| `thermalManagement` | `on` | thermald. **Intel only** — it exits on AMD, leaving a failed unit |
| `thumbnails` | `on` | Tumbler |
| `virtualFilesystems` | `on` | GVFS — trash, MTP/PTP, network shares |

Each option carries its full reasoning in
[modules/options.nix](modules/options.nix), which is also what the installer
renders. Read it there rather than here.

### Using the module directly

```nix
{
  inputs.nixos-nano-desktop.url = "github:batonac/nixos-nano-desktop";

  outputs = { nixpkgs, nixos-nano-desktop, ... }: {
    nixosConfigurations.laptop = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        nixos-nano-desktop.nixosModules.nanoDesktop
        {
          nanoDesktop = {
            hostName = "laptop";
            username = "you";
            diskType = "hdd";
            hardwareVideo = "intel-legacy";
            features.audioServer = true;
          };
        }
      ];
    };
  };
}
```

The module pulls in disko and declares the whole partition table from
`diskDevice` / `diskType` / `swapSizeGiB`, so it expects to own the disk. It
also sets `networking.hostName`, the primary user, the bootloader and the root
filesystem — it is a whole-machine configuration, not a desktop layer to drop
onto an existing one.

## Keyboard

| | |
|---|---|
| `Super+Space`, `F12`, `Alt+F2` | application launcher (fuzzel) |
| `Super+Return` | terminal |
| `Super+L` | lock screen |
| `Super+V` | clipboard history |
| `Super+.` | unicode / emoji picker |
| `Print` / `Shift+Print` | screenshot, full or region — saved to `~/Pictures` and copied |
| volume / mic / brightness keys | adjust, with an on-screen bar |
| right-click on the desktop | root menu |

labwc's own defaults are loaded too, so `Alt+Tab`, `Alt+F4` and friends work as
expected.

## Repository layout

`nixosModules.nanoDesktop` is one module, assembled from `modules/`:

| | |
|---|---|
| [modules/options.nix](modules/options.nix) | every `nanoDesktop.*` option — and the installer's menu |
| [modules/boot.nix](modules/boot.nix) | kernel, command line, sysctls, bootloader, `/tmp` |
| [modules/storage.nix](modules/storage.nix) | disk profiles, the disko table, zram, block-layer tuning |
| [modules/hardware.nix](modules/hardware.nix) | graphics + VA-API, bluetooth, scanners, power management |
| [modules/networking.nix](modules/networking.nix) | iwd + networkd, Avahi, firewall, SSH |
| [modules/audio.nix](modules/audio.nix) | PipeWire, or apulse/pressureaudio when it is off |
| [modules/nix.nix](modules/nix.nix) | nix settings, the resource guards, the upgrade timer |
| [modules/system.nix](modules/system.nix) | console, locale, users, polkit, documentation |
| [modules/desktop.nix](modules/desktop.nix) | `/etc/xdg` config, session environment, fonts, theme |
| [modules/session.nix](modules/session.nix) | the tty1 labwc service and the systemd user session |
| [modules/applications.nix](modules/applications.nix) | what is installed, and which application opens what |
| [modules/services.nix](modules/services.nix) | the remaining daemons, each behind a feature flag |
| [pkgs/](pkgs/) | the two derivations more than one module needs |

The desktop's own configuration is static project files rather than generated
Nix strings — [labwc/](labwc/), [sfwbar/](sfwbar/), [foot/](foot/),
[fuzzel/](fuzzel/), [mako/](mako/). They are installed into `/etc/xdg` and
loaded explicitly, and they reference executables through
`/run/current-system/sw/bin/` so menu and panel entries keep resolving across
package updates and garbage collection. **Edit those files to change the
desktop** — `nixos-rebuild switch` installs the new copies, and labwc's
*Reconfigure* menu entry re-reads its own config without restarting the
session.

[unicode/build-index.py](unicode/build-index.py) builds the emoji/character
index the picker searches, from the Unicode data already packaged in nixpkgs.

The Nix here is `nixfmt`-clean:

```sh
nix develop                                   # mcp-nixos
nix run nixpkgs#nixfmt-rfc-style -- flake.nix modules/*.nix pkgs/*.nix
```

## Things worth knowing before you install this

Not defaults so much as positions, all of them reversible:

- **The firewall is off** (`networking.firewall.enable = mkDefault false`).
  Reasonable for a single-user laptop with no listening services; set it true
  if that is not your machine.
- **`initialPassword` defaults to `password`.** Change it at install, or
  immediately after.
- **No input method.** Latin keyboard layouts are fine (set
  `environment.sessionVariables.XKB_DEFAULT_LAYOUT`), but CJK and other
  composed scripts need fcitx5 or ibus added back through `extraPackages` plus
  a user service. This replaced an fcitx5-based clipboard implementation that
  sat in the path of every keystroke on the machine.
- **iwd is 802.11 only** — no VPN plugins, no ModemManager/WWAN, no
  captive-portal detection, no connection sharing. VPNs become declarative
  (`networking.wireguard` and friends). A card whose driver only ever behaved
  under wpa_supplicant wants `networking.networkmanager.enable = true`
  alongside `useNetworkd = false` and `wireless.iwd.enable = false`.
- **No man pages or NixOS docs** on the installed system, to save the disk.
- **Wayland only.** `GDK_BACKEND=wayland` is set deliberately, so an X-only GTK
  app fails loudly instead of quietly starting XWayland.
- **`nix-daemon` is throttled** — `MemoryHigh` at 40%, `CPUWeight` 50, and
  systemd-oomd allowed to kill it (and only it) at sustained memory pressure.
  A large build goes slower; the desktop stays usable. The measurement that
  motivated this is written up under "Resource guards" in
  [modules/nix.nix](modules/nix.nix).
- **`allowUnfree` and `allowBroken` are on.**

Most non-obvious choice in this repo carries its reasoning, and often the
measurement, in a comment next to it. If something here looks wrong, the
argument for it is probably in the file.
