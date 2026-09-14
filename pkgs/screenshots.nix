# Boot the desktop in a VM and photograph it. The output is a directory of
# PNGs — lock, desktop, launcher, firefox, terminal-files, settings, office —
# for the project website, whose deploy workflow (.github/workflows/site.yml)
# copies $out/*.png into site/public/screenshots/ before building the site.
#
# A VM test rather than pictures somebody took on a laptop, for the reason
# the offline-install checks are one: the pictures are then of the module as
# committed, regenerated whenever the site is, and cannot drift from the
# desktop they advertise. The NixOS test driver already knows how to boot a
# configuration under qemu, type at it, and write the framebuffer to $out
# (machine.screenshot); everything here is arranging the session so that what
# it photographs is the desktop a user would see, in the order they would see
# it: the lock screen, then the desktop, then the applications.
#
#   nix build .#screenshots -L && ls result/
#
# Needs KVM and a builder advertising the nixos-test feature — the same as the
# offline-install checks; iso.yml and site.yml show the CI setup. For
# stepping through by hand, `nix build .#screenshots.driverInteractive` gives a
# visible qemu window and a Python prompt with the same `machine`.
#
# A package rather than a check. It is consumed as a build output, and, like
# the offline-install checks, it is a VM boot that a blanket `nix flake check`
# should not have to pay for.
{
  lib,
  pkgs,
  # self.nixosModules.nanoDesktop — the desktop under test, unchanged.
  nanoDesktop,
}:
pkgs.testers.runNixOSTest {
  name = "nano-desktop-screenshots";

  # runNixOSTest hands every node a read-only pkgs (node.pkgs, with the
  # nixpkgs.* options locked by nixos/modules/misc/nixpkgs/read-only.nix).
  # This desktop sets nixpkgs.overlays in four of its modules and
  # nixpkgs.config in a fifth, and under that lock the first of them is an
  # evaluation error ("nixpkgs.overlays is set to read-only"). Off, the node
  # builds its pkgs the way an installed machine does — same overlays, same
  # config, and so the same store paths the binary cache already holds.
  node.pkgsReadOnly = false;

  # No OCR. The driver offers wait_for_text, and it would be the honest way
  # to know a window has painted — but each attempt upscales the frame to
  # 300 dpi and runs tesseract over three variants of it, and on a 4-core
  # builder that is minutes per attempt, longer than any timeout worth
  # setting. So the script waits for processes and then for a fixed settle,
  # sized generously for a cold start over a shared store with software
  # rendering. The cost is a picture that could, in principle, be taken a
  # frame early; the check is a person looking at the site.

  nodes.machine =
    { ... }:
    {
      imports = [ nanoDesktop ];

      # ── Disk ────────────────────────────────────────────────────
      # qemu-vm.nix supplies the root (a throwaway image) and the store
      # (shared from the host), and forces its own fileSystems and
      # swapDevices at mkVMOverride priority, so disko's table would lose
      # there regardless. What it does not touch is the rest of what disko
      # derives from that table, and one line of it is dangerous here: the
      # swap partition in storage.nix is declared resumeDevice = true, which
      # becomes boot.resumeDevice and then resume=/dev/disk/by-partlabel/…
      # on the kernel command line. Under the systemd initrd that is a
      # device that never appears — a long wait, and with the
      # boot.panic_on_fail the test framework adds, a panic. This is the
      # switch disko provides for a system booted from somewhere other than
      # the disks it describes (its own doc names installer images), and it
      # takes fileSystems, swapDevices and boot.* out together.
      disko.enableConfig = false;

      # ── Display ─────────────────────────────────────────────────
      # qemu's default -vga std is a bochs framebuffer wlroots cannot start
      # on (nixos/tests/sway.nix and cage.nix carry this same line).
      # virtio-gpu gives labwc a real KMS device, and xres/yres set its
      # EDID preferred mode, which is how the output comes up 1440x900
      # rather than the device's 1280x800 default.
      #
      # Not 1366x768, the panel on the hardware this desktop exists for,
      # and the first thing tried: every frame came out sheared. The
      # guest's DRM dumb buffer pads each row to a 64-byte stride (1366 px
      # × 4 bytes = 5464, padded to 5504), and qemu's 2D transfer copies
      # rows assuming the guest stride equals the width — so each row
      # lands ten pixels further along than the last. A width that is a
      # multiple of 16 has no padding and no shear; 1440x900 is one, is a
      # common 14" panel of the same era, and keeps the UI at a size where
      # the panel text is legible on the website without scaling.
      #
      # No GPU in the VM — virtio-gpu without virgl has no render node, and
      # wlroots falls back to its pixman renderer by itself. Named on the
      # unit so the fallback is a decision rather than a log line.
      #
      # The clock is pinned so the panel and the lock screen read the same
      # on every run; a screenshot that changes with the build date is a
      # diff in the website for nothing. qemu takes UTC; the module's
      # default timezone is America/New_York, so this is 9:41 on a Monday.
      virtualisation = {
        qemu.options = [
          "-vga none"
          "-device virtio-gpu-pci,xres=1440,yres=900"
          "-rtc base=2026-01-05T14:41:00"
        ];
        # test-instrumentation.nix sets vm.panic_on_oom = 2: an OOM here is a
        # panic, not a slow test. Firefox and LibreOffice open one at a time,
        # and 4 GB is the machine this desktop is tuned for anyway.
        memorySize = 4096;
        cores = 4;
      };
      systemd.services.nano-desktop.environment.WLR_RENDERER = "pixman";

      # ── Firefox ─────────────────────────────────────────────────
      # A fresh profile opens the onboarding tour and a privacy notice, and
      # the VM has no route out (the test framework removes the default
      # gateway), so the browser would be photographed failing to load
      # Mozilla's pages. Policies, because that is the mechanism
      # programs.firefox already uses — these merge beside the module's
      # Preferences policy — and a bundled page as the home page so that a
      # plain `firefox` from the launcher lands on something too.
      programs.firefox.policies = {
        OverrideFirstRunPage = "";
        OverridePostUpdatePage = "";
        DontCheckDefaultBrowser = true;
        DisableTelemetry = true;
        DisableFirefoxStudies = true;
        NoDefaultBookmarks = true;
        Homepage = {
          URL = "file:///etc/nano-desktop/screenshot.html";
          StartPage = "homepage";
        };
      };
      programs.firefox.preferences."browser.aboutwelcome.enabled" = false;

      # The page Firefox is photographed on. Same background as the desktop
      # (nanoDesktop.backgroundColor's default) so the window reads as part
      # of it, and the UI font, which the closure already ships.
      environment.etc."nano-desktop/screenshot.html".text = ''
        <!doctype html>
        <meta charset="utf-8">
        <title>Nano Desktop</title>
        <style>
          body { margin: 0; min-height: 100vh; display: grid; place-items: center;
                 background: #1c1c1f; color: #ffffff;
                 font: 18px/1.5 "Adwaita Sans", sans-serif; }
          main { max-width: 34rem; padding: 2rem; }
          h1 { font-size: 3rem; margin: 0 0 .5rem; font-weight: 700; }
          p { margin: 0 0 1rem; color: #9a9a9a; }
          a { color: #3584e4; }
        </style>
        <main>
          <h1>Nano Desktop</h1>
          <p>A complete Wayland desktop for hardware everyone else has given up on.</p>
          <p>labwc, a panel, a lock screen, a settings app — and nothing running
             that you did not ask for.</p>
          <p><a href="#">batonac.github.io/nixos-nano-desktop</a></p>
        </main>
      '';
    };

  testScript =
    { nodes, ... }:
    let
      user = nodes.machine.nanoDesktop.username;
      password = nodes.machine.nanoDesktop.initialPassword;
    in
    ''
      import datetime

      USER = "${user}"
      PASSWORD = "${password}"


      def secs(n: int) -> datetime.timedelta:
          return datetime.timedelta(seconds=n)


      # systemctl --user from the driver's root shell. --machine=USER@ talks
      # to the user's own manager, which is where labwc pushed WAYLAND_DISPLAY
      # at startup; anything started there inherits it, plus the static
      # DefaultEnvironment from desktop.nix. GDK_BACKEND and MOZ_ENABLE_WAYLAND
      # live in sessionVariables — the launcher path gets them from labwc's
      # environment, this path does not — so they are handed over explicitly
      # and the apps come up the way they would from the panel.
      #
      # machine.wait_for_unit(unit, user=USER) is deliberately not used for
      # session units: it raises the moment it sees a unit that is inactive
      # with no job queued, which is what every one of these looks like in
      # the seconds before labwc starts nano-session.target.
      def user_active(unit: str) -> None:
          machine.wait_until_succeeds(
              f"systemctl --user --machine={USER}@ is-active {unit}",
              timeout=secs(120),
          )


      def user_run(unit: str, command: str) -> None:
          machine.succeed(
              f"systemd-run --user --machine={USER}@ --unit={unit} --collect"
              " --setenv=GDK_BACKEND=wayland --setenv=MOZ_ENABLE_WAYLAND=1"
              f" -- {command}"
          )


      def user_stop(unit: str) -> None:
          # execute, not succeed: --collect above means a unit that already
          # exited is gone, and stopping a unit that is gone is not a failure.
          machine.execute(f"systemctl --user --machine={USER}@ stop {unit}.service")
          machine.wait_until_fails(
              f"systemctl --user --machine={USER}@ is-active {unit}.service",
              timeout=secs(60),
          )
          # Let labwc repaint the empty desktop before the next window lands.
          machine.sleep(1)


      # A screenshot after a settle. Process presence proves a window was
      # asked for, not that its last frame — a fade-in, a late icon, a slow
      # first paint — has been drawn; the settle is what stands in for that.
      def shot(name: str, settle: int = 3) -> None:
          machine.sleep(settle)
          machine.screenshot(name)


      start_all()
      machine.wait_for_unit("multi-user.target")
      machine.wait_for_unit("nano-desktop.service", timeout=secs(120))

      # pgrep without -x throughout. nixpkgs wraps GTK programs, so the process
      # that runs is `.gtklock-wrapped` (and the kernel truncates that to
      # fifteen characters in the name pgrep matches against); an exact match
      # on `gtklock` never fires. The unanchored pattern matches either.
      with subtest("lock.png — the login gate"):
          user_active("nano-session.target")
          machine.wait_until_succeeds("pgrep gtklock", timeout=secs(120))
          # gtklock draws within a second of starting; well inside its 60 s
          # idle-hide, after which the password form fades and only the clock
          # is left.
          shot("lock", settle=4)
          # Typed in a loop, because "gtklock is running" is not "gtklock has
          # the keyboard". On a laptop the four seconds above were always
          # enough; on a CI runner the first attempt went to nothing — no
          # pam line in the journal, gtklock still up a minute later. A
          # wrong or lost attempt costs nothing (the field clears), so type
          # until it exits.
          for attempt in range(8):
              machine.send_chars(PASSWORD + "\n")
              try:
                  machine.wait_until_fails("pgrep gtklock", timeout=secs(10))
                  break
              except Exception:
                  machine.log(f"gtklock still up after attempt {attempt + 1}, typing again")
                  machine.sleep(3)
          else:
              raise Exception("gtklock never accepted the password")

      with subtest("desktop.png — the empty desktop and the panel"):
          user_active("sfwbar.service")
          # The panel is a GTK3 process that loads its config and a tray of
          # icons before its first frame.
          shot("desktop", settle=6)

      with subtest("launcher.png — fuzzel"):
          # labwc calls Super `W-`; qemu calls it meta_l.
          machine.send_key("meta_l-spc")
          machine.wait_until_succeeds("pgrep fuzzel", timeout=secs(30))
          # Give fuzzel its keyboard grab before typing into it. Two seconds,
          # because one was enough on a laptop and CI runners are not.
          machine.sleep(2)
          machine.send_chars("fire")
          shot("launcher", settle=2)
          machine.send_key("esc")
          machine.wait_until_fails("pgrep fuzzel", timeout=secs(30))

      with subtest("firefox.png"):
          # The page is given on the command line rather than trusted to the
          # Homepage policy: one less thing to be wrong about. Copied into
          # the home directory first, because Firefox shows the resolved
          # path in its address bar and /etc/nano-desktop is a symlink into
          # /nix/store — a forty-character hash is not the picture. Under
          # .cache, so it is not sitting in the file manager's view of the
          # home folder two pictures later.
          machine.succeed(
              f"install -D -o {USER} -m 0644 /etc/nano-desktop/screenshot.html"
              f" /home/{USER}/.cache/nano-desktop.html"
          )
          user_run(
              "shot-firefox",
              f"/run/current-system/sw/bin/firefox file:///home/{USER}/.cache/nano-desktop.html",
          )
          # Firefox's first start builds a profile before it opens a window.
          # Cold, over a shared store, with software WebRender, that is the
          # better part of a minute on a laptop-class builder.
          machine.wait_until_succeeds("pgrep -f firefox", timeout=secs(60))
          shot("firefox", settle=60)
          user_stop("shot-firefox")

      with subtest("terminal-files.png — pcmanfm and foot, tiled"):
          user_run("shot-files", "/run/current-system/sw/bin/pcmanfm")
          machine.wait_until_succeeds("pgrep pcmanfm", timeout=secs(60))
          machine.sleep(8)
          # labwc's built-in W-Right / W-Left are SnapToEdge; the new window
          # has focus, so this is the file manager on the right half …
          machine.send_key("meta_l-right")
          machine.sleep(1)
          # … and the terminal (rc.xml W-Return → foot) on the left.
          machine.send_key("meta_l-ret")
          machine.wait_until_succeeds("pgrep foot", timeout=secs(30))
          machine.sleep(3)
          machine.send_key("meta_l-left")
          # cd first: the terminal inherits labwc's working directory, which
          # is /, and a prompt at ~ is the one a person would see. free's
          # table is 87 columns and a half-width window is fewer; the cut
          # keeps the columns that fit rather than letting the last one wrap.
          machine.send_chars("cd; clear; uname -sr; free -m | cut -c1-70\n")
          shot("terminal-files", settle=3)
          machine.succeed("pkill -x foot")
          user_stop("shot-files")

      with subtest("settings.png — the project's own app"):
          user_run("shot-settings", "/run/current-system/sw/bin/nano-settings")
          # A Python interpreter, PyGObject and libadwaita, cold.
          machine.wait_until_succeeds("pgrep -f nano-settings", timeout=secs(60))
          shot("settings", settle=30)
          user_stop("shot-settings")

      with subtest("office.png — the LibreOffice start centre"):
          # Present here because this VM is built from the module's defaults,
          # which the site is honest about: the guided ISO ships without it,
          # and it is one online change in System Settings away.
          user_run("shot-office", "/run/current-system/sw/bin/soffice --norestore")
          # The slowest start on the machine, and its first run also writes
          # a profile. Sixty seconds is what an old laptop takes; a CI runner
          # is closer to that than to a workstation.
          machine.wait_until_succeeds("pgrep -f soffice", timeout=secs(60))
          shot("office", settle=90)
          user_stop("shot-office")

      machine.shutdown()
    '';
}
