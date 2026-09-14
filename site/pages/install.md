---
title: "Install NixOS Nano Desktop"
$head:
  - tagName: meta
    attributes:
      name: description
      content: "Write the ISO to a USB stick, boot it, answer three questions. Then what to expect after the first boot, the keyboard shortcuts, and the other ways to install if you already have Nix."
$elements:
  - $ref: ../components/nd-cta.json
  - $ref: ../components/nd-step.json
  - $ref: ../components/nd-kbd.json
  - $ref: ../components/nd-callout.json
---

::::::article{style.maxWidth="760px" style.margin="0 auto" style.padding="clamp(3rem, 7vw, 5rem) clamp(1rem, 3vw, 2rem)"}

:::h1{style.fontSize="clamp(2rem, 5vw, 3rem)" style.fontWeight="700" style.letterSpacing="-0.03em" style.lineHeight="1.1" style.margin="0 0 1rem"}
Install
:::

:::p{style.fontSize="1.125rem" style.color="var(--muted)" style.margin="0 0 2.5rem"}
The ISO installs the whole desktop with no network. It asks three questions — which disk, what to call the machine, and your username — and confirms before it writes anything.
:::

:::::section{style.margin="0 0 3rem"}
:::h2{style.fontSize="1.5rem" style.fontWeight="700" style.letterSpacing="-0.02em" style.margin="0 0 0.5rem"}
From the ISO
:::

::::nd-step{props.number="1" props.title="Download and verify"}
Get the ISO and its checksum from the [download page](/download/). The checksum is worth the ten seconds — an image that was cut short by a flaky connection installs a system that is short too.

```sh
sha256sum -c SHA256SUMS
```
::::

::::nd-step{props.number="2" props.title="Write it to a USB stick"}
The image is hybrid: a plain byte-for-byte copy boots on both BIOS and UEFI machines. On Linux or macOS, find the stick's device name (`lsblk` or `diskutil list`) and — checking twice, because this overwrites the whole device — write it:

```sh
sudo dd if=nano-desktop-guided.iso of=/dev/sdX bs=4M status=progress oflag=sync
```

On Windows, or if you would rather click, [balenaEtcher](https://etcher.balena.io/) and [Ventoy](https://www.ventoy.net/) both handle it.
::::

::::nd-step{props.number="3" props.title="Boot it"}
Plug the stick in, boot the laptop, and pick the stick from the firmware's boot menu — usually F12, F2, Esc or Del during the first second of power-on, the key varies by maker. It starts the installer on the first console.
::::

::::nd-step{props.number="4" props.title="Answer three questions"}
The installer lists the disks it can see and asks which one to install to. **Everything on that disk is erased.** Then a hostname, then a username; Enter accepts the defaults. It shows a summary and asks once more before it touches anything.

The install itself is a copy from the stick — a few minutes on an SSD, longer on a spinning disk — and then it reboots.
::::

::::nd-step{props.number="5" props.title="Log in"}
What you meet is the lock screen, with the desktop already loading behind it. The password is `password`. Change it in System Settings, which is in the panel's menu under Settings — it changes the account password and nothing else needs to know.
::::

:::nd-callout{props.title="No LibreOffice on the stick, on purpose"}
The ISO ships without LibreOffice so that it fits GitHub's 2 GiB limit for a downloadable file, and it records that choice in the machine's settings so the offline install is complete. Turning it on is one change in System Settings — *Office suite*, on the Applications page — and the row says what it costs: about half a gigabyte, so it needs an internet connection. Apply refuses to start that download offline rather than failing twenty minutes in. Every other way of installing keeps LibreOffice from the start.
:::
:::::

:::::section{style.margin="0 0 3rem"}
:::h2{style.fontSize="1.5rem" style.fontWeight="700" style.letterSpacing="-0.02em" style.margin="0 0 0.75rem"}
After installing
:::

**System Settings** is the way the machine is meant to be reconfigured. It edits every option of the desktop, adds software from a curated list or by nixpkgs name, and runs the rebuild — showing you the diff first, and rolling back on its own if the rebuild fails. A terminal is never required.

**Upgrades are automatic.** Once a day the machine fetches the current desktop and the current packages and rebuilds; the panel blinks and comes back on the new version, and whatever you have open is left alone. The `system-upgrade` command does the same on demand, and the timer is a switch in System Settings if you would rather not.

**`/etc/nixos` is yours.** It holds a small flake that tracks this project, a `nanoDesktop-settings.json` that System Settings writes, and — if you create it — a `local.nix` for anything that is a Nix value rather than a setting: an extra package, an overlay, a service. An upgrade never rewrites that file.

```sh
sudo nixos-rebuild switch --flake /etc/nixos   # rebuild by hand
system-upgrade                                 # fetch newer, then rebuild
```
:::::

:::::section{style.margin="0 0 3rem"}
:::h2{style.fontSize="1.5rem" style.fontWeight="700" style.letterSpacing="-0.02em" style.margin="0 0 0.75rem"}
Keyboard
:::

::nd-kbd{props.keys="Super+Space · F12 · Alt+F2" props.action="Application launcher"}
::nd-kbd{props.keys="Super+Return" props.action="Terminal"}
::nd-kbd{props.keys="Super+L" props.action="Lock the screen"}
::nd-kbd{props.keys="Super+V" props.action="Clipboard history"}
::nd-kbd{props.keys="Super+." props.action="Emoji and character picker"}
::nd-kbd{props.keys="Print · Shift+Print" props.action="Screenshot, full or region — saved to ~/Pictures and copied"}
::nd-kbd{props.keys="Super+Left · Super+Right" props.action="Snap the window to a half"}
::nd-kbd{props.keys="Alt+Tab · Alt+F4" props.action="Switch windows, close a window — labwc's defaults are loaded too"}
::nd-kbd{props.keys="Volume · mic · brightness keys" props.action="Adjust, with an on-screen bar"}

:::p{style.color="var(--muted)" style.margin="1rem 0 0" style.fontSize="0.9375rem"}
The desktop background has no menu on it. The panel's launcher menu is the one menu: applications, and lock and power, together.
:::
:::::

:::::section
:::h2{style.fontSize="1.5rem" style.fontWeight="700" style.letterSpacing="-0.02em" style.margin="0 0 0.75rem"}
If you already have Nix
:::

The ISO is one of three paths, and the wizard that produces all three is the flake itself:

```sh
nix run github:batonac/nixos-nano-desktop            # the wizard: settings, then a path
nix run github:batonac/nixos-nano-desktop#deploy -- root@<ip>   # nixos-anywhere to a machine you can reach
```

The wizard's questionnaire is generated from the desktop's own options, so it cannot ask for something the desktop does not accept. It can build you an **unattended ISO** with your settings baked in, which installs with no questions and no network; or a **network install** to a machine already booted into something with SSH, which is the only path that needs a connection. Both keep LibreOffice. The [README](https://github.com/batonac/nixos-nano-desktop#readme) covers them, along with using the module directly from your own configuration.

:::div{style.display="flex" style.gap="0.75rem" style.flexWrap="wrap" style.marginTop="2rem"}
::nd-cta{props.href="/download/" props.label="Download the ISO" props.variant="primary"}
::nd-cta{props.href="https://github.com/batonac/nixos-nano-desktop#readme" props.label="README on GitHub" props.variant="secondary" props.newTab="true"}
:::
:::::

::::::
