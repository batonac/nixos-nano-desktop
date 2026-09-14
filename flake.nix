{
  description = "NixOS Nano Desktop";

  # The project's binary cache, for the two consumers modules/nix.nix cannot
  # reach: `nix run .#deploy` (nixos-anywhere builds the target's toplevel on
  # the OPERATOR's machine, whose nix.conf decides where paths come from),
  # and anyone building this flake on a machine that is not already running
  # it — CI included. modules/nix.nix takes effect only once the system it
  # configures exists, which is after the build it would have accelerated.
  #
  # Nix honours this only for a trusted user who accepts it — a prompt the
  # first time, or `--accept-flake-config` — and everyone else gets a warning
  # and a local build, which is the pre-cache behaviour and is fine. That
  # friction is the correct amount for "this flake would like to add a party
  # who can sign store paths". Same key as modules/nix.nix; keep them equal.
  nixConfig = {
    extra-substituters = [ "https://nixos-nano-desktop.cachix.org" ];
    extra-trusted-public-keys = [
      "nixos-nano-desktop.cachix.org-1:ZvNNRuQDTmjMUUdgjexTmgLrdsMP69DRTyPUkPgnKeY="
    ];
  };

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nixos-install-helper = {
      # Pinned to the branch carrying `templateSettings` (Avunu/nixos-install-helper#4)
      # until it merges; then drop the branch from this ref and let Dependabot
      # move the lock. The guided ISO below does not evaluate without it.
      url = "github:Avunu/nixos-install-helper/template-settings";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.disko.follows = "disko";
    };
  };

  outputs =
    { self, nixpkgs, ... }@inputs:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      lib = nixpkgs.lib;

      # What the guided ISO leaves out, so the image fits a GitHub Release
      # (2 GiB per asset). The full desktop closure at squashfs compression
      # was measured at about 3 GB, and LibreOffice is roughly a third of
      # that. Defined once, here, because two things read it: the installer
      # bakes it into the guided template AND seeds it into the installed
      # machine's settings file, so the reconcile on first boot has nothing
      # to fetch and the install is complete offline; and the settings app
      # reads it to tell the owner that every other choice for the option
      # is a download and needs a network. Without a browser it would not be
      # a desktop, so Firefox stays. Installs that do not go through the
      # guided ISO — nix run, nixos-anywhere, the unattended ISO — are
      # untouched and keep the module's default.
      templateSettings.nanoDesktop.officeSuite = "none";

      nanoSettings = import ./pkgs/nano-settings { inherit lib pkgs templateSettings; };

      # Public-facing installer: derives its menu from nanoDesktop.* and ships
      # unattended / guided ISOs plus a nixos-anywhere deploy. The whole
      # installer surface is this one call.
      ih = inputs.nixos-install-helper.lib.mkProject {
        inherit nixpkgs system self;
        installModules = [ self.nixosModules.nanoDesktop ];
        optionRoots = [ "nanoDesktop" ];
        flakeStyle = "local";
        upstream = "github:batonac/nixos-nano-desktop";
        diskName = "main";
        # See templateSettings above: baked into the guided template and
        # seeded into the installed machine's settings file.
        inherit templateSettings;
        # The helper's default (zstd -6) trades ~18% image size for a ~23x
        # faster build, and its own comment says to raise it for an image
        # someone downloads. This is that image. ci.yml never builds it, so
        # the cost lands on the weekly iso.yml run alone.
        squashfsCompression = "zstd -Xcompression-level 19";
        # gum widget hints. configure.sh looks these up by the full dotted path
        # it builds while walking the derived schema — the walk starts at the
        # schema root, whose only property is the option root, so the key it
        # actually queries is "nanoDesktop.diskDevice". mk-project passes this
        # attrset through verbatim, so the bare "diskDevice" key never matched
        # and the lsblk picker silently degraded to a free-text box. Keyed both
        # ways so it keeps working if the helper is ever fixed to strip the root.
        hints = {
          diskDevice = "disk-device";
          "nanoDesktop.diskDevice" = "disk-device";
        };
        # What the guided ISO asks for on the target box, beyond the disk. That
        # ISO is generic — it bakes this module with no settings at all — so
        # everything else stays at the defaults in modules/options.nix, and only
        # what is genuinely per-machine is worth a prompt. Both are applied by
        # the first-boot reconcile, so neither moves the baked closure.
        guidedPrompts = [
          "hostName"
          "username"
        ];
      };
    in
    {
      devShells.${system} = {
        default = pkgs.mkShell {
          packages = [
            pkgs.mcp-nixos
          ];
        };

        # The settings app is the one part of this repository that is not
        # Nix, so it gets a shell of its own: an interpreter, the GTK stack,
        # and a venv managed from them. See pkgs/nano-settings/shell.nix.
        nano-settings = import ./pkgs/nano-settings/shell.nix { inherit lib pkgs; };
      };

      # The desktop itself. One module, assembled from ./modules — see
      # modules/default.nix for the map of which file holds what.
      nixosModules.nanoDesktop = import ./modules { inherit inputs; };

      # ── Installer (via nixos-install-helper) ─────────────────────────────────
      # install / installTemplate systems, the unattended + guided ISOs, and the
      # configure / install / deploy apps — all derived from nanoDesktop.*.
      nixosConfigurations = ih.nixosConfigurations;
      apps = ih.apps;

      # The installer's own outputs, plus the settings app and the four
      # things built alongside it, by name. nano-settings-tests is the type
      # check and the test suite; it is a package rather than a check phase
      # on the app so that an X server stays out of the build closure of
      # every installed machine. See pkgs/nano-settings/tests.nix.
      packages = ih.packages // {
        ${system} = ih.packages.${system} // {
          nano-settings = nanoSettings;
          nano-settings-helper = nanoSettings.passthru.helper;
          nano-settings-schema = nanoSettings.passthru.schema;
          nano-settings-palette = nanoSettings.passthru.palette;
          nano-settings-tests = nanoSettings.passthru.tests;
          # The website's screenshots: boots the desktop in a VM and
          # photographs it, $out/*.png. A package rather than a check because
          # it is consumed as a build output — site.yml copies the PNGs in —
          # and because, like the offline-install checks, it is a VM boot
          # that a blanket `nix flake check` should not pay for. Needs KVM.
          # See pkgs/screenshots.nix.
          screenshots = import ./pkgs/screenshots.nix {
            inherit lib pkgs;
            nanoDesktop = self.nixosModules.nanoDesktop;
          };
        };
      };

      # Offline-install VM tests. Each boots the real ISO with no network at all
      # and installs to a blank disk, which is the only way to find out whether
      # the baked closure covers the system disko-install derives ON THE BOX —
      # where the firmware mode and the chosen disk are inputs the image was
      # built without. Expensive (a 3 GB ISO and a full install per check), so
      # run them by name rather than through a blanket `nix flake check`:
      #   nix build .#checks.x86_64-linux.offline-install-guided -L
      #
      # The settings app's suite is in here too, and is the one that is cheap
      # enough to run whenever: seconds, and no VM.
      checks = ih.checks // {
        ${system} = ih.checks.${system} // {
          nano-settings = nanoSettings.passthru.tests;
        };
      };
    };
}
