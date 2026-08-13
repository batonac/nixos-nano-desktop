# nano-settings: the GUI for nanoDesktop.*. See ./src/nano_settings for the
# application itself, ./helper.nix for the root half, and ./schema.nix for
# where its knowledge of the options comes from.
#
# Python and PyGObject rather than a compiled toolkit binding: the whole
# interface is stock libadwaita rows, so there is nothing here that would go
# faster in C, and a settings app that can be read and edited in place on the
# machine it configures is worth more on this target than a few MB of closure.
# Nothing is compiled at install time either way — nixpkgs caches all of it.
{ lib, pkgs }:
let
  schema = import ./schema.nix { inherit lib pkgs; };

  python = pkgs.python3.withPackages (ps: [ ps.pygobject3 ]);

  # This desktop runs no polkit authentication agent, so the app brings one
  # and runs it as a child for as long as its window is open. polkit-gnome
  # is GTK3, which is already here (pcmanfm, galculator, iwgtk), and adds
  # about 380 KB. See src/nano_settings/privileged.py.
  polkitAgent = "${pkgs.polkit_gnome}/libexec/polkit-gnome-authentication-agent-1";

  desktopItem = pkgs.makeDesktopItem {
    name = "nano-settings";
    exec = "nano-settings";
    icon = "preferences-system";
    desktopName = "System Settings";
    genericName = "Settings";
    comment = "Configure this computer, add software, and install updates";
    # Settings puts it under the menu's own settings section; System keeps
    # it findable in menus that do not have one. The panel's appmenu and
    # fuzzel both enumerate .desktop files, so there is no menu to edit.
    categories = [
      "Settings"
      "System"
      "GTK"
    ];
    keywords = [
      "settings"
      "preferences"
      "configuration"
      "update"
      "upgrade"
      "password"
      "software"
      "install"
      "nixos"
    ];
    startupNotify = true;
  };

  # pkexec matches this action by the path it was asked to run, so the
  # annotation names the system profile path rather than a store path: the
  # store path changes whenever anything in the helper's closure does, and
  # an action that stopped matching would silently fall back to the generic
  # "run a program as another user" prompt.
  #
  # auth_admin_keep, so applying settings and then immediately updating does
  # not ask twice.
  polkitAction = pkgs.writeText "nu.avu.nanosettings.policy" ''
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE policyconfig PUBLIC
     "-//freedesktop//DTD PolicyKit Policy Configuration 1.0//EN"
     "http://www.freedesktop.org/standards/PolicyKit/1/policyconfig.dtd">
    <policyconfig>
      <vendor>NixOS Nano Desktop</vendor>
      <action id="nu.avu.nanosettings.helper">
        <description>Change system settings</description>
        <message>Authentication is required to change system settings and rebuild this computer.</message>
        <defaults>
          <allow_any>auth_admin</allow_any>
          <allow_inactive>auth_admin</allow_inactive>
          <allow_active>auth_admin_keep</allow_active>
        </defaults>
        <annotate key="org.freedesktop.policykit.exec.path">/run/current-system/sw/bin/nano-settings-helper</annotate>
        <annotate key="org.freedesktop.policykit.exec.allow_gui">true</annotate>
      </action>
    </policyconfig>
  '';
in
pkgs.stdenv.mkDerivation {
  pname = "nano-settings";
  version = "1.0";

  src = ./src;

  nativeBuildInputs = with pkgs; [
    wrapGAppsHook4
    gobject-introspection
  ];

  # Present so wrapGAppsHook4 puts their typelibs on GI_TYPELIB_PATH.
  buildInputs = with pkgs; [
    gtk4
    libadwaita
    glib
  ];

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall

    install -Dm644 -t $out/share/nano-settings/nano_settings nano_settings/*.py
    install -Dm644 catalog.json $out/share/nano-settings/catalog.json
    install -Dm644 ${schema} $out/share/nano-settings/schema.json

    substituteInPlace $out/share/nano-settings/nano_settings/paths.py \
      --replace-fail '@polkitAgent@' '${polkitAgent}'

    install -Dm644 ${polkitAction} \
      $out/share/polkit-1/actions/nu.avu.nanosettings.policy

    install -Dm644 -t $out/share/applications \
      ${desktopItem}/share/applications/*.desktop

    mkdir -p $out/bin
    cat > $out/bin/nano-settings <<EOF
    #!${pkgs.runtimeShell}
    exec ${python.interpreter} -m nano_settings "\$@"
    EOF
    chmod +x $out/bin/nano-settings

    runHook postInstall
  '';

  # The app shells out to nix (to check a package name before adding it) and
  # to pkexec and passwd. Only nix needs help being found; the other two are
  # setuid or PAM-adjacent and must come from the system, not the store.
  preFixup = ''
    gappsWrapperArgs+=(
      --prefix PYTHONPATH : "$out/share/nano-settings"
      --prefix PATH : "${lib.makeBinPath [ pkgs.nix ]}"
    )
  '';

  passthru = {
    inherit schema desktopItem;
    helper = import ./helper.nix { inherit lib pkgs; };
  };

  meta = {
    description = "Settings application for NixOS Nano Desktop";
    mainProgram = "nano-settings";
    platforms = lib.platforms.linux;
  };
}
