---
title: "NixOS Nano Desktop — a complete Wayland desktop for hardware everyone else has given up on"
$head:
  - tagName: meta
    attributes:
      name: description
      content: "A complete Wayland desktop for old, low-memory laptops, as a single NixOS module plus an offline installer. Browser, office, printing, scanning, bluetooth — tuned for 4 GB and a small disk."
  - tagName: meta
    attributes:
      property: "og:title"
      content: "NixOS Nano Desktop"
  - tagName: meta
    attributes:
      property: "og:description"
      content: "A complete Wayland desktop for hardware everyone else has given up on."
$elements:
  - $ref: ../components/nd-cta.json
  - $ref: ../components/nd-shot.json
  - $ref: ../components/nd-feature.json
---

:::::section{style.padding="clamp(4rem, 10vw, 7rem) clamp(1rem, 3vw, 2rem) clamp(2.5rem, 6vw, 4rem)" style.textAlign="center"}
::::div{style.maxWidth="820px" style.margin="0 auto"}
:::h1{style.fontSize="clamp(2.25rem, 6vw, 4rem)" style.fontWeight="700" style.letterSpacing="-0.03em" style.lineHeight="1.08" style.margin="0 0 1.25rem"}
A complete desktop for the laptop everyone else has given up on.
:::

:::p{style.fontSize="clamp(1.0625rem, 2vw, 1.25rem)" style.color="var(--muted)" style.lineHeight="1.65" style.margin="0 auto 2rem" style.maxWidth="640px"}
NixOS Nano Desktop is a full Wayland desktop — browser, office suite, printing, scanning, bluetooth, media playback, hardware video decoding — built for a 2012 laptop with two cores, 4 GB of RAM and a small disk. It runs fine on current hardware too. It is simply built as though it will not get any.
:::

:::div{style.display="flex" style.gap="0.75rem" style.justifyContent="center" style.flexWrap="wrap"}
::nd-cta{props.href="/download/" props.label="Download the ISO" props.variant="primary"}
::nd-cta{props.href="/install/" props.label="How to install" props.variant="secondary"}
:::
::::
:::::

:::::section{style.padding="0 clamp(1rem, 3vw, 2rem) clamp(3rem, 6vw, 5rem)"}
::::div{style.maxWidth="var(--max-width)" style.margin="0 auto" style.display="grid" style.gridTemplateColumns="repeat(auto-fit, minmax(min(420px, 100%), 1fr))" style.gap="1rem"}
::nd-shot{props.src="/screenshots/desktop.png" props.alt="The empty desktop: a near-black background and a single panel along the bottom with a start button, a clock and a tray." props.caption="The desktop as it boots: labwc, one panel, nothing else running."}
::nd-shot{props.src="/screenshots/launcher.png" props.alt="The application launcher open over the desktop, with Firefox matched from a partial search." props.caption="Super+Space: fuzzel, the launcher. Type, Enter."}
::nd-shot{props.src="/screenshots/terminal-files.png" props.alt="A terminal snapped to the left half of the screen and the file manager to the right." props.caption="foot and PCManFM, snapped to halves with Super+Left and Super+Right."}
::nd-shot{props.src="/screenshots/firefox.png" props.alt="Firefox open on a page, in the dark theme, on the Wayland desktop." props.caption="Firefox, on Wayland, with hardware video decoding where the chip has it."}
::nd-shot{props.src="/screenshots/settings.png" props.alt="The System Settings app: a sidebar of pages and rows of switches and pickers." props.caption="System Settings — every option of the desktop, no terminal required."}
::nd-shot{props.src="/screenshots/lock.png" props.alt="The lock screen: a large clock and a password field on a dark background." props.caption="The lock screen is the login screen. What you meet at boot is a password prompt with the session already loading behind it."}
::::
:::::

:::::section{style.padding="0 clamp(1rem, 3vw, 2rem) clamp(3rem, 6vw, 5rem)"}
::::div{style.maxWidth="var(--max-width)" style.margin="0 auto"}
:::h2{style.fontSize="clamp(1.5rem, 3vw, 2rem)" style.fontWeight="700" style.letterSpacing="-0.02em" style.margin="0 0 1.25rem"}
What you get
:::

:::div{style.display="grid" style.gridTemplateColumns="repeat(auto-fit, minmax(min(260px, 100%), 1fr))" style.gap="0.75rem"}
::nd-feature{props.title="Compositor and panel" props.text="labwc, straight to it on tty1 — no display manager. sfwbar along the bottom: app menu with lock and power, search, taskbar, wifi, bluetooth, volume, battery, clock, tray."}
::nd-feature{props.title="Applications" props.text="Firefox, GNOME Text Editor, PCManFM, Xarchiver, Celluloid, image-roll, Evince, and LibreOffice or AbiWord + Gnumeric — your call."}
::nd-feature{props.title="Terminal and launcher" props.text="foot and fuzzel. Super+Return and Super+Space. Clipboard history on Super+V, an emoji picker on Super+."}
::nd-feature{props.title="Printing, scanning, bluetooth" props.text="CUPS with system-config-printer, SANE with driverless scanning, bluetoothd with blueman. Each behind a feature flag if you would rather not."}
::nd-feature{props.title="Networking" props.text="iwd and systemd-networkd — 2.7 MB resident where NetworkManager is 17 — with iwgtk for the odd hidden network. VPNs are declarative."}
::nd-feature{props.title="A settings app" props.text="System Settings edits every option of the desktop, changes the password, adds software and runs the rebuild, with a diff before and a rollback if it fails."}
::nd-feature{props.title="Adwaita dark, everywhere" props.text="adw-gtk3-dark, MoreWaita icons, Adwaita Sans and Mono, one accent colour picked once. It looks like one thing because it is."}
::nd-feature{props.title="Built to be small" props.text="Kernel firmware trimmed to what laptops have, journald bounded, the nix daemon throttled so a rebuild never takes the desktop with it, no docs or man pages on the disk."}
:::
::::
:::::

:::::section{style.padding="0 clamp(1rem, 3vw, 2rem) clamp(4rem, 8vw, 6rem)"}
::::div{style.maxWidth="760px" style.margin="0 auto"}
:::h2{style.fontSize="clamp(1.5rem, 3vw, 2rem)" style.fontWeight="700" style.letterSpacing="-0.02em" style.margin="0 0 0.75rem"}
Positions, not defaults
:::

:::p{style.color="var(--muted)" style.margin="0 0 1rem"}
A few choices you should know about before you install. All of them are reversible, and every one carries its reasoning in a comment next to it in the source.
:::

- **The firewall is off.** Reasonable for a single-user laptop with no listening services; one line turns it on.
- **The lock screen is the login screen.** One gate, on a machine whose disk this module does not encrypt. Single-user laptop security, not a threat model.
- **Wayland only.** An X-only application fails loudly rather than quietly starting XWayland.
- **iwd is 802.11 only.** No VPN plugins, no WWAN, no captive-portal detection. A card that only ever behaved under wpa_supplicant wants NetworkManager back, and the README says how.
- **The default password is `password`.** Change it at install, or immediately after, in System Settings.

:::div{style.display="flex" style.gap="0.75rem" style.flexWrap="wrap" style.marginTop="2rem"}
::nd-cta{props.href="/download/" props.label="Download the ISO" props.variant="primary"}
::nd-cta{props.href="https://github.com/batonac/nixos-nano-desktop#readme" props.label="Read the README" props.variant="secondary" props.newTab="true"}
:::
::::
:::::
