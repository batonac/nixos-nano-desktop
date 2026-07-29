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
      lib = nixpkgs.lib;
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
      nixosModules.nanoDesktop =
        {
          config,
          lib,
          pkgs,
          ...
        }:
        with lib;
        let
          cfg = config.nanoDesktop;
          # GLib searches <dir>/glib-2.0/schemas/gschemas.compiled along
          # XDG_DATA_DIRS; nixpkgs relocates schemas to this per-package prefix
          # (wrapped apps get it injected by wrapGAppsHook, unwrapped ones need
          # it in the environment — see sessionVariables / DefaultEnvironment).
          gsettingsSchemaDir = "${pkgs.gsettings-desktop-schemas}/share/gsettings-schemas/${pkgs.gsettings-desktop-schemas.name}";

          # sfwbar volume control, spliced into ./sfwbar/sfwbar.config at the
          # @VOLUME_DEFS@ (top-level) and @VOLUME_WIDGET@ (in the bar) markers.
          # Both backends use sfwbar's own volume interface — native, themed,
          # icon + slider popup — keyed off features.audioServer:
          #  - server on  → the bundled volume.widget (loads pulsectl+alsactl);
          #    with PipeWire running it drives the pulse backend: per-sink,
          #    follows Bluetooth output, full multi-device popup.
          #  - server off → a slim alsactl-only button + popup. apulse/
          #    pressureaudio has no server, and the bundled widget also loads
          #    pulsectl (which would bind to apulse's stub libpulse), so here we
          #    load ONLY module("alsactl") and vendor a single-sink mini-mixer.
          #    It drives the hardware Master over ALSA and shares the "volume"
          #    trigger, so it stays in sync with nano-osd's amixer media keys.
          #    Left-click opens the slider popup, scroll adjusts, right mutes.
          #    Popup look: the #nanovol_* rules in ./sfwbar/sfwbar.css.
          sfwbarVolumeDefs =
            if cfg.features.audioServer then
              ""
            else
              ''
                module("alsactl")

                Var nanovol_thresholds = [67, 34, 0];
                Var nanovol_icons = ["audio-volume-high", "audio-volume-medium", "audio-volume-low"];

                PopUp "NanoVolumeWindow" {
                  style = "nanovol_popup"
                  image {
                    value = If(Volume("sink-mute"), "audio-volume-muted",
                      ArrayLookup(Volume("sink-volume"), nanovol_thresholds, nanovol_icons, "audio-volume-muted"))
                    style = "nanovol_mute"
                    tooltip = "Toggle mute"
                    action = VolumeCtl("sink-mute toggle")
                    trigger = "volume"
                    loc(1,1,1,1)
                  }
                  scale "nanovol_slider" {
                    style = "nanovol_scale"
                    value = Volume("sink-volume") / 100
                    action[1] = VolumeCtl("sink-volume " + Str(GtkEvent("dir") * 100))
                    trigger = "volume"
                    loc(2,1,1,1)
                  }
                  label {
                    value = Str(Volume("sink-volume"), 0) + "%"
                    style = "nanovol_pct"
                    trigger = "volume"
                    loc(3,1,1,1)
                  }
                }'';
          sfwbarVolumeWidget =
            if cfg.features.audioServer then
              ''
                widget "volume.widget" {
                    simple_icon = False
                    volume_thresholds = [80, 50, 0]
                    volume_icons = ["audio-volume-high", "audio-volume-medium", "audio-volume-low"]
                    volume_muted = "audio-volume-muted"
                  }''
            else
              # Inline button (like the start/launcher buttons) — NOT
              # `widget "name"`, which is sfwbar's file-include syntax. Uses the
              # alsactl module loaded in @VOLUME_DEFS@; left-click opens the
              # NanoVolumeWindow slider popup defined there.
              ''
                button {
                    style = "module"
                    value = If(Volume("sink-mute"), "audio-volume-muted",
                      ArrayLookup(Volume("sink-volume"), nanovol_thresholds, nanovol_icons, "audio-volume-muted"))
                    tooltip = "Volume " + Str(Volume("sink-volume"), 0) + "%" + If(Volume("sink-mute"), " (muted)", "")
                    trigger = "volume"
                    action[LeftClick] = PopUp("NanoVolumeWindow")
                    action[RightClick] = VolumeCtl("sink-mute toggle")
                    action[ScrollUp] = VolumeCtl("sink-volume +5")
                    action[ScrollDown] = VolumeCtl("sink-volume -5")
                  }'';
          sfwbarConfig =
            builtins.replaceStrings
              [ "@VOLUME_DEFS@" "@VOLUME_WIDGET@" ]
              [ sfwbarVolumeDefs sfwbarVolumeWidget ]
              (builtins.readFile ./sfwbar/sfwbar.config);

          # Wayland desktop config lives in static project files under ./labwc
          # and ./sfwbar, installed into /etc/xdg and loaded explicitly
          # (`labwc -C /etc/xdg/labwc`, `sfwbar -f /etc/xdg/sfwbar/sfwbar.config`).
          # They reference executables via /run/current-system/sw/bin/ rather
          # than /nix/store/ paths, so menu/panel entries keep resolving across
          # package updates / GC. Edit those files to change the desktop.

          # Screenshot helper: grim (+ slurp for a region) → save to Pictures
          # and copy to the clipboard. Bound to Print / Shift-Print in labwc
          # (labwc's Execute has no shell, so the grim+slurp pipe needs a script).
          nano-screenshot = pkgs.writeShellApplication {
            name = "nano-screenshot";
            runtimeInputs = with pkgs; [
              grim
              slurp
              wl-clipboard
              libnotify
              coreutils
            ];
            text = ''
              mode="''${1:-full}"
              dir="''${XDG_PICTURES_DIR:-$HOME/Pictures}"
              mkdir -p "$dir"
              file="$dir/screenshot-$(date +%Y%m%d-%H%M%S).png"
              if [ "$mode" = "region" ]; then
                grim -g "$(slurp)" "$file"
              else
                grim "$file"
              fi
              wl-copy < "$file"
              notify-send "Screenshot saved" "$file"
            '';
          };

          # Volume / brightness OSD without a resident daemon (replaces
          # swayosd-server, ~43 MB idle): adjust the level, then surface it
          # through mako, which renders the int:value hint as a progress bar
          # (progress-color in ./mako/config). The notification id is cached
          # under XDG_RUNTIME_DIR and re-used with -r, so repeated keypresses
          # update one on-screen card in place instead of stacking. Bound to
          # the XF86 audio/brightness keys in ./labwc/rc.xml.
          #
          # The audio half tracks features.audioServer: with the PipeWire
          # server it drives wpctl (per-sink volume, follows the default sink —
          # e.g. a Bluetooth speaker); in the server-free apulse/pressureaudio
          # mode it drives ALSA directly via amixer on the hardware Master /
          # Capture controls. Brightness (brightnessctl) is identical either way.
          nano-osd =
            let
              audioBackend =
                if cfg.features.audioServer then
                  {
                    inputs = [ pkgs.wireplumber ];
                    funcs = ''
                      sink_osd() {
                        # wpctl prints "Volume: 0.75" (+ " [MUTED]" when muted)
                        state=$(wpctl get-volume @DEFAULT_AUDIO_SINK@)
                        percent=$(awk '{printf "%.0f", $2 * 100}' <<<"$state")
                        if [[ "$state" == *MUTED* ]]; then
                          show audio-volume-muted "Volume muted" 0
                        elif (( percent <= 33 )); then
                          show audio-volume-low "Volume $percent%" "$percent"
                        elif (( percent <= 66 )); then
                          show audio-volume-medium "Volume $percent%" "$percent"
                        else
                          show audio-volume-high "Volume $percent%" "$percent"
                        fi
                      }
                    '';
                    arms = ''
                      volume-up)
                        wpctl set-volume -l 1.0 @DEFAULT_AUDIO_SINK@ 5%+
                        sink_osd
                        ;;
                      volume-down)
                        wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-
                        sink_osd
                        ;;
                      volume-mute)
                        wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle
                        sink_osd
                        ;;
                      mic-mute)
                        wpctl set-mute @DEFAULT_AUDIO_SOURCE@ toggle
                        if wpctl get-volume @DEFAULT_AUDIO_SOURCE@ | grep -q MUTED; then
                          show microphone-sensitivity-muted "Microphone muted" 0
                        else
                          show microphone-sensitivity-high "Microphone on" 100
                        fi
                        ;;
                    '';
                  }
                else
                  {
                    inputs = [ pkgs.alsa-utils ];
                    funcs = ''
                      sink_osd() {
                        # amixer -M sget prints "... [42%] [0.00dB] [on]" per channel
                        state=$(amixer -M sget Master 2>/dev/null || true)
                        percent=$(printf '%s\n' "$state" | grep -m1 -oE '[0-9]+%' | tr -d '%' || true)
                        percent=''${percent:-0}
                        if printf '%s\n' "$state" | grep -q '\[off\]'; then
                          show audio-volume-muted "Volume muted" 0
                        elif (( percent <= 33 )); then
                          show audio-volume-low "Volume $percent%" "$percent"
                        elif (( percent <= 66 )); then
                          show audio-volume-medium "Volume $percent%" "$percent"
                        else
                          show audio-volume-high "Volume $percent%" "$percent"
                        fi
                      }
                    '';
                    arms = ''
                      volume-up)
                        amixer -M -q sset Master 5%+ unmute
                        sink_osd
                        ;;
                      volume-down)
                        amixer -M -q sset Master 5%-
                        sink_osd
                        ;;
                      volume-mute)
                        amixer -q sset Master toggle
                        sink_osd
                        ;;
                      mic-mute)
                        amixer -q sset Capture toggle
                        if amixer sget Capture 2>/dev/null | grep -q '\[off\]'; then
                          show microphone-sensitivity-muted "Microphone muted" 0
                        else
                          show microphone-sensitivity-high "Microphone on" 100
                        fi
                        ;;
                    '';
                  };
            in
            pkgs.writeShellApplication {
              name = "nano-osd";
              runtimeInputs =
                (with pkgs; [
                  brightnessctl
                  coreutils
                  gawk
                  gnugrep
                  libnotify
                ])
                ++ audioBackend.inputs;
              text = ''
                mode="''${1:-}"
                idfile="''${XDG_RUNTIME_DIR:-/tmp}/nano-osd.id"

                show() { # show <icon> <summary> <percent>
                  last=$(cat "$idfile" 2>/dev/null || echo 0)
                  notify-send -p -e -t 1500 -i "$1" -h "int:value:$3" \
                    -r "$last" "$2" > "$idfile"
                }

                ${audioBackend.funcs}
                case "$mode" in
                  ${audioBackend.arms}
                  brightness-up | brightness-down)
                    if [ "$mode" = "brightness-up" ]; then
                      brightnessctl -q set 5%+
                    else
                      brightnessctl -q set 5%-
                    fi
                    # -m prints CSV: device,class,current,percent%,max
                    percent=$(brightnessctl -m | cut -d, -f4)
                    percent=''${percent%\%}
                    show display-brightness "Brightness $percent%" "$percent"
                    ;;
                  *)
                    echo "usage: nano-osd volume-up|volume-down|volume-mute|mic-mute|brightness-up|brightness-down" >&2
                    exit 2
                    ;;
                esac
              '';
            };

          # ── Clipboard history + unicode picker (features.clipboardHistory) ──
          # Both are keybind-invoked scripts rather than a resident daemon. The
          # only always-on piece is the wl-paste watcher user service below
          # (~1-2 MB), which replaced fcitx5 (~20 MB PSS, and an input-method
          # layer in the path of every keystroke on the machine for a desktop
          # that has exactly one Latin keyboard layout).
          #
          # Both pickers reuse fuzzel — already in the stack as the launcher, so
          # the look is shared for free — and both replay the pick into the
          # focused surface through wtype, which is what keeps the old
          # paste-on-select feel now that no input method can commit at the
          # caret. labwc advertises zwp_virtual_keyboard_manager_v1 (wtype) and
          # both ext-/wlr-data-control (the watcher), so nothing here needs a
          # compositor feature the session does not already have.

          # Searchable Unicode index: "<char>\t<NAME>" per line, built from the
          # Unicode data already packaged in nixpkgs. See ./unicode/
          # build-index.py for the source-by-source reasoning; the short version
          # is that UnicodeData.txt reproduces the corpus fcitx5's unicode addon
          # searched, and emoji-test.txt adds the multi-codepoint sequences
          # (flags, ZWJ families, skin tones) that UnicodeData cannot express.
          nanoUnicodeIndex =
            pkgs.runCommand "nano-unicode-index"
              {
                nativeBuildInputs = [ pkgs.python3 ];
              }
              ''
                mkdir -p "$out/share/nano-desktop"
                python3 ${./unicode/build-index.py} \
                  ${pkgs.unicode-character-database}/share/unicode/UnicodeData.txt \
                  ${pkgs.unicode-emoji}/share/unicode/emoji/emoji-test.txt \
                  "$out/share/nano-desktop/unicode-index.tsv"
              '';

          # Clipboard history picker (Super+V in labwc/rc.xml). cliphist list
          # emits "<id>\t<preview>"; the chosen line goes back through cliphist
          # decode because the preview is truncated and strips newlines, so it
          # is not the entry itself. wl-copy then owns the selection and wtype
          # replays Ctrl+V.
          #
          # The paste is best-effort on purpose: if wtype cannot reach the
          # surface, the entry is already on the clipboard, so the failure mode
          # is "press Ctrl+V yourself" rather than "the pick is lost".
          nano-clipboard = pkgs.writeShellApplication {
            name = "nano-clipboard";
            runtimeInputs = with pkgs; [
              cliphist
              fuzzel
              wl-clipboard
              wtype
              coreutils
            ];
            text = ''
              # Escape / no match exits fuzzel non-zero — not an error here.
              sel=$(cliphist list | fuzzel --dmenu --prompt "Clipboard ") || exit 0
              [ -n "$sel" ] || exit 0
              printf '%s' "$sel" | cliphist decode | wl-copy
              # wl-copy has to install the selection, and focus has to land back
              # on the application, before a synthesised Ctrl+V means anything.
              sleep 0.06
              wtype -M ctrl -k v -m ctrl || true
            '';
          };

          # Unicode / emoji picker (Super+. in labwc/rc.xml). Types the
          # character directly with `wtype -` (stdin, so no argument quoting to
          # get wrong — U+002D HYPHEN-MINUS would otherwise parse as a flag) and
          # deliberately leaves the clipboard alone, matching how fcitx5 used to
          # commit at the caret without clobbering the selection. Only if wtype
          # fails does it fall back to the clipboard, and then it says so.
          nano-unicode = pkgs.writeShellApplication {
            name = "nano-unicode";
            runtimeInputs = with pkgs; [
              fuzzel
              wl-clipboard
              wtype
              libnotify
              coreutils
            ];
            text = ''
              index=${nanoUnicodeIndex}/share/nano-desktop/unicode-index.tsv
              sel=$(fuzzel --dmenu --prompt "Unicode " < "$index") || exit 0
              [ -n "$sel" ] || exit 0
              # Index lines are "<char>\tNAME" — keep the character column.
              ch=$(printf '%s' "$sel" | cut -f1)
              [ -n "$ch" ] || exit 0
              sleep 0.06
              if ! printf '%s' "$ch" | wtype -; then
                printf '%s' "$ch" | wl-copy
                notify-send "Unicode" "Could not type $ch — copied to clipboard instead"
              fi
            '';
          };

          # Minimal system upgrade script (no timers, manual invocation only)
          systemUpgradeScript = pkgs.writeShellApplication {
            name = "system-upgrade";
            runtimeInputs = with pkgs; [
              coreutils
              git
              nix
              nixos-rebuild
            ];
            text = ''
              if [ "$(id -u)" -ne 0 ]; then
                exec /run/wrappers/bin/pkexec "$0" "$@"
              fi
              cd /etc/nixos
              BEFORE=$(sha256sum flake.lock 2>/dev/null || echo "")
              ${lib.getExe pkgs.nix} flake update --flake /etc/nixos
              AFTER=$(sha256sum flake.lock 2>/dev/null || echo "")
              if [ "$BEFORE" != "$AFTER" ]; then
                ${lib.getExe pkgs.nixos-rebuild} switch --flake /etc/nixos
                # Session user services carry restartIfChanged=false and the
                # desktop session itself survives the switch (getty@tty1 is
                # masked), so session-level updates land at the next session
                # restart rather than yanking the desktop out from under the
                # user mid-upgrade.
                echo "Upgrade applied. The running desktop session keeps its current binaries; log out or reboot to finish applying session updates." >&2
              else
                echo "Flake lock unchanged, skipping rebuild" >&2
              fi
            '';
          };

          # tty1 desktop launcher (run by the nano-desktop systemd service). Pulls
          # in the NixOS session environment (environment.variables +
          # sessionVariables — GDK_BACKEND, cursor/theme vars, …) via
          # /etc/set-environment, then starts labwc. No autostart script: labwc
          # natively pushes the runtime session vars (WAYLAND_DISPLAY, DISPLAY,
          # XDG_CURRENT_DESKTOP, XDG_SESSION_TYPE, XCURSOR_*) into the D-Bus
          # activation environment and the systemd user manager at startup, and
          # the static remainder is declared once in
          # systemd.user.settings.Manager.DefaultEnvironment (see below). `-s`
          # runs after the compositor (and that env push) is up: it starts
          # nano-session.target, which pulls in the panel/tray/notification
          # helpers; it re-runs on every respawn (Restart=always), same as the
          # old autostart. No `exec`: the trailing stop is the clean-teardown
          # step when labwc exits.
          nanoDesktopLauncher = pkgs.writeShellScript "nano-desktop-launch" ''
            if [ -r /etc/set-environment ]; then
              . /etc/set-environment
            fi
            ${pkgs.labwc}/bin/labwc -C /etc/xdg/labwc \
              -s "/run/current-system/sw/bin/systemctl --user start nano-session.target"
            ${pkgs.systemd}/bin/systemctl --user stop graphical-session.target
          '';

          # labwc titlebar theme carrying the GNOME/Adwaita window-button icons.
          # labwc finds button images by theme name on XDG_DATA_DIRS/themes, so
          # the SVGs must live in share/themes (linked via pathsToLink) rather
          # than /etc/xdg. rc.xml references it as <theme><name>NanoAdwaita.
          # Inactive-window buttons are derived from the active SVGs by dimming
          # (white → the inactive label grey), so only the active icons are
          # kept in-tree under ./labwc/theme.
          nanoLabwcTheme = pkgs.runCommand "nano-labwc-theme" { } ''
            dst=$out/share/themes/NanoAdwaita/labwc
            mkdir -p "$dst"
            cp ${./labwc/theme/NanoAdwaita/labwc}/themerc "$dst/"
            for f in ${./labwc/theme/NanoAdwaita/labwc}/*-active.svg; do
              base=$(basename "$f" -active.svg)
              cp "$f" "$dst/$base-active.svg"
              sed -e 's/#ffffff/#9a9a9a/g' \
                  -e 's/fill-opacity="0.09"/fill-opacity="0.05"/g' \
                  "$f" > "$dst/$base-inactive.svg"
            done
          '';

          # ── Office suite (officeSuite) ──────────────────────────────
          # LibreOffice reads its settings as a stack of configuration layers
          # (CONFIGURATION_LAYERS in program/fundamentalrc): the package's own
          # read-only registry at the bottom, the user's
          # registrymodifications.xcu at the top. Desktop-wide defaults belong
          # between the two — but the store is read-only, so we cannot drop a
          # .xcd into the package's share/registry, and configmgr's layer count
          # is fixed: appending an extra entry to CONFIGURATION_LAYERS makes
          # soffice abort with an uncaught RuntimeException before it draws
          # anything (measured, not feared).
          #
          # So rather than add a layer, re-point the existing one at a directory
          # of symlinks to every shipped .xcd plus one file of our own.
          # LibreOffice takes the list from the environment: rtl's bootstrap
          # resolves CONFIGURATION_LAYERS from there ahead of fundamentalrc, and
          # still expands the BRAND_BASE_DIR references in the rest of the
          # value. Our file declares <dependency file="main"/>, so configmgr
          # parses it after main.xcd and its values win inside the layer — while
          # the user layer still sits above it. That is what keeps these
          # defaults rather than locks: unlike the dconf profile below, a change
          # made in Tools > Options sticks.
          nanoLibreOfficeXcd = pkgs.writeText "nano-desktop.xcd" ''
            <?xml version="1.0"?>
            <oor:data xmlns:xs="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:oor="http://openoffice.org/2001/registry">
              <dependency file="main"/>
              <oor:component-data oor:name="Common" oor:package="org.openoffice.Office">
                <node oor:name="Misc">
                  <!-- Sifr: the flat monochrome icon theme, the closest thing
                       LibreOffice ships to the Adwaita look the rest of the
                       desktop wears. The dark variant by name rather than
                       "sifr" plus LibreOffice's own dark detection, because
                       this desktop is dark unconditionally (locked dconf
                       color-scheme, adw-gtk3-dark) and light Sifr on a dark
                       toolbar is grey-on-grey. -->
                  <prop oor:name="SymbolStyle" oor:op="fuse"><value>sifr_dark</value></prop>
                </node>
              </oor:component-data>
            </oor:data>
          '';

          # The shipped registry and our defaults as one directory.
          nanoLibreOfficeRegistry = pkgs.runCommand "nano-libreoffice-registry" { } ''
            mkdir -p $out
            ln -s ${pkgs.libreoffice-fresh.unwrapped}/lib/libreoffice/share/registry/* $out/
            cp ${nanoLibreOfficeXcd} $out/nano-desktop.xcd
          '';

          # The layer list, rebuilt from the package's own fundamentalrc at
          # build time so it tracks the LibreOffice version instead of being a
          # copy pasted in here — and hard-failing if upstream ever stops
          # leading with the shipped registry layer. A defaults file that is
          # silently no longer read is the one outcome worth ruling out.
          nanoLibreOfficeLayers = pkgs.runCommand "nano-libreoffice-layers" { } ''
            layers=$(sed -n 's/^CONFIGURATION_LAYERS=//p' \
              ${pkgs.libreoffice-fresh.unwrapped}/lib/libreoffice/program/fundamentalrc)
            shipped='xcsxcu:''${BRAND_BASE_DIR}/share/registry'
            case "$layers" in
              "$shipped "*) ;;
              *)
                echo "nano-desktop: fundamentalrc no longer starts CONFIGURATION_LAYERS" >&2
                echo "with the shipped registry layer. Got: $layers" >&2
                exit 1
                ;;
            esac
            printf '%s' "xcsxcu:file://${nanoLibreOfficeRegistry}''${layers#"$shipped"}" > $out
          '';

          # soffice and friends with that layer list in their environment.
          # Wrapping the wrapped package instead of overriding it keeps the
          # whole thing to nine tiny scripts — libreoffice-fresh, 1.5 GB
          # unpacked, stays exactly what the binary cache built. Same reasoning
          # as the Firefox wrapper overlay under nixpkgs.overlays below.
          # --set-default, so `CONFIGURATION_LAYERS=… soffice` still wins.
          nanoLibreOffice =
            pkgs.runCommand "libreoffice-nano-${pkgs.libreoffice-fresh.version}"
              {
                nativeBuildInputs = [ pkgs.makeWrapper ];
                inherit (pkgs.libreoffice-fresh) meta;
              }
              ''
                mkdir -p $out/bin
                ln -s ${pkgs.libreoffice-fresh}/share $out/share
                layers=$(cat ${nanoLibreOfficeLayers})
                for exe in ${pkgs.libreoffice-fresh}/bin/*; do
                  makeWrapper "$exe" "$out/bin/$(basename "$exe")" \
                    --set-default CONFIGURATION_LAYERS "$layers"
                done
              '';

          # What officeSuite selects. Attribute values are lazy, so only the
          # chosen branch is ever evaluated — "none" and "gnome" never so much
          # as mention the LibreOffice derivations above.
          officePackages =
            {
              libreoffice = [ nanoLibreOffice ];
              gnome = with pkgs; [
                abiword
                gnumeric
              ];
              none = [ ];
            }
            .${cfg.officeSuite};

          # Document types, pointed at the suite in use. Only types the chosen
          # applications actually handle: in "gnome" that leaves .docx and every
          # presentation format unassociated, because AbiWord does not read
          # OOXML text documents and the pair has no presentation program at
          # all. An association that mangles the file is worse than none — those
          # types fall through to the file manager's "Open With" instead.
          officeMimeApps =
            {
              libreoffice = {
                # Writer
                "application/vnd.oasis.opendocument.text" = "writer.desktop";
                "application/vnd.oasis.opendocument.text-template" = "writer.desktop";
                "application/vnd.openxmlformats-officedocument.wordprocessingml.document" = "writer.desktop";
                "application/msword" = "writer.desktop";
                "application/rtf" = "writer.desktop";
                "text/rtf" = "writer.desktop";
                # Calc
                "application/vnd.oasis.opendocument.spreadsheet" = "calc.desktop";
                "application/vnd.oasis.opendocument.spreadsheet-template" = "calc.desktop";
                "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" = "calc.desktop";
                "application/vnd.ms-excel" = "calc.desktop";
                "text/csv" = "calc.desktop";
                # Impress
                "application/vnd.oasis.opendocument.presentation" = "impress.desktop";
                "application/vnd.oasis.opendocument.presentation-template" = "impress.desktop";
                "application/vnd.openxmlformats-officedocument.presentationml.presentation" = "impress.desktop";
                "application/vnd.ms-powerpoint" = "impress.desktop";
                # Draw / Math / Base. Note that .odb is
                # opendocument.database to shared-mime-info but
                # opendocument.base in LibreOffice's own base.desktop — the
                # explicit association here is what makes double-click work,
                # since the file manager only ever sees the former.
                "application/vnd.oasis.opendocument.graphics" = "draw.desktop";
                "application/vnd.oasis.opendocument.graphics-template" = "draw.desktop";
                "application/vnd.oasis.opendocument.formula" = "math.desktop";
                "application/vnd.oasis.opendocument.database" = "base.desktop";
              };
              gnome = {
                "application/vnd.oasis.opendocument.text" = "abiword.desktop";
                "application/vnd.oasis.opendocument.text-template" = "abiword.desktop";
                "application/msword" = "abiword.desktop";
                "application/rtf" = "abiword.desktop";
                "application/x-abiword" = "abiword.desktop";
                "application/vnd.oasis.opendocument.spreadsheet" = "org.gnumeric.gnumeric.desktop";
                "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" =
                  "org.gnumeric.gnumeric.desktop";
                "application/vnd.ms-excel" = "org.gnumeric.gnumeric.desktop";
                "application/x-gnumeric" = "org.gnumeric.gnumeric.desktop";
                "text/csv" = "org.gnumeric.gnumeric.desktop";
              };
              none = { };
            }
            .${cfg.officeSuite};

          # ── Storage profile (diskType / swapSizeGiB) ─────────────────
          # Everything that has to be decided before the disk exists, keyed on
          # nanoDesktop.diskType. The counterpart to this is the udev block
          # under services.udev.extraRules, which tunes the block layer per
          # device off queue/rotational instead — see the note there for why
          # the split is deliberate.
          #
          # f2fs is a log-structured filesystem written for NAND: it turns
          # random writes into sequential ones and cleans segments in the
          # background, which is free on flash and a seek storm on a platter.
          # XFS is the spinning-disk answer — delayed logging keeps the
          # metadata-heavy Nix store off the head, and it is the one thing this
          # module's whole reclaim/scheduler posture is built to protect.
          #
          # What an HDD install gives up is f2fs's transparent zstd
          # compression, which XFS has no equivalent for. On a platter that is
          # a disk-space cost rather than a throughput one, but it is why the
          # same package set occupies noticeably more disk on "hdd".
          diskProfile =
            {
              ssd = {
                rootFormat = "f2fs";
                rootMountOptions = [
                  "atgc"
                  "compress_algorithm=zstd:1" # Level 1: minimal CPU overhead, reduces I/O bandwidth
                  "compress_cache" # Cache decompressed pages for hot data (SQLite, desktop apps)
                  "compress_chksum"
                  "compress_extension=*" # Compress all files by default
                  # ...except frequently-rewritten small WAL/journal/lock files: recompressing
                  # a whole cluster on every tiny in-place-ish rewrite (SQLite/LevelDB WAL,
                  # systemd journal) is a known GC/checkpoint stall pattern under f2fs, worst
                  # when the volume is mostly full. See linux-f2fs-devel deadlock reports.
                  # f2fs mount options are comma-split at the top level, so each excluded
                  # extension needs its own repeated nocompress_extension=... entry — a single
                  # comma-joined value gets torn into unrecognized tokens and fails root mount.
                  # Each extension is also capped at 7 chars (F2FS_EXTENSION_LEN=8 incl. NUL) —
                  # "sqlite-wal"/"sqlite-shm" (10 chars) overflow that and get rejected with
                  # "invalid extension length/number", failing the mount entirely. Omitted below;
                  # rely on the shorter db-wal/db-shm convention instead.
                  "nocompress_extension=db"
                  "nocompress_extension=db-wal"
                  "nocompress_extension=db-shm"
                  "nocompress_extension=sqlite"
                  "nocompress_extension=ldb"
                  "nocompress_extension=log"
                  "nocompress_extension=journal"
                  "nocompress_extension=lock"
                  "gc_merge"
                  "noatime"
                  "nodiscard" # Use scheduled fstrim instead of synchronous discard
                ];
                rootExtraArgs = [
                  "-O"
                  "extra_attr,compression"
                  "-l"
                  "root"
                ];
                # fstrim(8) walks mounted filesystems and never touches a swap
                # partition, so swapon's own discard is the only thing that
                # ever trims this area. "once" does it at swapon and then
                # leaves the device alone, rather than issuing a discard on
                # every page freed.
                swapDiscardPolicy = "once";
              };
              hdd = {
                rootFormat = "xfs";
                rootMountOptions = [
                  "noatime"
                  # VFS-level: timestamps live in memory and flush with other
                  # metadata or after ~24h. Removes a whole class of tiny
                  # metadata writes, which on a platter are seeks.
                  "lazytime"
                  # In-memory log buffer, up from the 32k default — fewer,
                  # larger log writes, so less head movement for metadata.
                  # Costs ~2 MB of RAM (8 buffers) and widens the window of
                  # metadata not yet in the log if the power goes. fsync is
                  # still honoured, so this trades crash-window for seeks, not
                  # durability guarantees.
                  "logbsize=256k"
                ];
                # -L root only: crc, sparse inodes, reflink and bigtime are all
                # xfsprogs defaults now, and mkfs.xfs already picks sensible
                # allocation-group counts for a single spindle.
                rootExtraArgs = [
                  "-L"
                  "root"
                ];
                # Nothing to trim on a platter.
                swapDiscardPolicy = null;
              };
            }
            .${cfg.diskType};

          # Partitions shared by both boot modes. Defined once here because the
          # uefi and legacy tables differ only in what comes *before* them (an
          # ESP, versus a BIOS boot partition plus an ext4 /boot) — and because
          # keeping two copies is how the legacy branch ended up silently
          # missing compress_cache and the whole nocompress_extension list.
          swapPartition = {
            size = "${toString cfg.swapSizeGiB}G";
            content = {
              type = "swap";
              resumeDevice = true;
              discardPolicy = diskProfile.swapDiscardPolicy;
            };
          };
          rootPartition = {
            size = "100%";
            content = {
              type = "filesystem";
              format = diskProfile.rootFormat;
              mountpoint = "/";
              mountOptions = diskProfile.rootMountOptions;
              extraArgs = diskProfile.rootExtraArgs;
            };
          };
          # Ordering is disko's job, not the attribute names': it sorts by the
          # partition's `priority`, which defaults to 9001 for size = "100%".
          # Root is therefore created last whether or not swap is present, so
          # dropping the swap partition at swapSizeGiB = 0 needs nothing else.
          diskPartitions =
            optionalAttrs (cfg.swapSizeGiB > 0) {
              swap = swapPartition;
            }
            // {
              root = rootPartition;
            };
        in
        {
          imports = [
            inputs.disko.nixosModules.disko
          ];

          options.nanoDesktop = {
            hostName = mkOption {
              type = types.str;
              description = "Hostname for the system";
            };
            diskDevice = mkOption {
              type = types.str;
              default = "/dev/sda";
              description = "Disk device for installation";
            };
            diskType = mkOption {
              type = types.enum [
                "ssd"
                "hdd"
              ];
              default = "ssd";
              description = ''
                What kind of drive this machine installs onto. A fair share of
                the hardware this desktop targets still boots off a platter, and
                a platter wants a different filesystem, a different set of
                background services and a different swap posture than flash
                does — so it is one switch rather than five.

                - "ssd": an f2fs root with transparent zstd compression, a daily
                  fstrim, and swapon --discard=once on the swap partition.
                - "hdd": an XFS root, no fstrim timer, and more zram before
                  anything reaches the platter.

                f2fs is written for NAND. It turns random writes into sequential
                ones and cleans segments in the background — free on flash,
                and on a spinning disk a seek storm sitting underneath every
                other thing this module does to keep the machine responsive.
                XFS is the answer there: its delayed logging keeps the
                metadata-heavy Nix store off the head. What you give up is
                f2fs's compression, which XFS has no equivalent for, so the same
                package set takes noticeably more disk on "hdd".

                Note what this option is NOT. It is an install-time decision:
                disko derives fileSystems."/".fsType from it, so changing it on
                a machine that is already installed produces a configuration
                whose root will not mount. It migrates nothing and reformats
                nothing. Get it right at install time, or reinstall.

                Only the choices that must be made before the disk exists live
                here. The block-layer tuning that can be decided at runtime —
                I/O scheduler, readahead, ATA head parking — is keyed on the
                kernel's own queue/rotational flag in services.udev.extraRules
                instead, so it is also right for a second or external drive of
                the other kind, and stays right even if this option is wrong.
              '';
            };
            swapSizeGiB = mkOption {
              type = types.ints.unsigned;
              default = 8;
              description = ''
                Size of the disk swap partition, in GiB. 0 leaves it out
                entirely.

                This is the second swap tier, not the first: zram sits above it
                at priority 100 (see zramSwap below), so the kernel fills
                compressed RAM before it touches the disk. What the partition
                actually buys is hibernation, which needs a resume device at
                least as large as RAM, plus somewhere to go when zram is full
                instead of the OOM killer.

                Which makes 8 GiB a default, not a recommendation. Size it
                against the machine in front of you: at least RAM if you want
                hibernation to work, and rather less than 8 GiB is reasonable
                on a small disk where the space is worth more than a tier that
                is only reached under real pressure. At 0 there is no swap
                partition, no swapDevices entry, no boot.resumeDevice and no
                hibernation — zram alone.

                Install-time, like diskType, but harmless to change afterwards
                rather than dangerous: nothing repartitions on rebuild, so a new
                value simply has no effect on an installed machine. The one
                exception is 0, which drops the swapDevices entry and so stops
                activating a partition that is still sitting on the disk.
              '';
            };
            bootMode = mkOption {
              type = types.enum [
                "uefi"
                "legacy"
              ];
              default = "uefi";
              description = "Boot mode: uefi (systemd-boot) or legacy (GRUB)";
            };
            cpuMitigations = mkOption {
              type = types.bool;
              default = true;
              description = ''
                Keep the kernel's CPU vulnerability mitigations (Meltdown page
                table isolation, Spectre retpolines, MDS/L1TF buffer clears).
                Setting this false adds mitigations=off, which is a security
                decision, not a tuning knob — so it is spelled out here rather
                than buried in kernelParams.

                It is worth understanding what the trade actually is on the
                hardware this desktop targets, because it is not the same trade
                as on a current machine. Mitigations cost the most on exactly
                the oldest CPUs: pre-Skylake parts pay for Meltdown in software
                (PTI flushes the TLB on every syscall) instead of in silicon,
                and the bill lands on syscall- and context-switch-heavy work —
                compiling, unpacking, file managers, browsers — which is most
                of what a desktop does. Reported figures run from a few percent
                to well over 30% depending on the workload; measure yours
                rather than trusting a number.

                And on a machine old enough that Intel has stopped shipping
                microcode for it, some of that is protection you are not
                getting anyway. The Ivy Bridge laptop this was written on
                reports "mds: Vulnerable: Clear CPU buffers attempted, no
                microcode" and "srbds: Vulnerable: No microcode" — it pays for
                PTI and retpolines in full while remaining exposed to the
                classes that need a microcode update to fix. Check
                /sys/devices/system/cpu/vulnerabilities/ on the machine in
                front of you before deciding.

                What you keep by leaving this on: the mitigations that do work
                without microcode, PTI being the important one — Meltdown is
                trivially exploitable and reads kernel memory from any
                unprivileged process. What you give up by turning it off is
                real on a machine that runs a browser. The default is therefore
                the kernel's own; a single-user machine doing local work on
                trusted data is a reasonable place to flip it.
              '';
            };
            hardwareVideo = mkOption {
              type = types.enum [
                "auto"
                "intel-modern"
                "intel-legacy"
                "none"
              ];
              default = "auto";
              description = ''
                VA-API hardware video decoding. Probably the largest single
                win available to this class of machine: a 1080p stream decoded
                on the GPU costs a few percent of one core, and the same stream
                decoded in software will hold an old dual-core at the ceiling,
                heat it until it throttles, and drop frames anyway.

                AMD and older Intel-with-Mesa paths come from mesa, which is
                installed either way; the choice here is which Intel VA-API
                driver to add, and it is a choice because the two do not
                overlap:

                - "auto": install both. libva asks the DRM driver what it is
                  and tries the candidates in turn, so the wrong one failing to
                  initialise falls through to the right one. Costs the closure
                  of both drivers and is the only option that needs no
                  knowledge of the machine.
                - "intel-modern": intel-media-driver (iHD), Broadwell and
                  newer.
                - "intel-legacy": intel-vaapi-driver (i965), roughly GMA 4500
                  through Skylake. The Ivy Bridge and Sandy Bridge laptops this
                  desktop is aimed at need this one; iHD does not support them.
                - "none": mesa only.

                vainfo (from libva-utils) is installed with any setting other
                than "none", because "is acceleration actually being used" is
                otherwise unanswerable. Note that Firefox decides separately
                and per-codec, and mpv/Celluloid need hardware decoding turned
                on in their own settings.
              '';
            };
            timeZone = mkOption {
              type = types.str;
              default = "America/New_York";
              description = "System timezone";
            };
            locale = mkOption {
              type = types.str;
              default = "en_US.UTF-8";
              description = "System locale";
            };
            username = mkOption {
              type = types.str;
              description = "Primary user name";
            };
            initialPassword = mkOption {
              type = types.str;
              default = "password";
              description = "Initial password for the user";
            };
            stateVersion = mkOption {
              type = types.str;
              default = "25.11";
              description = "NixOS state version";
            };
            officeSuite = mkOption {
              type = types.enum [
                "libreoffice"
                "gnome"
                "none"
              ];
              default = "libreoffice";
              description = ''
                Office suite to install, and the suite the document MIME types
                are pointed at. An enum rather than a feature-flag bool because
                the choice is three-way, and because the installer builds its
                menu out of these options (see nixos-install-helper below) —
                where an enum becomes a pick-list, like bootMode.

                - "libreoffice": libreoffice-fresh, the whole suite (Writer,
                  Calc, Impress, Draw, Math, Base). By far the largest thing on
                  the system — 1.5 GB unpacked, 2.7 GB of closure, most of it
                  shared with nothing else here — and the only option that reads
                  and writes .docx/.xlsx/.pptx faithfully enough to hand the file
                  back to whoever sent it. Started with desktop defaults spliced
                  into its configuration registry (currently the Sifr icon
                  theme, dark variant, to match the rest of the desktop); they
                  are defaults, not locks, so Tools > Options still wins.

                - "gnome": AbiWord and Gnumeric, the GNOME Office pair — about
                  0.6 GB together, most of which is the GTK stack this desktop
                  already carries, and quick to start on old hardware. Between
                  them they cover ODT/DOC/RTF and ODS/XLS/XLSX/CSV. There is no
                  presentation program, and AbiWord does not read .docx, so
                  those types are deliberately left unassociated instead of
                  being pointed at something that would mangle them.

                - "none": no office applications.

                Either suite is reachable from the panel's Start menu, which
                enumerates installed .desktop files; the labwc right-click menu
                is a fixed list and does not change with this option.

                Neither suite ships spell-check dictionaries. Add the ones you
                want through extraPackages (e.g. pkgs.hunspellDicts.en_US) —
                both find them in the system profile.
              '';
            };
            extraPackages = mkOption {
              type = types.listOf types.package;
              default = [ ];
              description = "Additional packages to install";
            };
            enableSsh = mkOption {
              type = types.bool;
              default = false;
              description = "Enable SSH server";
            };
            sshPasswordAuth = mkOption {
              type = types.bool;
              default = true;
              description = "Allow password authentication for SSH";
            };
            sshRootLogin = mkOption {
              type = types.str;
              default = "yes";
              description = "Permit root login via SSH";
            };

            # Feature flags — every desktop service that costs idle RAM or disk
            # but is not essential to a working desktop sits behind one of
            # these. Most default on (the featureful desktop) and can be
            # switched off per machine; the two that default OFF (audioServer,
            # desktopPortal) are the heavier choices this lite / old-hardware
            # target deliberately skips — turn them on where they are wanted.
            # They set the underlying NixOS options with mkDefault, so
            # overriding those options directly still works too.
            features = {
              audioServer = mkOption {
                type = types.bool;
                default = false;
                description = ''
                  Full PipeWire/WirePlumber audio server. Needed for Bluetooth
                  audio output (A2DP), automatic device routing (auto-switch to
                  headphones on plug-in), and per-application volume.

                  When off, the desktop drops the server entirely and uses
                  apulse/pressureaudio instead: a PulseAudio-API-compatible
                  shim implemented directly over ALSA (dmix/dsnoop/plug), with
                  NO daemon — the lowest-footprint option. It drives only local
                  ALSA devices (built-in speakers, headphone jack, HDMI, USB);
                  there is no Bluetooth audio and no server-side mixer, so
                  pavucontrol is replaced by amixer/alsamixer and the panel
                  volume widget talks to the hardware Master control. Firefox
                  (which has no ALSA fallback) is pointed at libpressureaudio
                  via a wrapper-scoped overlay; mpv/Celluloid and other clients
                  fall back to ALSA on their own. Only the small Firefox wrapper
                  rebuilds — firefox-unwrapped and the pipewire/gstreamer closure
                  stay on the binary cache (see the nixpkgs.overlays note).
                '';
              };
              autoUpgrade = mkOption {
                type = types.bool;
                default = true;
                description = ''
                  Daily automatic background upgrade timer (flake update +
                  nixos-rebuild switch). The manual `system-upgrade` command
                  remains available either way.
                '';
              };
              bluetooth = mkOption {
                type = types.bool;
                default = true;
                description = ''
                  Bluetooth support: bluetoothd (backing the panel's bluetooth
                  widget) plus blueman-manager for on-demand management.
                  Disable on machines without bluetooth hardware.

                  Note the interaction with features.audioServer: A2DP audio
                  output is a PipeWire feature, so with audioServer off there is
                  no bluetooth sound and this flag buys only input devices
                  (mice, keyboards, controllers) and file transfer. On a machine
                  with neither, turning it off drops bluetoothd (~4.4 MB) and
                  keeps the bluetooth kernel module and its six drivers
                  (~1.2 MB plus their dependents) unloaded.
                '';
              };
              clipboardHistory = mkOption {
                type = types.bool;
                default = true;
                description = ''
                  Clipboard history (Super+V) and unicode/emoji search
                  (Super+.), both presented through fuzzel and typed back into
                  the focused window with wtype.

                  The only resident cost is a wl-paste watcher feeding cliphist,
                  around 1-2 MB; the pickers themselves exist only for as long
                  as their window is open. This replaced an fcitx5-based
                  implementation that cost ~20 MB PSS and, because it worked by
                  being the session's input method, sat in the path of every
                  keystroke on the machine.

                  Note what that means if you need a real input method: this
                  desktop no longer ships one. Latin layouts are unaffected
                  (labwc/xkbcommon handle them — see
                  environment.sessionVariables.XKB_DEFAULT_LAYOUT), but CJK and
                  other composed scripts need fcitx5 or ibus added back through
                  nanoDesktop.extraPackages plus a user service to run it.
                '';
              };
              desktopPortal = mkOption {
                type = types.bool;
                default = false;
                description = ''
                  xdg-desktop-portal plus the GTK backend. Portals broker file
                  dialogs, notifications, OpenURI and the appearance/color-scheme
                  signal for sandboxed and portal-using apps. On this Wayland-only,
                  non-sandboxed desktop the native paths already cover all of it —
                  GTK's own file chooser, mako for notifications, xdg-open for
                  OpenURI, and dark mode from the locked dconf color-scheme, which
                  libadwaita reads directly through its GSettings backend when no
                  portal answers — so it defaults off to save the ~25-35 MB its
                  two D-Bus services take up once a GTK app triggers them. Enable
                  it for Flatpak/sandboxed apps, screen-casting portals, or if a
                  GTK4 app ends up light without it.
                '';
              };
              networkDiscovery = mkOption {
                type = types.bool;
                default = true;
                description = ''
                  Avahi mDNS/DNS-SD: .local hostname resolution and the
                  discovery that network printer/scanner setup relies on.
                  Disabling it makes features.printing/scanning setup manual.
                '';
              };
              printing = mkOption {
                type = types.bool;
                default = true;
                description = ''
                  CUPS printing stack plus system-config-printer. cupsd is
                  socket-activated, so it only occupies memory once something
                  prints (or the configuration tool is opened).
                '';
              };
              processScheduling = mkOption {
                type = types.bool;
                default = false;
                description = ''
                  ananicy-cpp with the CachyOS rule set: nice, ionice, cgroup
                  and scheduling policy applied per application, automatically,
                  so that a compiler or an indexer cannot compete with the
                  thing being typed into. It is the same idea as the resource
                  guards this module already applies to nix-daemon, generalised
                  to every program with a rule.

                  Off by default because it is a resident daemon that polls
                  /proc on an interval — modest memory, but a periodic wakeup
                  on a laptop that is otherwise engineered down to almost none,
                  which is the same reason audioServer and desktopPortal
                  default off. Worth turning on for a machine that regularly
                  runs something heavy in the background.
                '';
              };
              scanning = mkOption {
                type = types.bool;
                default = true;
                description = ''
                  SANE scanner support, including driverless network scanning
                  via sane-airscan (library-only: no resident cost, disk only).
                '';
              };
              thermalManagement = mkOption {
                type = types.bool;
                default = true;
                description = ''
                  thermald, Intel's thermal daemon. On hardware this old the
                  cooling is usually the most degraded part of the machine —
                  dried paste, a fan full of a decade of dust — and the failure
                  mode is a throttle spiral: the package hits its limit, the
                  firmware cuts the multiplier hard, everything crawls. thermald
                  steers with the thermal tables before it gets there.

                  Intel only, and it means it: thermald checks CPUID at startup
                  and exits on anything else, which would leave a failed unit
                  on every boot. Turn this off on AMD.
                '';
              };
              thumbnails = mkOption {
                type = types.bool;
                default = true;
                description = ''
                  Tumbler thumbnailer (D-Bus activated on demand by the file
                  manager; idle cost is zero until thumbnails are requested).
                '';
              };
              virtualFilesystems = mkOption {
                type = types.bool;
                default = true;
                description = ''
                  GVFS virtual filesystems: trash, MTP/PTP devices (phones,
                  cameras) and network shares in the file manager.

                  gvfsd is D-Bus activated, not session-started, so it costs
                  nothing until a GIO client asks for it. In practice something
                  in the session pokes it once at startup and it then stays
                  resident for the session — but the real cost is small: ~2.8 MB
                  PSS for gvfsd plus under 2 MB for gvfsd-fuse, because most of
                  its ~16 MB RSS is glib/gio already mapped by the panel. (An
                  earlier revision of this note claimed ~20 MB; that was reading
                  RSS and double-counting shared pages.)
                '';
              };
            };
          };

          config = {
            # ── Boot ────────────────────────────────────────────────────
            boot = {
              initrd = {
                availableKernelModules = [
                  "ahci"
                  "ehci_pci"
                  "nvme"
                  "uhci_hcd"
                ];
                systemd.enable = mkDefault true;
                verbose = mkDefault false;
              };
              kernelPackages = mkDefault pkgs.linuxPackages_latest;
              kernelParams = [
                "boot.shell_on_fail"
                "console=tty0"
                # Zeroing every page on allocation and on free is a nixpkgs
                # default (CONFIG_INIT_ON_ALLOC_DEFAULT_ON), not an upstream
                # one — Debian, Fedora and Arch all ship the kernel's own
                # setting, which is off, and which is what these two restore.
                # It buys back a memset on every allocation, and the memory
                # bandwidth it is spending belongs to a 2012 laptop.
                #
                # What it gives up is hardening rather than a fix for any
                # particular hole: uninitialised heap and page contents stop
                # being reliably zero, which makes some info-leak and
                # use-after-free bugs easier to turn into exploits. The larger
                # lever of the same kind is nanoDesktop.cpuMitigations, and
                # that one is deliberately left at the safe setting.
                "init_on_alloc=0"
                "init_on_free=0"
                "loglevel=3"
                "mem_sleep_default=deep"
                # No lockup detector: one armed perf counter and one timer per
                # CPU, permanently, to catch a class of kernel bug this desktop
                # can do nothing about anyway. It is also what prints "perf:
                # interrupt took too long" once the machine is already in
                # trouble. Cost of turning it off: a hard lockup hangs quietly
                # instead of panicking with a backtrace.
                "nmi_watchdog=0"
                "nowatchdog"
                "pcie_aspm.policy=powersupersave"
                # CONFIG_PREEMPT_DYNAMIC makes this a boot-time choice instead
                # of a kernel rebuild. Full preemption lets the scheduler
                # interrupt the kernel itself: a little throughput for the one
                # thing this desktop cares about, which is that the pointer
                # keeps moving while something heavy is running.
                "preempt=full"
                "quiet"
                "rd.systemd.show_status=false"
                "systemd.show_status=false"
                "rd.udev.log_level=3"
                # Huge pages only where a program asks for one. The kernel
                # default ("always") has khugepaged compacting memory in the
                # background to manufacture 2 MB pages, and compaction on a
                # small, fragmented, already-tight machine is precisely the
                # latency spike the reclaim tuning below exists to avoid.
                "transparent_hugepage=madvise"
                "udev.log_priority=3"
              ]
              ++ optional (!cfg.cpuMitigations) "mitigations=off";
              kernel.sysctl = {
                # High on purpose, and it stays high: with zram the cheap thing
                # to evict is anonymous memory (compressed, still in RAM), and
                # the expensive thing is file-backed pages, which have to be
                # read back off the disk. See the reclaim note under
                # "Resource guards" — the stall this machine actually suffers
                # is refaulting executables, not swapping. Note this argument
                # gets *stronger* under diskType = "hdd", not weaker: the
                # refault it is avoiding costs a seek there.
                "vm.swappiness" = mkDefault 100;
                "vm.vfs_cache_pressure" = mkDefault 50;
                # No swap-in readahead. Right for zram, which is the tier that
                # is actually hot — reading one compressed page back is cheap
                # and guessing at neighbours is not. Deliberately not raised
                # for diskType = "hdd", even though batched readahead would
                # suit the platter: the disk swap there sits below zram at a
                # priority the kernel only reaches under real pressure, and
                # tuning for it would tax every zram fault to help the case
                # where the machine has already lost.
                "vm.page-cluster" = mkDefault 0;
                # kswapd wakes when free memory drops to 0.1% of the zone —
                # on a 4 GB machine that is a runway of a few MB, so a burst of
                # allocation overruns it and lands in *direct* reclaim, which
                # stalls the allocating thread instead of a background kernel
                # thread. 2% gives kswapd room to keep ahead. Costs a little
                # memory kept free that could have been cache.
                "vm.watermark_scale_factor" = mkDefault 200;
                # Bound the writeback backlog. The defaults (20% hard, 10%
                # background) let ~750 MB of dirty pages queue up here before
                # anything is forced out, and this desktop has no fast way to
                # drain that: under diskType = "ssd" every page goes through
                # zstd compression on the way out, and under "hdd" it goes to a
                # platter. Either way the queue empties slowly and whoever hits
                # the hard limit blocks until it does. Starting earlier keeps
                # each stall short, which is why one pair of values covers both.
                "vm.dirty_ratio" = mkDefault 10;
                "vm.dirty_background_ratio" = mkDefault 5;
                # Background CPU spent keeping high-order pages available. With
                # transparent_hugepage=madvise almost nothing on this desktop
                # asks for one, so it is work done for nobody.
                "vm.compaction_proactiveness" = mkDefault 0;
                # Boosting temporarily multiplies the reclaim watermark after a
                # fragmentation event, which on a 4 GB machine arrives as a
                # burst of eviction. The steady, higher watermark set above is
                # the behaviour wanted here instead of a spiky one.
                "vm.watermark_boost_factor" = mkDefault 0;
              };
              consoleLogLevel = mkDefault 0;
              loader = mkMerge [
                (mkIf (cfg.bootMode == "uefi") {
                  efi.canTouchEfiVariables = mkDefault true;
                  systemd-boot = {
                    configurationLimit = mkDefault 10;
                    enable = mkDefault true;
                  };
                })
                (mkIf (cfg.bootMode == "legacy") {
                  grub = {
                    enable = mkDefault true;
                  };
                })
                ({ timeout = mkDefault 2; })
              ];
              # The root filesystem in use is added to this set automatically —
              # nixpkgs derives it from `fileSystems` at normal priority, which
              # would quietly override an mkDefault false here. So these track
              # diskType rather than stating a constant that may be a lie: the
              # point is to keep the *unused* one's tools (f2fs-tools /
              # xfsprogs) and initrd module off a system that will never mount
              # one. ext3 is covered by the ext4 driver either way.
              supportedFilesystems = {
                ext3 = mkDefault false;
                f2fs = mkDefault (cfg.diskType == "ssd");
                ntfs3 = mkDefault false;
                xfs = mkDefault (cfg.diskType == "hdd");
                zfs = mkDefault false;
              };
              swraid.enable = mkDefault false;
              tmp = {
                useTmpfs = mkDefault true;
                tmpfsSize = mkDefault "50%";
              };
            };

            # ── Console ─────────────────────────────────────────────────
            console = {
              keyMap = mkDefault "us";
              packages = [ pkgs.terminus_font ];
            };

            # ── Disk Layout (disko) ─────────────────────────────────────
            # Only the leading partitions differ between the boot modes — an
            # ESP, versus a BIOS boot partition plus an ext4 /boot. Swap and
            # root are the same table either way and come from diskPartitions
            # in the let block above, which is also where diskType picks the
            # root filesystem and swapSizeGiB sizes (or removes) the swap.
            disko.devices = mkDefault {
              disk.main = {
                device = cfg.diskDevice;
                type = "disk";
                content = mkMerge [
                  (mkIf (cfg.bootMode == "uefi") {
                    type = "gpt";
                    partitions = {
                      ESP = {
                        size = "512M";
                        type = "EF00";
                        content = {
                          type = "filesystem";
                          format = "vfat";
                          mountpoint = "/boot";
                          mountOptions = [
                            "noatime"
                            "umask=0077"
                          ];
                          extraArgs = [
                            "-n"
                            "ESP"
                          ];
                        };
                      };
                    }
                    // diskPartitions;
                  })
                  (mkIf (cfg.bootMode == "legacy") {
                    type = "gpt";
                    partitions = {
                      boot = {
                        size = "1M";
                        type = "EF02";
                      };
                      # GRUB reads ext4 natively and completely, which neither
                      # root filesystem on offer here can promise: its f2fs
                      # driver cannot read transparent compression at all, and
                      # its xfs driver trails the on-disk features mkfs.xfs
                      # turns on by default. A small ext4 /boot keeps GRUB's
                      # modules somewhere it is certain to reach them, under
                      # either diskType.
                      esp = {
                        size = "512M";
                        type = "EF00";
                        content = {
                          type = "filesystem";
                          format = "ext4";
                          mountpoint = "/boot";
                          mountOptions = [ "noatime" ];
                        };
                      };
                    }
                    // diskPartitions;
                  })
                ];
              };
            };

            # ── Documentation ───────────────────────────────────────────
            documentation = {
              enable = mkDefault false;
              doc.enable = mkDefault false;
              man.enable = mkDefault false;
              nixos.enable = mkDefault false;
            };

            # ── Environment ─────────────────────────────────────────────
            environment = {
              etc = {
                # System-wide labwc config, loaded via `labwc -C /etc/xdg/labwc`
                # (labwc's only other source is the immutable in-store default,
                # so we point it at /etc explicitly). No autostart/environment
                # files anymore: session startup is the launcher's `-s` flag,
                # runtime env comes from labwc's native import, and static env
                # is declared in systemd.user.settings.Manager.DefaultEnvironment.
                # XKB layout defaults to "us" inside xkbcommon; set
                # environment.sessionVariables.XKB_DEFAULT_LAYOUT to change it.
                "xdg/labwc/rc.xml".source = ./labwc/rc.xml;
                "xdg/labwc/menu.xml".source = ./labwc/menu.xml;
                "xdg/labwc/themerc-override".source = ./labwc/themerc-override;
                # System-wide Sfwbar panel, loaded via `sfwbar -f`. The sibling
                # sfwbar.css is auto-loaded by Sfwbar from the same directory.
                # sfwbar.config is spliced (not copied) so the volume widget can
                # follow features.audioServer — see sfwbarConfig in the let block.
                "xdg/sfwbar/sfwbar.config".text = sfwbarConfig;
                "xdg/sfwbar/sfwbar.css".source = ./sfwbar/sfwbar.css;
                # foot terminal — Adwaita Mono + GNOME/Adwaita dark palette. foot
                # reads it from XDG_CONFIG_DIRS (/etc/xdg), like the gtk configs.
                "xdg/foot/foot.ini".source = ./foot/foot.ini;
                # fuzzel launcher (Super+Space + F12/Alt-F2), Adwaita-dark.
                "xdg/fuzzel/fuzzel.ini".source = ./fuzzel/fuzzel.ini;
                # PCManFM/libfm: point "Open Terminal" and open-in-terminal
                # actions at foot (libfm defaults to an unset terminal → the
                # "terminal emulator is not set" error). foot is not in libfm's
                # terminals.list, so libfm falls back to `foot -e <cmd>`; foot
                # accepts and ignores -e (xterm compat), so this works for both
                # bare "Open Terminal" and execute-in-terminal.
                "xdg/libfm/libfm.conf".text = ''
                  [config]
                  terminal=foot
                '';
                # mako notifications — Adwaita-dark, GNOME-style. mako only
                # auto-reads ~/.config/mako/config, so the service loads this
                # explicitly with `--config` (see systemd.user.services.mako).
                "xdg/mako/config".source = ./mako/config;
                # GTK3/GTK4 system-wide settings. /etc/xdg is on XDG_CONFIG_DIRS,
                # so GTK apps pick up the theme/icon/cursor/font from here. The
                # modern-Adwaita-dark default: GTK3 → adw-gtk3-dark, GTK4 → the
                # built-in Adwaita forced dark via prefer-dark. The locked dconf
                # profile (programs.dconf below) is the authoritative source for
                # GNOME/libadwaita apps; these files cover non-dconf GTK apps.
                "xdg/gtk-3.0/settings.ini".text = ''
                  [Settings]
                  gtk-theme-name=adw-gtk3-dark
                  gtk-icon-theme-name=Papirus-Dark
                  gtk-cursor-theme-name=Adwaita
                  gtk-cursor-theme-size=24
                  gtk-font-name=Adwaita Sans 11
                  gtk-application-prefer-dark-theme=1
                '';
                "xdg/gtk-4.0/settings.ini".text = ''
                  [Settings]
                  gtk-theme-name=Adwaita
                  gtk-icon-theme-name=Papirus-Dark
                  gtk-cursor-theme-name=Adwaita
                  gtk-cursor-theme-size=24
                  gtk-font-name=Adwaita Sans 11
                  gtk-application-prefer-dark-theme=1
                '';
                # Allow unfree by default
                "nix/nixpkgs-config.nix".text = lib.mkDefault ''
                  { allowUnfree = true; }
                '';
              };
              # Desktop launch is no longer wired through the login shell — a
              # dedicated systemd service (systemd.services.nano-desktop) owns tty1
              # and starts the session. See the "Wayland session" block below.
              pathsToLink = [
                "/share/applications"
                "/share/icons"
                "/share/pixmaps"
                "/share/sfwbar"
                # GTK themes (adw-gtk3-dark). Sfwbar runs as a systemd user
                # service whose XDG_DATA_DIRS is /run/current-system/sw/share;
                # without this link the adw-gtk3-dark theme is absent there and
                # GTK falls back to the built-in *light* Adwaita. Its popup
                # menus (Start / window-ops / tray) then render light while the
                # panel CSS forces label text white — white-on-light = an
                # unreadable "blank" menu. Linking themes lets the settings.ini
                # gtk-theme-name (adw-gtk3-dark) resolve for GTK3 services.
                "/share/themes"
              ];
              shells = with pkgs; [ bash ];
              variables = {
                EDITOR = "/run/current-system/sw/bin/geany";
                BROWSER = "/run/current-system/sw/bin/firefox";
                TERMINAL = "/run/current-system/sw/bin/foot";
                NIXPKGS_ALLOW_UNFREE = "1";
                SQLITE_TMPDIR = "/tmp";
              };
              # Wayland enforcement + appearance. GDK_BACKEND=wayland removes the
              # X fallback, so any X-only GTK app hard-fails instead of silently
              # spinning up XWayland — the behaviour we want on a Wayland-only box.
              sessionVariables = {
                NIXOS_OZONE_WL = "1";
                GDK_BACKEND = "wayland";
                QT_QPA_PLATFORM = "wayland";
                SDL_VIDEODRIVER = "wayland";
                CLUTTER_BACKEND = "wayland";
                MOZ_ENABLE_WAYLAND = "1";
                XDG_CURRENT_DESKTOP = "labwc";
                # gsettings-desktop-schemas first: unwrapped GTK/libadwaita apps
                # (e.g. image-roll — a bare binary, no wrapGAppsHook) need the
                # org.gnome.* compiled schemas findable on XDG_DATA_DIRS, else
                # GLib's default schema source is NULL and every GSettings
                # lookup logs "g_settings_schema_source_lookup: assertion
                # 'source != NULL' failed".
                XDG_DATA_DIRS = "${gsettingsSchemaDir}:/run/current-system/sw/share";
                XDG_ICON_DIRS = "/run/current-system/sw/share/icons";
                XCURSOR_THEME = "Adwaita";
                XCURSOR_SIZE = "24";
                # Select lxmenu-data's lxde-applications.menu for menu-cache
                # (PCManFM's "Open With" app list). menu-cache reads
                # ''${XDG_MENU_PREFIX}applications.menu from XDG_CONFIG_DIRS/menus,
                # and lxmenu-data installs it as lxde-applications.menu.
                XDG_MENU_PREFIX = "lxde-";
                # NO GTK_THEME here — deliberately. GTK_THEME does NOT only
                # affect GTK3: libadwaita defers to the named theme instead of
                # applying its own color-scheme-aware stylesheet, and since
                # adw-gtk3 ships no gtk-4.0 CSS, GTK4/libadwaita apps then fall
                # back to the default *light* Adwaita (verified with image-roll:
                # light with GTK_THEME set, dark without). GTK3 apps already get
                # adw-gtk3-dark from /etc/xdg/gtk-3.0/settings.ini; GTK4/
                # libadwaita apps get dark from the settings portal
                # (color-scheme=prefer-dark via the locked dconf profile).
                _JAVA_AWT_WM_NONREPARENTING = "1";
              }
              # Pin the VA-API driver when the machine's generation is known.
              # Left unset under "auto" on purpose: libva's own probe tries the
              # candidates in order, and naming one here would defeat that.
              // optionalAttrs (cfg.hardwareVideo == "intel-modern") {
                LIBVA_DRIVER_NAME = "iHD";
              }
              // optionalAttrs (cfg.hardwareVideo == "intel-legacy") {
                LIBVA_DRIVER_NAME = "i965";
              };
              systemPackages =
                with pkgs;
                [
                  # ── Compositor + panel ──
                  labwc
                  nanoLabwcTheme # Adwaita titlebar-button icons for labwc
                  sfwbar

                  # ── Terminal + launcher ──
                  foot
                  fuzzel

                  # ── Browser (Firefox / GNOME Web, WebKitGTK) ──
                  firefox

                  # ── Text editor (GTK3) ──
                  geany

                  # ── File management ──
                  pcmanfm
                  xarchiver
                  file

                  # ── Media / images / documents ──
                  celluloid
                  image-roll
                  atril

                  # ── Notifications ──
                  mako

                  # ── Screenshot / clipboard / lock ──
                  grim
                  slurp
                  wl-clipboard
                  swaylock
                  nano-screenshot

                  # ── Volume / brightness ──
                  # nano-osd services the XF86 media keys (see labwc/rc.xml)
                  # with no resident daemon (replaced swayosd-server, ~43 MB).
                  # alsa-utils supplies amixer (used by nano-osd and, in apulse
                  # mode, the panel volume widget) and alsamixer (the panel
                  # widget's click-to-open mixer). pavucontrol is the full GUI
                  # mixer but needs a running server, so it ships only with
                  # features.audioServer (see the optionals below).
                  nano-osd
                  alsa-utils
                  brightnessctl

                  # ── Network configuration (on demand) ──
                  # Day-to-day wifi lives in the panel's built-in widget
                  # (sfwbar wifi-iwd module — see sfwbar/sfwbar.config).
                  # iwgtk is the escape hatch for what that widget leaves out:
                  # hidden networks, WPS, per-adapter power and diagnostics. It
                  # replaces nm-connection-editor, whose other jobs no longer
                  # exist here — wired is automatic under networkd and VPNs are
                  # declarative. Nothing autostarts (iwgtk ships an indicator
                  # service that stays unused), and iwctl from the iwd package
                  # is the CLI equivalent. Bluetooth management
                  # (blueman-manager) arrives via services.blueman below,
                  # D-Bus activated only when opened.
                  iwgtk

                  # ── System tools ──
                  lxtask
                  galculator
                  which
                  pciutils
                  usbutils

                  # ── Theme / cursor / icons / MIME / XDG ──
                  # adw-gtk3 gives GTK3 apps the libadwaita look; GTK4/libadwaita
                  # apps follow the dark color-scheme directly. Papirus-Dark (in
                  # papirus-icon-theme) supplies the full-colour + symbolic named
                  # icons the labwc menu / Sfwbar panel reference; hicolor carries
                  # each app's own branded icon. adwaita-icon-theme is kept purely
                  # for the Adwaita cursor — Wayland has no server-side default
                  # cursor.
                  adw-gtk3
                  adwaita-icon-theme
                  papirus-icon-theme
                  hicolor-icon-theme
                  # NixOS snowflake (hicolor: nix-snowflake, nix-snowflake-white)
                  # — the Sfwbar Start-button icon. Papirus-Dark has no copy and
                  # inherits breeze-dark/hicolor, so hicolor is what resolves it.
                  nixos-icons
                  shared-mime-info
                  xdg-user-dirs
                  xdg-utils
                  # lxmenu-data ships the freedesktop application menu
                  # (lxde-applications.menu) plus its category .directory files.
                  # PCManFM/libfm's "Open With → Choose an application" dialog
                  # builds its installed-apps list from menu-cache, which reads
                  # this menu; without it the dialog lists nothing. Selected via
                  # XDG_MENU_PREFIX = "lxde-" (see sessionVariables).
                  lxmenu-data

                  # ── Upgrade script ──
                  # Always installed for manual runs; the automatic timer is
                  # gated by features.autoUpgrade.
                  systemUpgradeScript
                ]
                # Clipboard history (Super+V) + unicode/emoji picker (Super+.).
                # cliphist owns the on-disk history and is driven by the
                # wl-paste watcher user service; the pickers are the two scripts
                # from the let block, run from labwc keybinds — see their
                # comments there for the design.
                #
                # The scripts carry their own dependencies through
                # writeShellApplication, so wtype and fuzzel are deliberately
                # NOT listed here: they are implementation details, not commands
                # anyone runs. cliphist is the exception — it is also the
                # management interface for the history it keeps (`cliphist
                # wipe`, `cliphist list`), so it belongs on PATH.
                ++ optionals cfg.features.clipboardHistory [
                  cliphist
                  nano-clipboard
                  nano-unicode
                ]
                # Printer configuration UI
                ++ optionals cfg.features.printing [ system-config-printer ]
                # Full GUI mixer — only useful with a running audio server.
                ++ optionals cfg.features.audioServer [ pavucontrol ]
                # vainfo: the only way to answer "is video actually being
                # decoded on the GPU", which is worth knowing on a machine
                # where the answer decides whether video is watchable at all.
                ++ optionals (cfg.hardwareVideo != "none") [ libva-utils ]
                # ── Office suite ──
                # LibreOffice, AbiWord + Gnumeric, or nothing — see
                # nanoDesktop.officeSuite and officePackages in the let block.
                ++ officePackages
                ++ cfg.extraPackages;
            };

            # ── Filesystems ─────────────────────────────────────────────
            fileSystems."/".noCheck = mkDefault true;

            # ── Fonts (minimal, fast) ───────────────────────────────────
            fonts = {
              enableDefaultPackages = mkForce false;
              fontDir.enable = mkDefault true;
              packages = with pkgs; [
                # Adwaita Sans (Inter-based) + Adwaita Mono (Iosevka-based) are the
                # modern GNOME UI/mono fonts and the global default here. DejaVu /
                # Liberation stay as metric-compatible fallbacks; Noto for emoji.
                adwaita-fonts
                dejavu_fonts
                liberation_ttf
                noto-fonts-color-emoji
              ];
              fontconfig = {
                enable = true;
                defaultFonts = {
                  sansSerif = [
                    "Adwaita Sans"
                    "DejaVu Sans"
                    "Liberation Sans"
                  ];
                  serif = [
                    "DejaVu Serif"
                    "Liberation Serif"
                  ];
                  monospace = [
                    "Adwaita Mono"
                    "DejaVu Sans Mono"
                    "Liberation Mono"
                  ];
                  emoji = [ "Noto Color Emoji" ];
                };
              };
            };

            # ── Power Management ────────────────────────────────────────
            powerManagement = {
              enable = mkDefault true;
              powertop.enable = mkDefault false;
              # Most drives come back from suspend at their firmware default
              # APM level, so the head-parking rule in services.udev.extraRules
              # has to be re-applied by hand — udev sees no add event for a disk
              # that was never removed. Same match as that rule (rotational
              # SATA/PATA disks) and the same best-effort handling; on a machine
              # with no spinning disk the loop matches nothing and costs a
              # couple of stat calls per resume.
              #
              # types.lines, so a host adding its own resumeCommands appends to
              # this rather than replacing it.
              resumeCommands = ''
                for disk in /sys/block/sd[a-z]; do
                  [ -e "$disk/queue/rotational" ] || continue
                  [ "$(cat "$disk/queue/rotational")" = 1 ] || continue
                  ${pkgs.hdparm}/bin/hdparm -q -B 254 "/dev/''${disk##*/}" || true
                done
              '';
            };

            # ── Hardware ────────────────────────────────────────────────
            hardware = {
              bluetooth.enable = mkDefault cfg.features.bluetooth;
              enableRedistributableFirmware = mkDefault true;
              graphics = {
                enable = true;
                # mesa covers AMD and the Gallium paths either way; these add
                # the Intel VA-API driver(s) selected by nanoDesktop.
                # hardwareVideo. The two Intel drivers cover disjoint
                # generations, which is why "auto" ships both and lets libva
                # fall through to whichever initialises.
                extraPackages =
                  with pkgs;
                  [ mesa ]
                  ++ optionals (elem cfg.hardwareVideo [
                    "auto"
                    "intel-modern"
                  ]) [ intel-media-driver ]
                  ++ optionals (elem cfg.hardwareVideo [
                    "auto"
                    "intel-legacy"
                  ]) [ intel-vaapi-driver ];
              };
              sane = {
                enable = mkDefault cfg.features.scanning;
                extraBackends = with pkgs; [
                  sane-airscan
                  sane-backends
                ];
              };
              sensor.iio.enable = mkDefault false;
            };

            # ── Networking ──────────────────────────────────────────────
            # iwd + systemd-networkd, no NetworkManager. iwd is the supplicant
            # (~2.7 MB resident against NetworkManager's ~17 MB, measured with
            # both running) and networkd owns IP configuration for every
            # interface, so one DHCP client covers wired and wireless alike.
            #
            # This is a resident-memory win, not a disk win: the measured
            # closure delta is only about -8 MB, all of it nm-applet's
            # (libdbusmenu-gtk3, ayatana-ido, libnma). NetworkManager itself
            # stays in the store no matter what is set here, because blueman
            # links its GObject typelib for the Bluetooth PAN/DUN plugin — so
            # the ~360 MB closure leaves only if features.bluetooth is off too.
            # The daemon does not run either way, which is the part that counts.
            #
            # networking.useDHCP — on by default, left alone here — is what
            # makes this work with no per-interface configuration: under
            # useNetworkd it expands to the generic 99-ethernet-default-dhcp and
            # 99-wireless-client-dhcp units, which match on interface *type*
            # rather than name (so nothing here needs to know this laptop calls
            # its port enp0s25) and give wifi a higher route metric, so a
            # plugged-in cable wins automatically.
            #
            # The trade, stated plainly. networkd pulls systemd-resolved in with
            # it — NixOS defaults resolved on whenever networkd is enabled, and
            # networkd has no other way to publish DHCP-supplied nameservers —
            # so the resident saving is smaller than the 17 MB above buys you; a
            # caching stub resolver is what you get for the difference. And iwd
            # is 802.11 only: this stack has no VPN plugins, no ModemManager /
            # WWAN, no captive-portal detection and no connection sharing. VPNs
            # become declarative (networking.wireguard and friends) instead of a
            # GUI. A machine that needs any of those — or a card whose driver
            # only ever behaved under wpa_supplicant, older Intel parts with
            # fragile firmware being the usual suspects — should set
            # networking.networkmanager.enable = true alongside
            # networking.useNetworkd = false and wireless.iwd.enable = false.
            #
            # Saved networks live in iwd's own store (/var/lib/iwd) rather than
            # NM's connection store, so a machine migrating off the
            # NetworkManager stack re-enters wifi passphrases once.
            networking = {
              hostName = cfg.hostName;
              networkmanager.enable = mkDefault false;
              wireless.iwd = {
                enable = mkDefault true;
                settings = {
                  # Both are iwd's own defaults; spelled out because the split
                  # of responsibilities is the whole point of this stack.
                  # networkd does addressing, iwd stays a pure supplicant.
                  General.EnableNetworkConfiguration = false;
                  Settings.AutoConnect = true;
                };
              };
              useNetworkd = mkDefault true;
              firewall = {
                enable = mkDefault false;
                allowedTCPPorts = [
                  7236
                  7250
                ];
                allowedUDPPorts = [
                  7236
                  5353
                ];
              };
            };

            # Release network-online.target as soon as *one* interface is up.
            # The upgrade timer below waits on that target, and the default
            # (every managed link must be online) means an unplugged ethernet
            # port on a laptop running fine over wifi holds it until
            # systemd-networkd-wait-online gives up on its timeout.
            systemd.network.wait-online.anyInterface = mkDefault true;

            # ── Nix Configuration ───────────────────────────────────────
            nix = {
              gc = {
                automatic = mkDefault true;
                dates = mkDefault "weekly";
                options = mkDefault "--delete-older-than 7d";
              };
              settings = {
                # Left on under both diskTypes, which is worth stating because
                # the hard-linking pass is random I/O and a platter is where
                # random I/O hurts. It stays because an "hdd" install has no
                # f2fs compression underneath it and so carries a materially
                # larger store — the setting that costs the most there is also
                # the one that saves the most there.
                auto-optimise-store = true;
                experimental-features = [
                  "nix-command"
                  "flakes"
                  "cgroups"
                ];
                # Nix substitutes up to 16 paths at once by default: sixteen
                # concurrent downloads, each feeding a zstd decompression and a
                # write into the store. On four cores and 4 GB that is not
                # throughput, it is a stampede — it is what pinned this laptop
                # for forty minutes fetching one large package (see "Resource
                # guards"). Four keeps a home link saturated without it.
                max-substitution-jobs = mkDefault 4;
                substituters = [
                  "https://cache.nixos.org?priority=40"
                ];
                trusted-public-keys = [
                  "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
                ];
                trusted-users = [
                  "root"
                  cfg.username
                  "@wheel"
                ];
                use-cgroups = true;
                use-xdg-base-directories = true;
              };
            };

            # ── Resource guards ─────────────────────────────────────────
            # Why this section exists, concretely: a single `nix build` that
            # substituted LibreOffice (1.5 GB unpacked) locked this 4 GB laptop
            # up for forty minutes. Input events arrived 20 seconds late,
            # journald could not write, and nothing was ever OOM-killed.
            #
            # Nothing was killed because nothing looked out of memory. Swap
            # stayed 98% free throughout — the pressure was not anonymous
            # pages. nix-daemon peaked at 944 MB while the kernel evicted
            # file-backed pages to make room, which on this machine means
            # everybody's executables and the store itself, and then had to
            # fault them straight back in. Its cgroup scanned ten million pages
            # doing it. The kernel counts that memory as reclaimable, so the
            # OOM killer never has grounds to fire and the machine just
            # thrashes. PSI for that boot: 20 minutes of memory stall, 13 of
            # them with nothing runnable at all, plus 36 minutes of I/O stall.
            #
            # That is also why there is no earlyoom here. A free-memory
            # watchdog cannot see this: memory and swap both read healthy right
            # through it. The guards are pressure- and cgroup-based instead,
            # and they are aimed at the offender rather than the victim.
            systemd.services.nix-daemon.serviceConfig = {
              # A ceiling nix reclaims against *inside its own cgroup*, page
              # cache included — which is the whole point, since page cache is
              # what it was taking. MemoryHigh throttles, it does not kill: a
              # big build or a big download simply goes slower, and no
              # derivation fails because of it. nix.settings.use-cgroups above
              # puts each build in a child cgroup, so the ceiling covers builds
              # and substitutions alike. 40% is ~1.5 GB here, comfortably above
              # the 944 MB an ordinary large fetch peaked at.
              MemoryHigh = mkDefault "40%";
              # Interactive work wins the CPU when nix is busy.
              CPUWeight = mkDefault 50;
              # Backstop, deliberately scoped to this one unit. systemd-oomd is
              # already running (NixOS enables it) but polices nothing by
              # default: every slice ships ManagedOOM*=auto and `oomctl`
              # reports zero monitored cgroups. Setting it here — rather than
              # via systemd.oomd.enableUserSlices — is what makes it safe on
              # this desktop, where labwc lives in the logind session scope and
              # apps started from the panel inherit sfwbar's cgroup: policing
              # the user slices would let oomd answer a nix storm by killing
              # the panel, the editor, or the whole session. This way the only
              # thing it can kill is the daemon that caused the pressure, and
              # nix-daemon is socket-activated, so it comes straight back.
              #
              # The cost is real and worth stating: this can kill a legitimate
              # local build of something enormous, which is why the threshold
              # is 80% rather than oomd's 60% default. At 80% of wall-clock
              # time stalled on memory for thirty seconds straight, the build
              # was not going to finish in any useful time anyway, and the
              # machine it is running on is unusable while it tries. The
              # upgrade timer's Restart=on-failure picks it up again.
              ManagedOOMMemoryPressure = mkDefault "kill";
              ManagedOOMMemoryPressureLimit = mkDefault "80%";
            };

            # ── nixpkgs ─────────────────────────────────────────────────
            nixpkgs.config = {
              allowBroken = true;
              allowUnfree = true;
              allowUnfreePredicate = _: true;
            };
            # When the audio server is off (features.audioServer), point
            # Firefox's PulseAudio client at apulse/pressureaudio: libpulse
            # implemented over pure ALSA, no daemon. Firefox is the one app here
            # with no ALSA fallback — Mozilla dropped ALSA output in 2017, which
            # is pressureaudio's whole reason to exist. Every other PulseAudio
            # client in the set (mpv/Celluloid, libcanberra, …) falls back to
            # ALSA on its own once no server answers, so they need no override.
            #
            # This is deliberately scoped to the Firefox *wrapper* rather than a
            # global `libpulseaudio = libpressureaudio`. A global swap makes
            # libpulseaudio a permanent cache-miss and drags 200+ packages —
            # including firefox-unwrapped (via roc-toolkit → pipewire), gstreamer
            # and SDL — into a local-from-source rebuild on every nixpkgs bump,
            # which would cost far more resources than dropping the daemon saves.
            # Scoping it here rebuilds only the tiny wrapper; firefox-unwrapped
            # and the pipewire/gst closure stay on the binary cache.
            #
            # prev.libpressureaudio (no global override in play) builds against
            # the real prev.libpulseaudio, so there is no src = self.src cycle.
            #
            # libpulseaudio is an outer callPackage arg of the Firefox wrapper,
            # not an inner override knob, so `firefox.override { libpulseaudio }`
            # fails. Instead override wrapFirefox (the callPackage'd wrapper) and
            # re-wrap the same firefox-unwrapped — mirrors nixpkgs' own
            # `firefox = wrapFirefox firefox-unwrapped { }` and rebuilds just the
            # wrapper, leaving firefox-unwrapped on the binary cache.
            nixpkgs.overlays = mkIf (!cfg.features.audioServer) [
              (final: prev: {
                firefox =
                  (prev.wrapFirefox.override { libpulseaudio = prev.libpressureaudio; }) prev.firefox-unwrapped
                    { };
              })
            ];

            # ── Programs ────────────────────────────────────────────────
            programs = {
              # dconf/GSettings backend — GNOME apps need it to
              # persist settings. It is also the authoritative
              # source of the modern-Adwaita-dark look for GNOME/libadwaita apps:
              # a locked system-wide profile pins the dark color-scheme, adw-gtk3
              # GTK3 theme, Papirus-Dark icons, Adwaita cursor and Adwaita Sans/Mono
              # fonts. lockAll enforces Nano's "global default, no user config"
              # model — users cannot override these keys.
              dconf = {
                enable = mkDefault true;
                profiles.user.databases = [
                  {
                    lockAll = true;
                    settings."org/gnome/desktop/interface" = {
                      color-scheme = "prefer-dark";
                      gtk-theme = "adw-gtk3-dark";
                      icon-theme = "Papirus-Dark";
                      cursor-theme = "Adwaita";
                      cursor-size = lib.gvariant.mkInt32 24;
                      font-name = "Adwaita Sans 11";
                      document-font-name = "Adwaita Sans 11";
                      monospace-font-name = "Adwaita Mono 11";
                    };
                  }
                ];
              };
              git = {
                enable = true;
                config.safe.directory = [ "/etc/nixos" ];
              };
              nix-ld = {
                enable = mkDefault true;
                package = pkgs.nix-ld;
                libraries = with pkgs; [
                  glib
                  libxkbcommon
                  openssl
                  zstd
                ];
              };
            };

            # ── Services ────────────────────────────────────────────────
            services = {
              # AccountsService has no consumer in this stack (no GDM / GNOME
              # Settings) — it only idled as a resident daemon. Off statically.
              accounts-daemon.enable = mkDefault false;
              # Per-application nice / ionice / cgroup / scheduling policy from
              # the CachyOS rule set, gated on features.processScheduling
              # (off by default — see the option).
              ananicy = {
                enable = mkDefault cfg.features.processScheduling;
                package = mkDefault pkgs.ananicy-cpp;
                rulesProvider = mkDefault pkgs.ananicy-rules-cachyos;
              };
              avahi = {
                enable = mkDefault cfg.features.networkDiscovery;
                nssmdns4 = mkDefault true;
                nssmdns6 = mkDefault true;
                # Resolve, don't advertise. Everything this desktop actually
                # wants from mDNS is on the query side: .local name resolution
                # (nssmdns above) and the printer/scanner browsing that
                # system-config-printer and sane-airscan do at add time.
                # Publishing is the other direction — announcing this host and
                # its addresses to the segment — which nothing here consumes,
                # and which costs periodic multicast on an otherwise idle wifi
                # link (radio wakeups on battery) plus a standing description of
                # the machine to anyone on the network. Flip publish.enable back
                # on for a workstation that other hosts need to find by name.
                publish.enable = mkDefault false;
              };
              # Installs blueman-manager (app menu) + the blueman D-Bus
              # services. Nothing autostarts: the panel's bluez widget covers
              # status/pairing, and opening blueman-manager D-Bus-activates
              # what it needs on demand (org.blueman.Applet/.Manager both ship
              # activation files).
              blueman.enable = mkDefault cfg.features.bluetooth;
              bpftune.enable = mkDefault false;
              dbus = {
                implementation = mkDefault "broker";
                packages = with pkgs; [ ];
              };
              # Flash only — there is nothing to trim on a platter, and this
              # module is otherwise careful about periodic wakeups it cannot
              # justify. Note it is also the reason the swap partition carries
              # discardPolicy = "once" under diskType = "ssd": fstrim walks
              # mounted filesystems and never sees a swap partition.
              fstrim = {
                enable = mkDefault (cfg.diskType == "ssd");
                interval = mkDefault "daily";
              };
              gvfs = {
                enable = mkDefault cfg.features.virtualFilesystems;
                package = mkDefault pkgs.gnome.gvfs;
              };
              # Bound the journal. journald's default SystemMaxUse is 10% of the
              # filesystem (up to 4 GB), which is the single largest resource
              # this desktop consumes on a small disk — measured at 256 MB of
              # mostly-stale archived boots on a laptop that had been up for
              # days. Storage stays persistent (crash forensics across a reboot
              # is worth more than the space, and volatile journals also fill
              # tmpfs, i.e. RAM); the caps just stop it drifting. 16 MB files
              # keep rotation granular enough that the cap evicts in useful
              # increments instead of dropping one huge file at a time.
              #
              # mkDefault on a lines-typed option is wholesale, not per-line: a
              # host that sets services.journald.extraConfig at normal priority
              # replaces this block entirely rather than appending to it, so
              # such a host has to restate any cap it still wants.
              journald.extraConfig = mkDefault ''
                SystemMaxUse=64M
                SystemMaxFileSize=16M
              '';
              # PipeWire + WirePlumber, gated on features.audioServer. When off,
              # the whole server (and rtkit below) is gone and audio goes through
              # apulse/pressureaudio over ALSA instead (see the nixpkgs overlay
              # and the audioServer option). alsa/pulse compat only matter when
              # the server is actually running.
              pipewire = {
                enable = mkDefault cfg.features.audioServer;
                alsa.enable = mkDefault true;
                pulse.enable = mkDefault true;
              };
              # power-profiles-daemon has no consumer in this stack: there is no
              # GNOME Settings, and the panel exposes no power-profile widget,
              # so nothing ever calls org.freedesktop.UPower.PowerProfiles. It
              # is D-Bus activated, so leaving it on cost no resident memory —
              # only closure — but a daemon nothing can reach is not a feature.
              # Enable it alongside a UI that drives it.
              power-profiles-daemon.enable = mkDefault false;
              printing = {
                enable = mkDefault cfg.features.printing;
                # cups-browsed idled ~17 MB resident and its event
                # subscriptions kept cupsd itself permanently awake (~18 MB
                # more). Without it cupsd stays socket-activated (below) and
                # printers are added once via system-config-printer, which
                # still discovers network printers at add time. Turn browsed
                # back on only if you want remote queues to appear in print
                # dialogs automatically.
                browsed.enable = mkDefault false;
                # Only start cupsd when something actually talks to it.
                startWhenNeeded = mkDefault true;
                webInterface = mkDefault false;
              };
              # Intel thermal daemon (features.thermalManagement) — steers away
              # from the throttle spiral that tired laptop cooling falls into.
              # Exits on non-Intel, so turn the feature off there.
              thermald.enable = mkDefault cfg.features.thermalManagement;
              tumbler.enable = mkDefault cfg.features.thumbnails;
              # brightnessctl udev rules so the video group can set backlight
              # (and nano-osd's brightness keys work without root).
              udev.packages = with pkgs; [ brightnessctl ];
              # Block-layer tuning, per device class. This is the runtime half
              # of the storage story whose eval-time half is nanoDesktop.
              # diskType: everything here keys off the kernel's own
              # queue/rotational flag rather than the option, so it is also
              # correct for a second or external drive of the other kind, and
              # stays correct on a machine whose diskType is set wrong. The
              # kernel's own default is mq-deadline for everything, which is
              # the wrong answer at both ends of the range this desktop runs on.
              #
              # The two queue-attribute rules deliberately do not restrict
              # KERNEL=: a partition has no queue/ directory at all, so it
              # simply fails the match, and dropping the old sd[a-z] pattern
              # picks up sdaa+, USB and virtio disks it silently missed. The
              # hdparm rule below does keep the pattern, because that one is
              # sending an ATA command rather than writing a sysfs attribute.
              udev.extraRules = ''
                # NVMe reorders in hardware across deep queues; a software
                # scheduler in front of it is pure overhead.
                ACTION=="add|change", SUBSYSTEM=="block", KERNEL=="nvme[0-9]n[0-9]", ATTR{queue/scheduler}="none"
                # Spinning disks get BFQ, the one scheduler that will hold a
                # background writer off the head long enough for an interactive
                # read to land — the difference between "the machine is copying
                # a file" and "the machine is unusable until it finishes". It
                # also gives systemd's IOWeight= something to act on: io.weight
                # is a no-op under mq-deadline, which is why the nix-daemon
                # guard under "Resource guards" leans on MemoryHigh instead.
                ACTION=="add|change", SUBSYSTEM=="block", ATTR{queue/rotational}=="1", ATTR{queue/scheduler}="bfq"
                # Readahead, up from the 128 KB default. A platter charges the
                # same seek whether it then reads 128 KB or 1 MB, so the larger
                # window is close to free on the sequential reads that dominate
                # startup and file copies. It is a ceiling and not a floor:
                # Linux readahead is adaptive and only ramps to it once it has
                # actually detected a sequential pattern, so random small reads
                # do not start paying for page cache they will not use.
                ACTION=="add|change", SUBSYSTEM=="block", ATTR{queue/rotational}=="1", ATTR{bdi/read_ahead_kb}="1024"
                # Stop the heads parking. Laptop drives of this vintage ship
                # with APM aggressive enough to unload after a few seconds idle;
                # every read after that pays a ~1s load, and each cycle spends
                # one of a rated ~600k — which drives have exhausted inside a
                # year on Linux, since the desktop wakes the disk far more often
                # than the firmware's idle heuristic assumes. 254 is maximum
                # performance with APM still enabled (255 disables it outright,
                # which some firmware handles badly). The cost is real: no
                # automatic head unload means measurably more idle power, so
                # this is a laptop trading battery for the disk's lifetime and
                # for latency it would otherwise pay on every idle read.
                #
                # -q because drives and USB bridges that do not implement APM
                # answer with an error, and this is best-effort by nature.
                ACTION=="add", SUBSYSTEM=="block", ENV{DEVTYPE}=="disk", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="1", RUN+="${pkgs.hdparm}/bin/hdparm -q -B 254 /dev/%k"
              '';
              udisks2.enable = mkDefault true;
              upower.enable = mkDefault true;
            };

            # ── SSH ─────────────────────────────────────────────────────
            services.openssh = mkIf cfg.enableSsh {
              enable = true;
              settings = {
                PermitRootLogin = cfg.sshRootLogin;
                PasswordAuthentication = cfg.sshPasswordAuth;
              };
            };

            # ── Security ────────────────────────────────────────────────
            security = {
              # swaylock needs a PAM service to authenticate the unlock.
              pam.services.swaylock = { };
              # PAM service for the nano-desktop tty1 unit. systemd opens only the
              # account + session phases here (no auth prompt — the service already
              # runs as the user), and startSession registers a logind session via
              # pam_systemd, giving labwc its seat, VT and XDG_RUNTIME_DIR.
              pam.services.nano-desktop.startSession = true;
              polkit = {
                enable = mkDefault true;
                enablePkexecWrapper = mkDefault true;
              };
              # RealtimeKit hands out RT scheduling to the PipeWire server; with
              # no server (features.audioServer off) nothing uses it.
              rtkit.enable = mkDefault cfg.features.audioServer;
              tpm2.enable = mkDefault false;
            };

            # ── Wayland session ─────────────────────────────────────────
            # No display-server / greeter: the nano-desktop system service (below)
            # owns tty1 and starts labwc as the user via a logind (pam_systemd)
            # session — the seat/DRM/XDG_RUNTIME_DIR setup a Wayland compositor
            # needs. labwc natively imports the runtime session env
            # (WAYLAND_DISPLAY, DISPLAY, XDG_CURRENT_DESKTOP, XDG_SESSION_TYPE,
            # XCURSOR_*) into D-Bus + the systemd user manager at startup, then
            # the launcher's `-s` flag starts nano-session.target, which BindsTo
            # graphical-session.target (the sway-session.target pattern): it
            # pulls in the helper user services below and tears them down
            # cleanly when labwc exits.
            systemd.user.targets.nano-session = {
              description = "Nano desktop session";
              documentation = [ "man:systemd.special(7)" ];
              bindsTo = [ "graphical-session.target" ];
              wants = [ "graphical-session-pre.target" ];
              after = [ "graphical-session-pre.target" ];
            };

            # Static session environment for ALL systemd user units, declared
            # once ([Manager] DefaultEnvironment in /etc/systemd/user.conf).
            # This is what the appmenu/`Open With` discovery needs
            # (XDG_DATA_DIRS/XDG_CONFIG_DIRS/XDG_MENU_PREFIX) plus theme vars.
            # %u/%h are systemd specifiers (user/home) — $VARS do NOT expand
            # here, and values must not contain spaces. PATH listed here covers
            # *packaged* units (portals, xdg-user-dirs, blueman's upstream
            # unit); NixOS-generated services get an injected Environment=PATH
            # that shadows it, which the session services' `path` option below
            # corrects. Runtime vars (WAYLAND_DISPLAY, DISPLAY) are pushed by
            # labwc itself and deliberately absent here.
            # No GTK_THEME here (breaks libadwaita dark — see sessionVariables);
            # GTK3 services read /etc/xdg/gtk-3.0/settings.ini via
            # XDG_CONFIG_DIRS instead. GIO_EXTRA_MODULES loads the dconf GIO
            # backend (so service-launched GSettings apps actually see the
            # locked dconf profile — color-scheme, fonts — rather than silently
            # falling back to a keyfile) and the gvfs module (trash/mtp/network
            # in pcmanfm).
            systemd.user.settings.Manager.DefaultEnvironment = toString [
              "XDG_CURRENT_DESKTOP=labwc"
              "XDG_DATA_DIRS=${gsettingsSchemaDir}:/run/current-system/sw/share:%h/.nix-profile/share:%h/.local/state/nix/profile/share:/etc/profiles/per-user/%u/share:/nix/var/nix/profiles/default/share"
              "XDG_CONFIG_DIRS=/etc/xdg:%h/.nix-profile/etc/xdg:%h/.local/state/nix/profile/etc/xdg:/etc/profiles/per-user/%u/etc/xdg:/nix/var/nix/profiles/default/etc/xdg:/run/current-system/sw/etc/xdg"
              "XDG_MENU_PREFIX=lxde-"
              "XDG_ICON_DIRS=/run/current-system/sw/share/icons"
              "GIO_EXTRA_MODULES=${pkgs.dconf.lib}/lib/gio/modules:${config.services.gvfs.package}/lib/gio/modules"
              "PATH=/run/wrappers/bin:/etc/profiles/per-user/%u/bin:/nix/var/nix/profiles/default/bin:/run/current-system/sw/bin"
            ];

            # xdg-user-dirs ships a packaged oneshot user unit
            # (Before=graphical-session-pre.target) that creates the standard
            # XDG user directories (~/Documents, ~/Downloads, ~/Pictures, …) and
            # ~/.config/user-dirs.dirs. systemd.packages links the unit; NixOS
            # does not process packaged [Install] sections, so the wants link is
            # added under systemd.user.services below. Ordering guarantees the
            # dirs exist before the panel/session helpers start.
            systemd.packages = [ pkgs.xdg-user-dirs ];

            # Panel / notification / input-method helpers as systemd user
            # services bound to graphical-session.target: restart-on-crash,
            # ordering and clean teardown (vs the old `& … kill 0` juggling).
            # Network, bluetooth and volume status live inside sfwbar's own
            # modules (wifi-iwd / bluez / volume — pulse or amixer per
            # features.audioServer, see sfwbar/sfwbar.config), so no tray
            # applets autostart: the old nm-applet + blueman
            # applet/tray trio cost ~150 MB of resident memory for what the
            # already-running panel now does itself. The SNI tray stays for
            # user-launched apps that ship status icons.
            systemd.user.services =
              let
                sessionDefaults = {
                  partOf = [ "graphical-session.target" ];
                  after = [ "graphical-session.target" ];
                  wantedBy = [ "graphical-session.target" ];
                  # NixOS injects a minimal Environment=PATH (coreutils & co.)
                  # into every generated service, shadowing both the user
                  # manager's PATH and DefaultEnvironment. That breaks more than
                  # launching: GLib's GDesktopAppInfo REJECTS any .desktop file
                  # whose Exec= binary is not findable in $PATH, so sfwbar's
                  # appmenu (and pcmanfm's "Open With" list in apps spawned from
                  # the bar) enumerate NOTHING under the stripped PATH. Putting
                  # the wrappers + system profile first fixes discovery and
                  # launching in one stroke ("path" strings render as <dir>/bin,
                  # prepended to the injected default).
                  path = [
                    "/run/wrappers"
                    "/run/current-system/sw"
                  ];
                  # Never bounce the visible session on nixos-rebuild switch
                  # (switch-to-configuration honors this for user units): the
                  # running session keeps its current binaries; new versions
                  # apply at the next session restart / reboot.
                  restartIfChanged = false;
                };
                sessionService =
                  description: exec:
                  sessionDefaults
                  // {
                    inherit description;
                    serviceConfig = {
                      ExecStart = exec;
                      Restart = "on-failure";
                      RestartSec = 1;
                    };
                  };
              in
              {
                sfwbar = sessionService "Sfwbar panel" "${pkgs.sfwbar}/bin/sfwbar -f /etc/xdg/sfwbar/sfwbar.config";
                mako = sessionService "Mako notification daemon" "${pkgs.mako}/bin/mako --config /etc/xdg/mako/config";
                # The only resident half of the clipboard feature: wl-paste
                # watches the selection through ext-/wlr-data-control and hands
                # each new entry to cliphist, which appends it to a small
                # on-disk store under $XDG_CACHE_HOME. The pickers (Super+V,
                # Super+.) are keybind-invoked scripts, so between keypresses
                # this watcher is all that is running — around 1-2 MB, against
                # the ~20 MB PSS of the fcitx5 daemon it replaces.
                #
                # --type text on purpose: fcitx5's clipboard addon was
                # text-only too (an input method can only commit text), and
                # without the filter every screenshot copied to the clipboard
                # would be written into the history store at full size.
                #
                # wl-paste exits when the compositor goes away, and Restart plus
                # partOf=graphical-session.target (sessionDefaults) bring it back
                # with the next session rather than leaving a dead watcher.
                cliphist-store = mkIf cfg.features.clipboardHistory (
                  sessionService "Clipboard history watcher (cliphist)" "${pkgs.wl-clipboard}/bin/wl-paste --type text --watch ${pkgs.cliphist}/bin/cliphist store"
                );
                # Wire the packaged xdg-user-dirs oneshot (see systemd.packages
                # above) into the session: NixOS ignores packaged [Install]
                # sections, so declare the wants link here. Runs Before=
                # graphical-session-pre.target, i.e. before the helpers above.
                xdg-user-dirs.wantedBy = [ "graphical-session-pre.target" ];
              };

            # ── Puppy-style desktop service: boot straight to labwc on tty1 ──
            # A dedicated systemd service (modelled on nixos-install-helper's
            # install service + NixOS's own services.cage) replaces getty +
            # login-shell autostart: findable (`systemctl status nano-desktop`),
            # journal-logged, with proper process/lifecycle management. It claims
            # tty1 by conflicting getty@tty1, runs labwc as the user through a
            # pam_systemd session (PAMName below → seat0, XDG_RUNTIME_DIR, DRM
            # master), and relaunches on exit (Restart=always) for the always-on
            # desktop. No getty autologin anywhere: tty2…6 keep normal logins.
            #
            # getty@tty1 is additionally MASKED (autovt@tty1 is its alias):
            # switch-to-configuration re-starts every active target on every
            # switch, and getty.target carries Wants=autovt@tty1.service when no
            # display manager is enabled — un-masked, each `nixos-rebuild switch`
            # would start getty@tty1, whose Conflicts= tears down the whole
            # running desktop session (~50 s outage + races that left helpers
            # dead). Wants= on a masked unit is a harmless no-op, and the
            # Conflicts= below stays as belt-and-braces for first boot.
            systemd.units."getty@tty1.service".enable = false;
            systemd.units."autovt@tty1.service".enable = false;
            systemd.services.nano-desktop = {
              description = "Nano Desktop (labwc Wayland session on tty1)";
              after = [
                "systemd-user-sessions.service"
                "plymouth-quit-wait.service"
                "getty@tty1.service"
              ];
              wants = [ "dbus.socket" ];
              wantedBy = [ "multi-user.target" ];
              conflicts = [ "getty@tty1.service" ];
              restartIfChanged = false;
              unitConfig.ConditionPathExists = "/dev/tty1";
              serviceConfig = {
                ExecStart = nanoDesktopLauncher;
                User = cfg.username;
                Restart = "always";
                RestartSec = 1;
                IgnoreSIGPIPE = "no";
                # Log the user with utmp (w/who), since we replace (a)getty.
                UtmpIdentifier = "%n";
                UtmpMode = "user";
                # Own the virtual terminal; fail if it can't be controlled.
                TTYPath = "/dev/tty1";
                TTYReset = "yes";
                TTYVHangup = "yes";
                TTYVTDisallocate = "yes";
                StandardInput = "tty-fail";
                StandardOutput = "journal";
                StandardError = "journal";
                # Full logind user session (seat/DRM/XDG_RUNTIME_DIR), required to
                # run a Wayland compositor from a system service.
                PAMName = "nano-desktop";
              };
            };

            # ── Automatic background upgrades ───────────────────────────
            # Daily (was hourly — a full flake eval transiently costs hundreds
            # of MB, which matters on small-RAM machines): refresh the flake
            # inputs and `nixos-rebuild switch` (via systemUpgradeScript). A
            # root oneshot, gated only on network-online.target. There used to
            # be a metered-connection check here (nmcli GENERAL.METERED); it
            # went with NetworkManager, and it was already inert — nothing in
            # this desktop could ever set the flag once nm-applet was dropped,
            # so NM only ever reported "no (guessed)". Neither iwd nor networkd
            # has the concept at all. Mirrors the micro desktop. NixOS's own
            # system.autoUpgrade stays
            # off (below) — this timer is the mechanism, and features.autoUpgrade
            # is the switch (the manual system-upgrade command always works).
            # The live session keeps its binaries (session user services carry
            # restartIfChanged=false), so an upgrade never pulls the desktop out
            # from under the user mid-session; session updates land on next login.
            systemd.services.system-upgrade = mkIf cfg.features.autoUpgrade {
              restartIfChanged = false;
              unitConfig = {
                Description = "Update flake inputs and switch NixOS configuration";
                StartLimitIntervalSec = 300;
                StartLimitBurst = 5;
              };
              serviceConfig = {
                Type = "oneshot";
                User = "root";
                Environment = "HOME=/root";
                ExecStart = lib.getExe systemUpgradeScript;
                Restart = "on-failure";
                RestartSec = "120s";
                # The same guards as nix-daemon, for the same reason and then
                # some: this is the one thing on the machine that runs a full
                # flake eval (hundreds of MB) and a rebuild unattended, on a
                # timer, while someone is presumably in the middle of using the
                # desktop. It should always be the process that yields. The
                # eval and the rebuild driver run here; the fetching and
                # building they trigger runs in nix-daemon, under its own
                # ceiling. See "Resource guards" above.
                MemoryHigh = mkDefault "25%";
                CPUWeight = mkDefault 20;
                Nice = mkDefault 19;
              };
              wants = [ "network-online.target" ];
              after = [ "network-online.target" ];
              path = with pkgs; [
                nix
                git
              ];
            };

            systemd.timers.system-upgrade = mkIf cfg.features.autoUpgrade {
              wantedBy = [ "timers.target" ];
              timerConfig = {
                OnCalendar = "daily";
                Persistent = true;
                Unit = "system-upgrade.service";
              };
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

            # ── XDG ─────────────────────────────────────────────────────
            xdg = {
              autostart.enable = mkDefault true;
              icons.enable = mkDefault true;
              menus.enable = mkDefault true;
              mime = {
                enable = mkDefault true;
                # officeMimeApps is merged in at the end: empty unless
                # officeSuite selects a suite, and it overlaps nothing in the
                # fixed set below — application/pdf in particular stays with
                # atril, which LibreOffice Draw would otherwise claim.
                defaultApplications = {
                  # Web → Firefox
                  "text/html" = "firefox.desktop";
                  "application/xhtml+xml" = "firefox.desktop";
                  "x-scheme-handler/http" = "firefox.desktop";
                  "x-scheme-handler/https" = "firefox.desktop";
                  # Plain text / code → Geany
                  "text/plain" = "geany.desktop";
                  "text/x-chdr" = "geany.desktop";
                  "text/x-csrc" = "geany.desktop";
                  "text/x-c++hdr" = "geany.desktop";
                  "text/x-c++src" = "geany.desktop";
                  "text/x-java" = "geany.desktop";
                  "text/x-pascal" = "geany.desktop";
                  "text/x-perl" = "geany.desktop";
                  "text/x-python" = "geany.desktop";
                  "text/css" = "geany.desktop";
                  "text/x-diff" = "geany.desktop";
                  # Images → image-roll
                  "image/png" = "com.github.weclaw1.ImageRoll.desktop";
                  "image/x-png" = "com.github.weclaw1.ImageRoll.desktop";
                  "image/jpeg" = "com.github.weclaw1.ImageRoll.desktop";
                  "image/jpg" = "com.github.weclaw1.ImageRoll.desktop";
                  "image/gif" = "com.github.weclaw1.ImageRoll.desktop";
                  "image/bmp" = "com.github.weclaw1.ImageRoll.desktop";
                  "image/x-bmp" = "com.github.weclaw1.ImageRoll.desktop";
                  "image/svg+xml" = "com.github.weclaw1.ImageRoll.desktop";
                  "image/webp" = "com.github.weclaw1.ImageRoll.desktop";
                  "image/tiff" = "com.github.weclaw1.ImageRoll.desktop";
                  "image/avif" = "com.github.weclaw1.ImageRoll.desktop";
                  "image/heif" = "com.github.weclaw1.ImageRoll.desktop";
                  "image/jxl" = "com.github.weclaw1.ImageRoll.desktop";
                  # Audio → celluloid
                  "audio/mpeg" = "io.github.celluloid_player.Celluloid.desktop";
                  "audio/mp3" = "io.github.celluloid_player.Celluloid.desktop";
                  "audio/ogg" = "io.github.celluloid_player.Celluloid.desktop";
                  "audio/x-ogg" = "io.github.celluloid_player.Celluloid.desktop";
                  "audio/vorbis" = "io.github.celluloid_player.Celluloid.desktop";
                  "audio/flac" = "io.github.celluloid_player.Celluloid.desktop";
                  "audio/x-flac" = "io.github.celluloid_player.Celluloid.desktop";
                  "audio/wav" = "io.github.celluloid_player.Celluloid.desktop";
                  "audio/x-wav" = "io.github.celluloid_player.Celluloid.desktop";
                  "audio/aac" = "io.github.celluloid_player.Celluloid.desktop";
                  "audio/mp4" = "io.github.celluloid_player.Celluloid.desktop";
                  "audio/x-m4a" = "io.github.celluloid_player.Celluloid.desktop";
                  "audio/opus" = "io.github.celluloid_player.Celluloid.desktop";
                  # Video → celluloid
                  "video/mp4" = "io.github.celluloid_player.Celluloid.desktop";
                  "video/x-matroska" = "io.github.celluloid_player.Celluloid.desktop";
                  "video/webm" = "io.github.celluloid_player.Celluloid.desktop";
                  "video/ogg" = "io.github.celluloid_player.Celluloid.desktop";
                  "video/mpeg" = "io.github.celluloid_player.Celluloid.desktop";
                  "video/quicktime" = "io.github.celluloid_player.Celluloid.desktop";
                  "video/x-msvideo" = "io.github.celluloid_player.Celluloid.desktop";
                  "video/x-flv" = "io.github.celluloid_player.Celluloid.desktop";
                  "video/x-ms-wmv" = "io.github.celluloid_player.Celluloid.desktop";
                  "video/3gpp" = "io.github.celluloid_player.Celluloid.desktop";
                  "video/3gpp2" = "io.github.celluloid_player.Celluloid.desktop";
                  "video/x-ogm+ogg" = "io.github.celluloid_player.Celluloid.desktop";
                  # Documents / comics → atril
                  "application/pdf" = "atril.desktop";
                  "application/epub+zip" = "atril.desktop";
                  "application/postscript" = "atril.desktop";
                  "image/vnd.djvu" = "atril.desktop";
                  "application/x-cbr" = "atril.desktop";
                  "application/x-cbz" = "atril.desktop";
                  "application/x-cb7" = "atril.desktop";
                  "application/x-cbt" = "atril.desktop";
                  # Archives → Xarchiver
                  "application/zip" = "xarchiver.desktop";
                  "application/x-tar" = "xarchiver.desktop";
                  "application/x-7z-compressed" = "xarchiver.desktop";
                  "application/vnd.rar" = "xarchiver.desktop";
                  "application/x-rar" = "xarchiver.desktop";
                  "application/gzip" = "xarchiver.desktop";
                  "application/x-bzip2" = "xarchiver.desktop";
                  "application/x-bzip-compressed-tar" = "xarchiver.desktop";
                  "application/x-compressed-tar" = "xarchiver.desktop";
                  "application/x-xz" = "xarchiver.desktop";
                  # Directories → PCManFM
                  "inode/directory" = "pcmanfm.desktop";
                }
                // officeMimeApps;
              };
              # Off by default on this lite target (features.desktopPortal) —
              # the native paths cover file dialogs / notifications / OpenURI /
              # dark mode without it. The GTK-portal wiring below applies only
              # when it is turned back on.
              portal = {
                enable = mkDefault cfg.features.desktopPortal;
                extraPortals = with pkgs; [
                  xdg-desktop-portal-gtk
                ];
                # Only the GTK portal is installed (FileChooser / Notification /
                # OpenURI / Settings). XDG_CURRENT_DESKTOP=labwc, so key the labwc
                # profile to gtk too — labwc ships a wlr-preferring default we
                # don't want here (no wlroots portal installed; screenshots use
                # grim/slurp directly, which need no portal).
                config = {
                  common = {
                    default = [ "gtk" ];
                    "org.freedesktop.impl.portal.FileChooser" = [ "gtk" ];
                    "org.freedesktop.impl.portal.Notification" = [ "gtk" ];
                    "org.freedesktop.impl.portal.OpenURI" = [ "gtk" ];
                  };
                  labwc = {
                    default = [ "gtk" ];
                  };
                };
              };
              sounds.enable = mkDefault true;
            };

            # ── zram ────────────────────────────────────────────────────
            zramSwap = {
              enable = mkDefault true;
              # lz4 rather than the zstd default. For a swap device the number
              # that matters is how long a fault takes to come back, not how
              # small the page got: zstd compresses perhaps 30% better and
              # costs several times as much CPU to decompress, and on these
              # machines that CPU is the scarce resource. Compressed swap is
              # only worth having while reading it back stays cheaper than
              # reading the disk it replaces.
              algorithm = mkDefault "lz4";
              # Explicit because the ordering carries weight: zram has to
              # outrank the disk swap partition disko creates (which lands at
              # priority -1), or the kernel will page out to the disk while
              # compressed RAM sits unused.
              priority = mkDefault 100;
              # 50% is the NixOS default and stays that on flash, where falling
              # through to the disk swap partition is merely slow. On a platter
              # it is the difference between a pause and a machine that has
              # stopped answering, so buy more headroom in compressed RAM before
              # anything reaches the disk at all.
              #
              # This is a capacity, not an allocation: the figure is how much
              # *uncompressed* anonymous memory the device will accept, and the
              # real RAM it occupies is that divided by the compression ratio,
              # only as it fills. At 75% with lz4 doing its usual 2-3x on
              # desktop anon pages, a full device is holding roughly three
              # quarters of RAM worth of pages in something like a quarter of
              # it. Distributions ship 100% at this point; 75% keeps a margin
              # for the case where the pages compress badly.
              memoryPercent = mkDefault (if cfg.diskType == "hdd" then 75 else 50);
            };
          };
        };

      # ── Installer (via nixos-install-helper) ─────────────────────────────────
      # install / installTemplate systems, the unattended + guided ISOs, and the
      # configure / install / deploy apps — all derived from nanoDesktop.*.
      nixosConfigurations = ih.nixosConfigurations;
      packages = ih.packages;
      apps = ih.apps;
    };
}
