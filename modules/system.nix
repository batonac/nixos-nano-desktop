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
  # ── Console ─────────────────────────────────────────────────
  console = {
    keyMap = mkDefault "us";
    packages = [ pkgs.terminus_font ];
  };

  # ── Documentation ───────────────────────────────────────────
  documentation = {
    enable = mkDefault false;
    doc.enable = mkDefault false;
    man.enable = mkDefault false;
    nixos.enable = mkDefault false;
  };

  # ── Environment ─────────────────────────────────────────────
  environment.shells = with pkgs; [ bash ];

  # ── Programs ────────────────────────────────────────────────
  programs.nix-ld = {
    enable = mkDefault true;
    package = pkgs.nix-ld;
    libraries = with pkgs; [
      glib
      libxkbcommon
      openssl
      zstd
    ];
  };

  # ── Security ────────────────────────────────────────────────
  security = {
    # The screen lock's PAM service is declared by programs.gtklock
    # (see session.nix), which is also what authenticates the boot-time
    # login gate.
    polkit = {
      enable = mkDefault true;
      enablePkexecWrapper = mkDefault true;
    };
    tpm2.enable = mkDefault false;
  };

  # ── System ──────────────────────────────────────────────────
  system = {
    stateVersion = cfg.stateVersion;
    autoUpgrade.enable = mkDefault false;
  };

  # ── Time & Locale ───────────────────────────────────────────
  time.timeZone = cfg.timeZone;
  i18n.defaultLocale = cfg.locale;

  # ── Users ───────────────────────────────────────────────────
  users = {
    defaultUserShell = pkgs.bash;
    users.${cfg.username} = {
      extraGroups = [
        "input"
        # No networkmanager group any more — iwd's D-Bus policy grants
        # the wheel group below, which is what lets the panel's wifi
        # widget scan, connect and answer passphrase prompts.
        "wheel"
        "audio"
        "video"
      ];
      initialPassword = cfg.initialPassword;
      isNormalUser = true;
      useDefaultShell = true;
    };
  };
}
