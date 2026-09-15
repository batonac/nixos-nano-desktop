# nano-settings: the GUI for nanoDesktop.*. See ./src/nano_settings for the
# application itself, ./helper.nix for the root half, and ./schema.nix and
# ./palette.nix for where its knowledge of the options and of the accent
# colours comes from.
#
# Python and PyGObject rather than a compiled toolkit binding: the whole
# interface is stock libadwaita rows, so there is nothing here that would go
# faster in C, and a settings app that can be read and edited in place on the
# machine it configures is worth more on this target than the alternative.
# It costs almost no disk — the interpreter is on every machine already, for
# nixos-rebuild-ng behind system-upgrade, and PyGObject is 1.2 MB — and nothing
# resident. What Python does cost is start-up, and the two things done about
# it are below: bytecode compiled into the store, because it cannot be written
# there later, and (in window.py) pages built on first visit.
{
  lib,
  pkgs,
  # What the guided ISO bakes in place of the module's defaults; see
  # ../template-settings.nix. Passed through to schema.nix so the app can say
  # which choices are not on the install media. Defaulted, because this file
  # is imported from flake.nix AND from modules/applications.nix, and the copy
  # a machine installs is the second one.
  templateSettings ? import ../template-settings.nix,
}:
let
  schema = import ./schema.nix { inherit lib pkgs templateSettings; };
  palette = import ./palette.nix { inherit lib pkgs; };

  python = pkgs.python3.withPackages (ps: [ ps.pygobject3 ]);

  # This desktop runs no polkit authentication agent, so the app brings one
  # and runs it as a child for as long as its window is open. polkit-gnome
  # is GTK3, which is already here (pcmanfm, galculator, iwgtk), and adds
  # about 380 KB. See src/nano_settings/privileged.py.
  polkitAgent = "${pkgs.polkit_gnome}/libexec/polkit-gnome-authentication-agent-1";

  # The application ID, and — deliberately — the .desktop file's basename
  # too. A Wayland taskbar has nothing to identify a window by but its
  # toplevel app_id, and Sfwbar's lookup (app_info_lookup_id, src/appinfo.c)
  # tries that as an icon name and then as "<app_id>.desktop"; GTK4 takes
  # the app_id from GApplication's application-id, which is paths.APP_ID.
  # Named anything else, the entry is simply not where the taskbar looks:
  # the application menu shows the right icon, because it reads the file
  # itself and never has to guess the name, and the taskbar button next to
  # it comes up blank. This is also the freedesktop convention, and what
  # every other reverse-DNS entry in the menu here already does.
  appId = "nu.avu.NanoSettings";

  desktopItem = pkgs.makeDesktopItem {
    name = appId;
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
    # The package is fully annotated; this is what lets anything type-checked
    # against the installed copy see that rather than assuming Any.
    install -Dm644 nano_settings/py.typed $out/share/nano-settings/nano_settings/py.typed
    install -Dm644 catalog.json $out/share/nano-settings/catalog.json
    install -Dm644 ${schema} $out/share/nano-settings/schema.json
    install -Dm644 ${palette} $out/share/nano-settings/palette.json

    substituteInPlace $out/share/nano-settings/nano_settings/paths.py \
      --replace-fail '@polkitAgent@' '${polkitAgent}'

    # Bytecode, compiled now because it cannot be compiled later: the store
    # is read-only, so a __pycache__ that is not written here is never
    # written, and every launch parses and compiles all fourteen modules and
    # throws the result away — measured at about a fifth of the time the
    # application's own imports take. unchecked-hash rather than the
    # timestamp default: the daemon resets every mtime to 1 when it registers
    # this path, which would make a timestamp .pyc stale before its first
    # use, and the source cannot change underneath a store path anyway.
    # Which is also why this comes AFTER the substitution above: unchecked
    # means the .pyc is believed, so it has to be compiled from the source
    # as it will be shipped, agent path and all.
    ${python.interpreter} -m compileall -q --invalidation-mode unchecked-hash \
      $out/share/nano-settings/nano_settings
    # Guarded like the app-id below: a compileall that quietly compiled
    # nothing would cost exactly what it costs today, which nobody would see;
    # and one that ran before the substitution would ship an agent path of
    # "@polkitAgent@" in the bytecode that is believed over the source.
    test -f $out/share/nano-settings/nano_settings/__pycache__/window.cpython-*.pyc
    grep -q 'polkit-gnome-authentication-agent-1' \
      $out/share/nano-settings/nano_settings/__pycache__/paths.cpython-*.pyc

    install -Dm644 ${polkitAction} \
      $out/share/polkit-1/actions/nu.avu.nanosettings.policy

    install -Dm644 -t $out/share/applications \
      ${desktopItem}/share/applications/*.desktop

    # The basename above is only the app_id while paths.py still agrees,
    # and nothing else connects the two. Drift is silent — the app runs,
    # the menu entry is right, and only the taskbar icon goes missing —
    # so it is caught here instead.
    grep -q 'APP_ID: Final = "${appId}"' \
      $out/share/nano-settings/nano_settings/paths.py

    mkdir -p $out/bin
    cat > $out/bin/nano-settings <<EOF
    #!${pkgs.runtimeShell}
    exec ${python.interpreter} -m nano_settings "\$@"
    EOF
    chmod +x $out/bin/nano-settings

    runHook postInstall
  '';

  # The app shells out to nix (to check a package name before adding it, and
  # to ask whether the binary cache can be reached before a download) and to
  # pkexec and passwd. Only nix needs help being found; the other two are
  # setuid or PAM-adjacent and must come from the system, not the store.
  preFixup = ''
    gappsWrapperArgs+=(
      --prefix PYTHONPATH : "$out/share/nano-settings"
      --prefix PATH : "${lib.makeBinPath [ pkgs.nix ]}"
    )
  '';

  passthru = {
    inherit schema palette desktopItem;
    helper = import ./helper.nix { inherit lib pkgs; };
    # `nix build .#nano-settings-tests`. Not a check phase here on purpose —
    # see the head of ./tests.nix for why an X server does not belong in the
    # build closure of every machine this desktop installs.
    tests = import ./tests.nix { inherit lib pkgs; };
  };

  meta = {
    description = "Settings application for NixOS Nano Desktop";
    mainProgram = "nano-settings";
    platforms = lib.platforms.linux;
  };
}
