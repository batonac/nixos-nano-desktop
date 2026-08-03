{
  description = "NixOS Nano Desktop";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nixos-install-helper = {
      url = "github:Avunu/nixos-install-helper";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.disko.follows = "disko";
    };
  };

  outputs =
    { self, nixpkgs, ... }@inputs:
    let
      system = "x86_64-linux";

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
      devShells.x86_64-linux.default =
        let
          pkgs = nixpkgs.legacyPackages.x86_64-linux;
        in
        pkgs.mkShell {
          packages = [
            pkgs.mcp-nixos
          ];
        };

      # The desktop itself. One module, assembled from ./modules — see
      # modules/default.nix for the map of which file holds what.
      nixosModules.nanoDesktop = import ./modules { inherit inputs; };

      # ── Installer (via nixos-install-helper) ─────────────────────────────────
      # install / installTemplate systems, the unattended + guided ISOs, and the
      # configure / install / deploy apps — all derived from nanoDesktop.*.
      nixosConfigurations = ih.nixosConfigurations;
      packages = ih.packages;
      apps = ih.apps;

      # Offline-install VM tests. Each boots the real ISO with no network at all
      # and installs to a blank disk, which is the only way to find out whether
      # the baked closure covers the system disko-install derives ON THE BOX —
      # where the firmware mode and the chosen disk are inputs the image was
      # built without. Expensive (a 3 GB ISO and a full install per check), so
      # run them by name rather than through a blanket `nix flake check`:
      #   nix build .#checks.x86_64-linux.offline-install-guided -L
      checks = ih.checks;
    };
}
