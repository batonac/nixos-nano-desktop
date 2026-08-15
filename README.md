# NixOS Nano Desktop

A complete Wayland desktop for hardware everyone else has given up on, as a single NixOS module plus an installer.

The target is a machine like the one this was written on: a 2012 Ivy Bridge laptop, dual core, 4 GB of RAM, a small disk. That constraint drives every choice here — a compositor and panel that idle in single-digit megabytes, no resident daemon that something else can do on demand, and cgroup guards so a `nixos-rebuild` cannot make the pointer stop moving. It is a full desktop, not a rescue environment: browser, office suite, printing, scanning, bluetooth, media playback, hardware video decoding.

It runs fine on current hardware too. It is simply built as though it will not get any.

## What you get

|  |  |
| --- | --- |
| Compositor | labwc (Wayland, Openbox-like), boots straight to it on tty1 |
| Panel | sfwbar — app menu (with lock + power), search, taskbar, wifi, bluetooth, volume, battery, clock, SNI tray |
| Terminal / launcher | foot, fuzzel |
| Login / lock | gtklock — the password prompt at boot, and Super+L |
| Notifications | mako, with a volume + brightness OSD |
| Browser / editor | Firefox, GNOME Text Editor |
| Files | PCManFM, Xarchiver |
| Media / documents | Celluloid, image-roll, Evince |
| Office | LibreOffice, or AbiWord + Gnumeric, or nothing — see officeSuite |
| Networking | iwd + systemd-networkd (no NetworkManager), iwgtk for the awkward cases |
| Printing / scanning | CUPS (socket-activated), SANE with driverless network scanning |
| Look | Adwaita dark throughout — adw-gtk3-dark, MoreWaita icons, Adwaita Sans/Mono, locked via a system dconf profile. One accent colour and one background, set once and followed by every toolkit here — see accentColor / backgroundColor / backgroundImage |

There is no display manager and no greeter. The desktop starts as the user on tty1, and gtklock takes the screen as it comes up, so what you meet at boot is a password prompt with the session already loading behind it. That is the whole login stack: one lock screen, the user's own PAM password, and nothing resident between sessions.

Storage is btrfs with zstd compression on the root, sized and tuned by `diskType`; zram sits above the disk swap so compressed RAM fills first.

## Install

The installer is derived from the module's own options — the menu you see is `nanoDesktop.*`, so it can never drift from what the desktop actually accepts. It comes from [nixos-install-helper](https://github.com/Avunu/nixos-install-helper).

```sh
nix run github:batonac/nixos-nano-desktop     # wizard, straight from the flake
nix run .                                     # or from a checkout
nix run . -- root@<ip>                        # pre-seed a network-install target
```

The wizard walks you through settings and then a deployment path. The individual steps are also exposed:

```sh
nix run .#configure            # questionnaire → installer/nanoDesktop-settings.json
nix run .#install              # unattended ISO | guided ISO | network install
nix run .#deploy -- root@<ip>  # nixos-anywhere to a reachable machine
```

| Path | Offline | Per-host config |
| --- | --- | --- |
| Unattended ISO (.#installerIso) | yes | baked in at build time |
| Guided ISO (.#guidedIso) | yes | chosen on the machine at boot |
| Network install (.#deploy) | no | full |

`installer/` is deliberately **not** committed — per-host identity stays on your machine. The wizard injects it by absolute path, so building an ISO directly needs that done by hand:

```sh
IH_SETTINGS_DIR=$PWD/installer nix build --impure .#installerIso
```

Without it the ISO would silently bake the option defaults, and `nanoDesktop.username` has none, so a plain `nix build .#installerIso` fails rather than producing a wrong ISO.

### After installing

`/etc/nixos` gets a small synthesized flake that tracks this repo, applies your `nanoDesktop-settings.json`, and imports `local.nix` if it exists — that last file is yours, never rewritten by an upgrade, and the right place for anything that is a Nix value rather than a JSON string (an extra package, an overlay, a service).

```sh
sudo nixos-rebuild switch --flake /etc/nixos   # resolves by hostname
system-upgrade                                 # flake update + switch, in one
```

`system-upgrade` is also on a daily timer (`features.autoUpgrade`, on by default). Either way the switch restarts the desktop shell in place: the panel, notifications, background and clipboard watcher come back on the new version, and labwc reloads its configuration — so a changed accent colour or panel layout is on screen when the rebuild ends. Applications are untouched, because everything the panel launches gets its own scope under `app.slice` rather than living in the panel's cgroup. The compositor binary is the one thing that waits for the next login; nothing else has to.

### The settings app

**System Settings** (`nano-settings`, in the menu under Settings) is the GUI for everything in the tables below. It edits `nanoDesktop-settings.json`, changes the account password, adds packages, and runs the rebuild — so an installed machine never needs a terminal to be reconfigured.

Edits are batched: changing things marks the window dirty, and **Apply** shows what is about to change, then hands the whole file to a small root helper (`nano-settings-helper`, through `pkexec`) that writes it atomically and rebuilds. **If the rebuild fails, the previous settings are restored automatically** — a mistyped value cannot leave the machine unable to evaluate.

It is written in Python against GTK4/libadwaita, which is the one thing here that costs disk rather than memory: the GTK stack is already installed, but a Python interpreter is not, so it adds roughly 150 MB of closure. Turn it off with `features.settingsApp = false` on a machine where the disk is the binding constraint.

Two notes on how it fits the rest of this desktop. Nothing about it is resident — including the polkit authentication agent it needs to show a password prompt, which it spawns as its own child and kills on exit, because this desktop otherwise runs none. And what it knows is _generated_ at build time rather than restated in Python: the option list from [modules/options.nix](modules/options.nix), so a new option appears in the GUI with nothing to edit on the application side, and the accent swatches — the row of coloured circles GNOME's own settings has — from [pkgs/accent.nix](pkgs/accent.nix), so the colour in the circle is the colour the desktop is about to paint.

#### Working on it

It has a shell of its own — an interpreter, the GTK stack, and a `.venv` provisioned from them on entry for editors and language servers to point at. The venv holds nothing that is not derived from the shell, so deleting it loses nothing.

```sh
nix develop .#nano-settings
cd pkgs/nano-settings/src
pytest                 # the suite, with coverage; the bar is the whole package
mypy .                 # strict, against real PyGObject stubs
ruff check .
python -m nano_settings # run it against the schema the shell built
```

The suite builds real libadwaita widgets on an X server it starts itself, and drives the privileged helper, `nix eval` and `passwd` through stand-in scripts — so the streaming, the exit codes and the pty conversation are exercised rather than mocked. It runs in a sandbox too, which is where to check it before trusting it:

```sh
nix build .#nano-settings-tests   # mypy + pytest, roughly ten seconds
```

That is a package rather than a check phase on the app itself, so that an X server and a type checker stay out of the build closure of every machine this desktop installs.

## Configuration

| Option | Type | Default |  |
| --- | --- | --- | --- |
| hostName | string | required |  |
| username | string | required |  |
| initialPassword | string | "password" | change this |
| diskDevice | string | /dev/sda | install target |
| diskType | ssd \| hdd | ssd | mkfs + mount profile; install-time, migrates nothing |
| compressionLevel | fast \| balanced \| max | fast | zstd 1 / 6 / 12; safe to change later |
| swapSizeGiB | int | 8 | 0 omits the partition (and hibernation) |
| bootMode | uefi \| legacy | uefi | systemd-boot or GRUB |
| cpuMitigations | bool | true | false adds mitigations=off — a security decision |
| cpuBufferClears | bool | true | false adds mds=off. Free on a CPU whose vulnerabilities/mds says no microcode — read it first |
| browserSiteIsolation | bool | true | false turns off Firefox Fission — the biggest RAM lever here, and a security decision |
| energyPerfBias | balanced \| performance | balanced | performance writes EPB 4; trades battery for turbo residency. Intel only |
| virtualTerminals | bool | true | false masks the tty2…6 consoles. Frees no memory — closes five login doors and gives up Ctrl+Alt+F2 as a recovery path |
| disableLogging | bool | false | true is scorched earth: Storage=none, no forwarding, ring buffer emptied after boot. No journal means no diagnosis — and a failing autoUpgrade goes silent |
| hardwareVideo | auto \| intel-modern \| intel-legacy \| none | auto | VA-API driver; the two Intel drivers cover disjoint generations |
| officeSuite | libreoffice \| gnome \| none | libreoffice | also sets the document MIME types |
| accentColor | blue \| teal \| green \| yellow \| orange \| red \| pink \| purple \| slate | blue | GNOME's nine. libadwaita apps take it from dconf, GTK3 apps from a theme rebuilt around it, and labwc / the panel / fuzzel / mako / foot from their config files. Firefox and LibreOffice theme themselves and take none of it |
| backgroundColor | string | "#1c1c1f" | #rrggbb. Empty runs no wallpaper client at all — the only appearance option that costs a resident process (swaybg, ~2 MB plus one screen-sized buffer) |
| backgroundImage | string | "" | absolute path on the machine, not a Nix path — scaled to fill. Missing or unreadable at session start falls back to backgroundColor |
| timeZone / locale | string | America/New_York / en_US.UTF-8 |  |
| stateVersion | string | "25.11" |  |
| extraPackages | list of packages | [ ] |  |
| extraPackageNames | list of strings | [ ] | the same thing by nixpkgs attribute name ("gimp", "hunspellDicts.en_US"), so it survives JSON — this is what the settings app writes. A name that does not resolve warns and is skipped rather than breaking the rebuild |

Every desktop service that costs idle RAM or disk but is not essential sits behind a feature flag. They set the underlying NixOS options with `mkDefault`, so setting those directly still wins.

| features.* | Default |  |
| --- | --- | --- |
| audioServer | off | PipeWire/WirePlumber. Off means apulse/pressureaudio — PulseAudio API over bare ALSA, no daemon, but also no bluetooth audio and no per-app volume |
| desktopPortal | off | xdg-desktop-portal + GTK backend. The native paths already cover file dialogs, notifications, OpenURI and dark mode; turn on for Flatpak or screen casting |
| processScheduling | off | ananicy-cpp with the CachyOS rules |
| autoUpgrade | on | the daily upgrade timer (system-upgrade works either way) |
| bluetooth | on | bluetoothd + blueman-manager |
| clipboardHistory | on | Super+V history and Super+. unicode picker |
| networkDiscovery | off | Avahi mDNS — .local names, printer/scanner discovery. Off because it is resident and periodic and speculative; turn it on to print or scan over the network |
| printing | on | CUPS + system-config-printer |
| scanning | on | SANE + sane-airscan |
| settingsApp | on | the System Settings GUI and its root helper. Costs ~150 MB of disk (a Python interpreter) and nothing resident |
| thermalManagement | on | thermald. Intel only — it exits on AMD, leaving a failed unit |
| thumbnails | on | Tumbler |
| virtualFilesystems | on | GVFS — trash, MTP/PTP, network shares |

Each option carries its full reasoning in [modules/options.nix](modules/options.nix), which is also what the installer renders. Read it there rather than here.

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

The module pulls in disko and declares the whole partition table from `diskDevice` / `diskType` / `swapSizeGiB`, so it expects to own the disk. It also sets `networking.hostName`, the primary user, the bootloader and the root filesystem — it is a whole-machine configuration, not a desktop layer to drop onto an existing one.

## Keyboard

|  |  |
| --- | --- |
| Super+Space, F12, Alt+F2 | application launcher (fuzzel) |
| Super+Return | terminal |
| Super+L | lock screen |
| Super+V | clipboard history |
| Super+. | unicode / emoji picker |
| Print / Shift+Print | screenshot, full or region — saved to ~/Pictures and copied |
| volume / mic / brightness keys | adjust, with an on-screen bar |

labwc's own defaults are loaded too, so `Alt+Tab`, `Alt+F4` and friends work as expected. The desktop background has no menu on it — all three of labwc's default root-menu buttons are unbound, and the panel's launcher menu is the one menu, applications and lock/power together.

## Repository layout

`nixosModules.nanoDesktop` is one module, assembled from `modules/`:

|  |  |
| --- | --- |
| modules/options.nix | every nanoDesktop.* option — and the installer's menu |
| modules/boot.nix | kernel, command line, sysctls, bootloader, /tmp |
| modules/storage.nix | disk profiles, the disko table, zram, block-layer tuning |
| modules/hardware.nix | graphics + VA-API, bluetooth, scanners, power management |
| modules/networking.nix | iwd + networkd, Avahi, firewall |
| modules/audio.nix | PipeWire, or apulse/pressureaudio when it is off |
| modules/nix.nix | nix settings, the resource guards, the upgrade timer |
| modules/system.nix | console, locale, users, polkit, documentation |
| modules/desktop.nix | /etc/xdg config, session environment, fonts, theme |
| modules/session.nix | the tty1 labwc service, the gtklock login gate, the systemd user session |
| modules/applications.nix | what is installed, and which application opens what |
| modules/services.nix | the remaining daemons, each behind a feature flag |
| pkgs/ | the derivations more than one module needs |
| pkgs/nano-settings/ | the settings app: `default.nix` (GUI), `helper.nix` (the root half), `schema.nix` (options.nix, machine-readable), `palette.nix` (accent.nix, likewise), `shell.nix` (dev shell), `tests.nix` (mypy + pytest), `src/` |

The desktop's own configuration is static project files rather than generated Nix strings — [config/labwc/](config/labwc/), [config/sfwbar/](config/sfwbar/), [config/foot/](config/foot/), [config/fuzzel/](config/fuzzel/), [config/mako/](config/mako/), [config/gtk-3.0/](config/gtk-3.0/) and [config/gtk-4.0/](config/gtk-4.0/). They are installed into `/etc/xdg` and loaded explicitly, and they reference executables through `/run/current-system/sw/bin/` so menu and panel entries keep resolving across package updates and garbage collection. **Edit those files to change the desktop** — `nixos-rebuild switch` installs the new copies, and `labwc --reconfigure` re-reads labwc's own config without restarting the session.

[config/unicode/build-index.py](config/unicode/build-index.py) builds the emoji/character index the picker searches, from the Unicode data already packaged in nixpkgs.

The Nix here is `nixfmt`\-clean:

```sh
nix develop                                   # mcp-nixos
nix run nixpkgs#nixfmt-rfc-style -- flake.nix modules/*.nix pkgs/*.nix
```

## Things worth knowing before you install this

Not defaults so much as positions, all of them reversible:

-   **The firewall is off** (`networking.firewall.enable = mkDefault false`). Reasonable for a single-user laptop with no listening services; set it true if that is not your machine.
-   **`initialPassword` defaults to `password`.** Change it at install, or immediately after.
-   **No input method.** Latin keyboard layouts are fine (set `environment.sessionVariables.XKB_DEFAULT_LAYOUT`), but CJK and other composed scripts need fcitx5 or ibus added through `extraPackages` plus a user service to run it.
-   **Nothing autostarts, and now that is stated rather than accidental.** `xdg.autostart.enable` is off. It used to be on, which had systemd-xdg-autostart-generator writing units for the blueman applet, the iwgtk indicator and the print applet — ~150 MB of tray applets held back only by the fact that nothing starts `xdg-desktop-autostart.target`. Session services belong in `systemd.user.services`, next to sfwbar and mako.
-   **logrotate is off.** Its generated config rotated `/var/log/{btmp,wtmp}` and nothing else, both `monthly` with `minsize 1M`, on an hourly timer. journald bounds itself.
-   **The lock screen is the login screen**, and it is the only thing between a cold boot and the desktop. That is a real gate — gtklock holds the session through `ext-session-lock-v1`, so the compositor keeps it locked even if gtklock dies — but it is one gate, on a machine whose disk is not encrypted by this module and whose tty2…6 accept the same password. Single-user laptop security, not a threat model.
-   **iwd is 802.11 only** — no VPN plugins, no ModemManager/WWAN, no captive-portal detection, no connection sharing. VPNs become declarative (`networking.wireguard` and friends). A card whose driver only ever behaved under wpa\_supplicant wants `networking.networkmanager.enable = true` alongside `useNetworkd = false` and `wireless.iwd.enable = false`.
-   **No man pages or NixOS docs** on the installed system, to save the disk.
-   **Wayland only.** `GDK_BACKEND=wayland` is set deliberately, so an X-only GTK app fails loudly instead of quietly starting XWayland.
-   **`nix-daemon` is throttled** — `MemoryHigh` at 40%, `CPUWeight` and `IOWeight` 50, `max-jobs` 1, build scratch on `/var/tmp` rather than the tmpfs `/tmp`, and systemd-oomd allowed to kill it (and only it) at sustained memory pressure. The session is protected from the other side with `MemoryLow`, so reclaim takes the compositor's pages last rather than first. A large build goes slower; the desktop stays usable. The measurement that motivated all of it is written up under "Resource guards" in [modules/nix.nix](modules/nix.nix).
-   **Store deduplication runs on a timer, not inline.** `auto-optimise-store` is off and `nix.optimise` weekly is on, so the hashing happens when nobody is waiting on it. NixOS's `ConditionACPower` is dropped from that unit — on a laptop it would mean the pass silently never runs.
-   **Every non-NVMe disk gets BFQ**, not just the spinning ones. SATA SSDs and eMMC used to fall through to `mq-deadline`; the middle of the range was the part that was uncovered. It costs some peak throughput and is what makes `IOWeight` and `IOSchedulingClass` mean anything at all.
-   **CPU microcode is loaded** (`hardware.cpu.*.updateMicrocode`). NixOS only wires that up from `nixos-generate-config`, which this module replaces, so it had to be stated — machines were running whatever their BIOS shipped. It costs ~15 MB per generation on the ESP, which is the reason not to raise `configurationLimit` on a small one.
-   **`allowUnfree` and `allowBroken` are on.**

Most non-obvious choice in this repo carries its reasoning, and often the measurement, in a comment next to it. If something here looks wrong, the argument for it is probably in the file.
