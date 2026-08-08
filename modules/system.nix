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
  # No console.packages. It used to carry terminus_font, which never
  # loaded: console.font is null here, so NixOS writes no FONT= line
  # into /etc/vconsole.conf and systemd-vconsole-setup leaves the
  # kernel's built-in font alone. console.packages only extends the
  # search path setfont would have looked in — with nothing selecting a
  # font from it, the package was 2.2 MB of consolefonts installed on
  # every machine and read by nothing.
  #
  # The kernel font is the right answer here anyway. This desktop boots
  # to Wayland on tty1 and the VTs exist as a rescue path; a nicer font
  # on a screen someone sees when something has gone wrong is not worth
  # a package in the closure.
  console.keyMap = mkDefault "us";

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
