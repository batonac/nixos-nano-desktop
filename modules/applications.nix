{
  config,
  lib,
  pkgs,
  ...
}:
with lib;
let
  cfg = config.nanoDesktop;

  # Always installed for manual runs; the automatic timer is gated by
  # features.autoUpgrade (see nix.nix, which owns both).
  systemUpgradeScript = import ../pkgs/system-upgrade.nix { inherit lib pkgs; };

  accents = import ../pkgs/accent.nix { inherit lib; };

  # adw-gtk3, with nanoDesktop.accentColor in it.
  #
  # The theme hardcodes its accent — `@define-color accent_bg_color @blue_3`
  # — and ships no per-accent variants, so following the option means
  # rewriting that one definition. It is worth doing rather than leaving
  # GTK3 blue on a desktop where half the visible chrome (the file manager,
  # the lock screen, the panel's menus) is GTK3: accent_bg_color is used 157
  # times downstream of that line, and accent_color is derived from it, so
  # the single substitution carries the whole theme. @blue_3 itself is used
  # nowhere else, which is what makes this safe rather than a sed across a
  # stylesheet.
  #
  # Only when the accent is not blue. At the default this is the upstream
  # package unchanged — no derivation of our own, nothing to build, and the
  # binary cache still has it.
  adwGtk3 =
    if cfg.accentColor == accents.default then
      pkgs.adw-gtk3
    else
      pkgs.adw-gtk3.overrideAttrs (previous: {
        pname = "${previous.pname or "adw-gtk3"}-${cfg.accentColor}";
        postInstall = (previous.postInstall or "") + ''
          for css in $out/share/themes/adw-gtk3*/gtk-3.0/gtk.css; do
            substituteInPlace "$css" \
              --replace-fail \
                '@define-color accent_bg_color @blue_3;' \
                '@define-color accent_bg_color ${accents.palette.${cfg.accentColor}};'
          done
        '';
      });

  # The packages and the document types for nanoDesktop.officeSuite. See
  # ../pkgs/office.nix — "none" and "gnome" never evaluate the LibreOffice
  # derivations, so the choice costs nothing it does not use.
  office = import ../pkgs/office.nix {
    inherit lib pkgs;
    inherit (cfg) officeSuite;
  };

  # The settings GUI and its root helper, gated by features.settingsApp.
  # See ../pkgs/nano-settings — the app reads a schema generated from
  # options.nix, so it needs nothing from here beyond being installed.
  nanoSettings = import ../pkgs/nano-settings { inherit lib pkgs; };

  # nanoDesktop.extraPackageNames → derivations.
  #
  # The JSON settings file cannot hold a package, only its name, which is
  # what makes a GUI able to add software at all. Resolution is deliberately
  # forgiving: this list is written by that GUI, and one bad entry must not
  # be able to leave the machine unable to evaluate — that would take the
  # autoUpgrade timer down with it, silently, and turn a mistyped package
  # into a rescue-media problem.
  #
  # The derivation is forced through drvPath rather than merely looked up,
  # because that is where nixpkgs decides whether it will allow the package
  # at all. A package it refuses — insecure, broken, or unfree on a system
  # that did not allow it — answers .name quite happily and only throws when
  # something forces its output path. Without the seq that something would
  # be environment.systemPackages building its buildEnv: far outside this
  # tryEval, and long past the point where the name could be blamed.
  resolvePackageName =
    name:
    let
      attempt = builtins.tryEval (
        let
          value = lib.attrByPath (lib.splitString "." name) null pkgs;
        in
        if lib.isDerivation value then builtins.seq value.drvPath value else null
      );
    in
    if attempt.success && attempt.value != null then
      attempt.value
    else
      lib.warn "nanoDesktop.extraPackageNames: \"${name}\" is not a package that can be installed here — skipping it. It may be misspelled, renamed, removed from nixpkgs, or refused as broken or insecure." null;

  namedPackages = lib.filter (package: package != null) (
    map resolvePackageName cfg.extraPackageNames
  );

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

  # Volume / brightness OSD without a resident daemon: adjust the
  # level, then surface it
  # through mako, which renders the int:value hint as a progress bar
  # (progress-color in ../config/mako/config). The notification id is cached
  # under XDG_RUNTIME_DIR and re-used with -r, so repeated keypresses
  # update one on-screen card in place instead of stacking. Bound to
  # the XF86 audio/brightness keys in ../config/labwc/rc.xml.
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
  # only always-on piece is the wl-paste watcher user service below,
  # around 1-2 MB.
  #
  # Both pickers reuse fuzzel — already in the stack as the launcher, so
  # the look is shared for free — and both replay the pick into the
  # focused surface through wtype, so the character lands at the caret
  # rather than only on the clipboard. labwc advertises
  # zwp_virtual_keyboard_manager_v1 (wtype) and both ext-/wlr-data-control
  # (the watcher), so nothing here needs a compositor feature the session
  # does not already have.

  # Searchable Unicode index: "<char>\t<NAME>" per line, built from the
  # Unicode data already packaged in nixpkgs. See ../config/unicode/
  # build-index.py for the source-by-source reasoning; the short version
  # is that UnicodeData.txt carries every named codepoint, and
  # emoji-test.txt adds the multi-codepoint sequences (flags, ZWJ
  # families, skin tones) that UnicodeData cannot express.
  nanoUnicodeIndex =
    pkgs.runCommand "nano-unicode-index"
      {
        nativeBuildInputs = [ pkgs.python3 ];
      }
      ''
        mkdir -p "$out/share/nano-desktop"
        python3 ${../config/unicode/build-index.py} \
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
  # deliberately leaves the clipboard alone, so picking a character does
  # not cost the user whatever they had copied. Only if wtype fails does
  # it fall back to the clipboard, and then it says so.
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

  # labwc titlebar theme carrying the GNOME/Adwaita window-button icons.
  # labwc finds button images by theme name on XDG_DATA_DIRS/themes, so
  # the SVGs must live in share/themes (linked via pathsToLink) rather
  # than /etc/xdg. rc.xml references it as <theme><name>NanoAdwaita.
  # Inactive-window buttons are derived from the active SVGs by dimming
  # (white → the inactive label grey), so only the active icons are
  # kept in-tree under ../config/labwc/theme.
  nanoLabwcTheme = pkgs.runCommand "nano-labwc-theme" { } ''
    dst=$out/share/themes/NanoAdwaita/labwc
    mkdir -p "$dst"
    cp ${../config/labwc/theme/NanoAdwaita/labwc}/themerc "$dst/"
    for f in ${../config/labwc/theme/NanoAdwaita/labwc}/*-active.svg; do
      base=$(basename "$f" -active.svg)
      cp "$f" "$dst/$base-active.svg"
      sed -e 's/#ffffff/#9a9a9a/g' \
          -e 's/fill-opacity="0.09"/fill-opacity="0.05"/g' \
          "$f" > "$dst/$base-inactive.svg"
    done
  '';

  # The icon theme: upstream MoreWaita, mirrored as a symlink farm so
  # this package can add directories to it and own its index.theme.
  # The chain is MoreWaita → Adwaita → AdwaitaLegacy → hicolor.
  #
  # Why MoreWaita: it only ever adds icons. A theme that also aliases
  # app names onto generic category art — apps/code.svg as a symlink to
  # text-editor.svg, and hundreds more of that kind — is not merely a
  # style choice here, because Sfwbar tries the raw Wayland app_id as an
  # icon name *before* it reads app_id.desktop's Icon= key
  # (app_info_lookup_id, src/appinfo.c). VS Code is app_id "code" and
  # Icon=vscode, so under a theme carrying an alias at "code" the
  # taskbar stops there and shows a notepad, never reaching the vscode
  # icon the same theme also ships. MoreWaita has no "code" at all, so
  # that lookup falls through to code.desktop and resolves vscode
  # properly. It generalises: a name MoreWaita does not carry falls
  # through to hicolor — the app's own branded icon, which is the right
  # icon in the wrong style rather than the wrong icon.
  #
  # adwaita-icon-theme-legacy is the load-bearing part of the chain. It
  # is where GNOME 46 put the named full-colour icons it removed from
  # adwaita-icon-theme (application-pdf, web-browser, document-new,
  # audio-volume-*, battery-*, the dialog-* set), which is what made a
  # plain Adwaita unusable here before. MoreWaita's index.theme already
  # names it in Inherits=, so it only has to be installed.
  #
  # Three things are added on top of upstream. First, four names this
  # desktop asks for by hand that nothing in the chain carries — an
  # unresolved name in the labwc menu or the Sfwbar panel is a blank
  # entry rather than a worse one. Second, three application names
  # answered with generic art instead of the program's own. Third, 24px
  # line-art variants of the places/devices icons, which is the part
  # worth explaining:
  #
  # libfm asks for plain names (user-home, folder, drive-harddisk) for
  # both the PCManFM side pane and its file lists, and Adwaita answers
  # those with full-colour art at every size — so a 16px side-pane row
  # gets a shrunken illustration where a glyph belongs. Splitting the
  # answer by size is what fixes that, and the icon theme spec already
  # provides the lever: a 24x24 Threshold directory covers 16–32px (side
  # pane 24, list view 24) while Adwaita's colour art stays linked into
  # scalable for everything above (icon view 48, thumbnails 128). The
  # small sizes are drawn from Adwaita's own symbolic art, so the two
  # halves are the same shapes at both ends.
  #
  # The recolour is what makes that work at all. These are copies rather
  # than symbolic lookups — GTK only recolours a name ending in
  # -symbolic — so the fill has to be rewritten, to #dedede. See
  # symbolize() below for why the rewrite is a pattern rather than the
  # one literal colour it started as.
  nanoIconTheme = pkgs.runCommand "nano-icon-theme" { } ''
    mw=${pkgs.morewaita-icon-theme}/share/icons/MoreWaita
    adw=${pkgs.adwaita-icon-theme}/share/icons/Adwaita
    dst=$out/share/icons/MoreWaita

    # cp -rs links rather than copies, so upstream stays on the binary
    # cache and only the files added below cost anything.
    mkdir -p "$dst"
    cp -rs "$mw"/. "$dst"/
    # cp -rs copies the store's read-only directory modes along with the
    # tree. Only the directories are made writable — a -R chmod would
    # follow the symlinks and try to touch the store files themselves.
    find "$dst" -type d -exec chmod u+w {} +
    rm "$dst/index.theme"

    # Copy a symbolic drawing to a name GTK will not recolour for it,
    # baking in the colour that recolouring would have supplied.
    #
    # Everything below installs symbolic art under a plain name, and the
    # -symbolic suffix is precisely what makes GTK substitute the widget's
    # foreground colour for the fill. Without it the file renders as drawn,
    # and symbolic art is drawn near-black — which on this desktop means
    # invisible, since every surface these icons land on (the panel, its
    # menus, the fuzzel launcher, PCManFM's dark side pane) is dark. So the
    # fill is rewritten here to #dedede, the light grey those surfaces
    # already draw their text in.
    #
    # A pattern rather than the single s/#2e3436/#dedede/ this began as,
    # because Adwaita is not consistent about which near-black it draws in:
    # #2e3436 for most of it, #2e3434 in six of the device icons (camera-web,
    # drive-optical, drive-removable-media, media-flash, media-optical,
    # scanner), #474747 through half the legacy set, #222222 for phone's home
    # bar. The literal caught the first and left the rest black on black.
    #
    # The fill on the root <svg> is for art that names no fill at all, which
    # would otherwise inherit the SVG default — black again. fill is an
    # inherited presentation attribute, so it reaches any path that does not
    # set its own, and the rewrite above covers the ones that do.
    #
    # Flattening every fill to one grey is only right for art that was
    # monochrome to begin with. Adwaita's symbolic tree is, with four
    # exceptions — the charge-state battery icons, which carry a real green
    # and a real red — and nothing below points at those.
    #
    # Deleting the destination first matters because of the cp -rs above:
    # where MoreWaita already has a file of that name, $2 is a symlink into
    # its store path, and a plain redirect would follow it and try to write
    # there.
    symbolize() { # symbolize <source.svg> <destination.svg>
      mkdir -p "$(dirname "$2")"
      rm -f "$2"
      sed -E -e 's|<svg |<svg fill="#dedede" |' \
             -e 's|fill="#[0-9a-fA-F]{6}"|fill="#dedede"|g' \
             -e 's|fill:#[0-9a-fA-F]{6}|fill:#dedede|g' \
             "$1" > "$2"
    }

    # lxtask.desktop names utilities-system-monitor. htop's icon is the
    # nearest thing in the chain — a terminal carrying a bar graph.
    cp "$mw/scalable/apps/htop.svg" \
      "$dst/scalable/apps/utilities-system-monitor.svg"
    cp "$mw/symbolic/apps/htop-symbolic.svg" \
      "$dst/symbolic/apps/utilities-system-monitor-symbolic.svg"

    # Sfwbar's wifi-secret.widget — the WPA passphrase prompt the network
    # widget opens — labels its two buttons dialog-ok and dialog-cancel.
    # Those are pre-GNOME-3 names that no Adwaita generation carried.
    cp "$adw/symbolic/actions/object-select-symbolic.svg" \
      "$dst/symbolic/status/dialog-ok-symbolic.svg"
    cp "$adw/symbolic/ui/window-close-symbolic.svg" \
      "$dst/symbolic/status/dialog-cancel-symbolic.svg"

    # No generation of Adwaita has drawn a suspend glyph. The Sfwbar
    # power menu needs one to sit beside lock/log-out/reboot/shut-down,
    # and pause is the reading the rest of the set implies.
    cp "$adw/symbolic/actions/media-playback-pause-symbolic.svg" \
      "$dst/symbolic/status/system-suspend-symbolic.svg"

    # ── Applications answered with generic art ──────────────────
    # Three programs whose own icon is the wrong icon here, replaced by
    # naming them in the theme: the theme is consulted before the .desktop
    # file's Icon= key can send anyone to hicolor, so one entry per name
    # covers the application menu, the taskbar and the fuzzel launcher at
    # once, and nothing has to override a .desktop file the package owns.
    #
    #   iwgtk      — ships a 48px wifi arc with no fill attribute at all,
    #                so it renders solid black: not merely off-style but
    #                genuinely hard to see on the dark menu and launcher.
    #                Adwaita's wifi glyph says the same thing legibly.
    #   galculator — a 2008-vintage GTK2-era drawing, and the one thing
    #                on this desktop where a generic name (the calculator
    #                everyone recognises) is more informative than the
    #                brand.
    #   xarchiver  — likewise; the package-x-generic parcel is what the
    #                rest of this desktop already uses for an archive.
    #
    # Both halves are installed for each: the recoloured copy under the
    # plain name, which is what everything here actually asks for, and the
    # untouched original under -symbolic, so a consumer that prefers the
    # symbolic variant (Sfwbar sets -ScaleImage-symbolic on most panel
    # images) gets art GTK will recolour for itself rather than the baked
    # grey.
    for entry in \
      "iwgtk:devices/network-wireless-symbolic.svg" \
      "galculator:legacy/accessories-calculator-symbolic.svg" \
      "xarchiver:mimetypes/package-x-generic-symbolic.svg"
    do
      name=''${entry%%:*}
      art="$adw/symbolic/''${entry#*:}"
      symbolize "$art" "$dst/scalable/apps/$name.svg"
      ln -sf "$art" "$dst/symbolic/apps/$name-symbolic.svg"
    done

    # The 16–32px line-art set described above. Driven off Adwaita rather
    # than a hand-kept list: every places/devices name it draws both ways
    # — 36 of them — gets the treatment, and a list that derives itself
    # cannot fall behind the theme it derives from.
    for cat in places devices; do
      mkdir -p "$dst/24x24/$cat" "$dst/scalable/$cat"
      for f in "$adw"/scalable/$cat/*.svg; do
        n=$(basename "$f" .svg)
        sym=$(find -L "$adw/symbolic" -name "$n-symbolic.svg" | head -1)
        [ -n "$sym" ] || continue
        symbolize "$sym" "$dst/24x24/$cat/$n.svg"
        # Only where MoreWaita has no art of its own — its own drawings win.
        if [ ! -e "$dst/scalable/$cat/$n.svg" ] && [ ! -L "$dst/scalable/$cat/$n.svg" ]; then
          ln -s "$f" "$dst/scalable/$cat/$n.svg"
        fi
      done
    done

    # ── display-brightness, at a size mako can use ──────────────
    # nano-osd names display-brightness for the brightness keys, and no
    # generation of Adwaita draws it outside symbolic/ — so that OSD came
    # up as a bare progress bar while volume and microphone, which
    # AdwaitaLegacy carries as sized art, came up with a glyph.
    #
    # Everything odd about where this lands is mako's doing, because mako
    # reads no theme metadata at all. It globs <theme>/*/*/<name>.* and
    # takes the icon size from the directory name with strtol, so
    # scalable/ and symbolic/ both parse as size 0 and are skipped: only a
    # numerically-named directory can answer it. And fit_to_square() only
    # ever shrinks, never enlarges, so a 16px drawing would stay 16px
    # beside the 48px volume glyphs however much room the card has.
    #
    # Hence 48x48, and hence the width/height rewrite: the size has to be
    # in the file as well as in the path. The viewBox is deliberately left
    # alone — that is what makes this a resize of vector art rather than a
    # window onto the corner of it.
    symbolize "$adw/symbolic/status/display-brightness-symbolic.svg" \
      "$dst/48x48/status/display-brightness.svg"
    sed -i -E 's/(width|height)="16px"/\1="48px"/g' \
      "$dst/48x48/status/display-brightness.svg"

    # The 24x24 dirs go at the FRONT of Directories=: GTK breaks a
    # size-match tie by list order, and scalable/* matches 24 just as
    # exactly as a Threshold dir centred on it does. 48x48/status rides
    # along for declaration's sake rather than to win anything — nothing
    # else in the chain draws display-brightness at any size — but a
    # directory missing from Directories= is one GTK will not look in at
    # all, and an icon only mako can see is a trap for whoever needs the
    # same glyph next.
    sed 's|^Directories=|Directories=24x24/places,24x24/devices,48x48/status,|' \
      "$mw/index.theme" > "$dst/index.theme"
    for spec in "24x24/places:24:Places" "24x24/devices:24:Devices" \
                "48x48/status:48:Status"; do
      rest=''${spec#*:}
      printf '\n[%s]\nSize=%s\nContext=%s\nType=Threshold\nThreshold=8\n' \
        "''${spec%%:*}" "''${rest%%:*}" "''${rest#*:}" >> "$dst/index.theme"
    done
  '';

  # ── Application entries this desktop owns ───────────────────
  # Seven .desktop files that packages we do want install alongside what
  # we want. Four are hidden, because they only make the application menu
  # harder to read; three — PCManFM's, iwgtk's and foot's — are rewritten
  # to say what the program is rather than what it is called. There is no
  # build-time switch for any of them, so both happen after the fact.
  #
  # The mechanism is the system profile's own collision resolution.
  # environment.systemPackages is a buildEnv, and buildEnv resolves two
  # packages claiming the same relative path by meta.priority, lower
  # number winning; the default is 5. At priority -10 this package's
  # share/applications/<name>.desktop is the one that gets linked into
  # /run/current-system/sw/share/applications, and the real entry is
  # simply not there.
  #
  # Doing it in the profile rather than per-consumer is what makes it
  # hold everywhere: the Sfwbar menu, the fuzzel launcher and PCManFM's
  # "Open With" list all read that one directory, so none of them needs
  # to know. (Sfwbar's appmenu module has an AppMenuFilter action that
  # would cover its own menu alone — not enough.)
  #
  # Hidden as well as NoDisplay: NoDisplay is the "not in menus" flag,
  # Hidden makes GIO refuse to load the entry at all. None of the hidden
  # files carries a MimeType, so nothing loses a document association.
  #
  # Note what is NOT here: blueman-adapters.desktop. It already declares
  # OnlyShowIn=XFCE;MATE, so everything that reads that key was hiding it
  # correctly and there is nothing to correct in the profile — it was
  # fuzzel that had to be told to read the key at all (filter-desktop in
  # ../config/fuzzel/fuzzel.ini). An entry that is honest about where it
  # belongs deserves the setting, not a stub written over the top of it.
  nanoDesktopEntries =
    let
      # cups.desktop is "Manage Printing", and it opens the CUPS web
      # interface at localhost:631 — which services.printing.webInterface
      # is set to false in services.nix, so the link goes nowhere. The
      # printer UI on this desktop is system-config-printer, installed
      # by the same feature flag.
      hidden = [
        # foot installs a launcher for each half of its client/server
        # mode next to the plain terminal. Three terminal entries in
        # the menu, two of which do nothing useful started from a menu.
        "footclient.desktop"
        "foot-server.desktop"
        # "Desktop Preferences" — wallpaper and icon-view settings for a
        # desktop PCManFM is not drawing. Nothing here runs `pcmanfm
        # --desktop`: the background is swaybg's (see session.nix) and
        # nanoDesktop.backgroundColor / backgroundImage is where it is
        # set from. The dialog opens, and every control in it is inert.
        #
        # It is the one entry in this list that says where it does not
        # belong and is still wrong here — NotShowIn=GNOME;XFCE;KDE;MATE
        # names the four desktops that draw their own background and
        # misses ours, which does too.
        "pcmanfm-desktop-pref.desktop"
      ]
      ++ optional cfg.features.printing "cups.desktop";
    in
    pkgs.runCommand "nano-desktop-entries" { meta.priority = -10; } ''
      mkdir -p "$out/share/applications"
      for entry in ${escapeShellArgs hidden}; do
        printf '%s\n' \
          '[Desktop Entry]' \
          'Type=Application' \
          "Name=$entry" \
          'Exec=true' \
          'NoDisplay=true' \
          'Hidden=true' \
          > "$out/share/applications/$entry"
      done

      # ── Three entries named for what they are ──────────────────
      # The three below are renamed for one reason: this menu is read by
      # someone looking for a capability, not for a project. "PCMan File
      # Manager", "iwgtk" and "Foot" file the file manager under P, the
      # wifi tool under I and the terminal under F, in a menu sorted and
      # displayed by that key, next to entries that already read Document
      # Viewer, Task Manager and System Settings.
      #
      # Each is derived from the packaged entry and rewritten in place, so
      # everything else the file says — Exec, MimeType, Categories, the
      # translations — stays exactly as shipped and stays that way through
      # updates. Each rewrite is guarded by a grep first: the whole point
      # of deriving is to notice when upstream moves, and a sed that
      # silently matches nothing would give away that entire benefit.
      #
      # The brand goes into Keywords rather than being lost. Someone who
      # knows the program by name should still find it by name; fuzzel is
      # told to match on keywords in ../config/fuzzel/fuzzel.ini, and the
      # panel's menu does not search at all, so there is nothing to tell
      # it there.
      keywords() { # keywords <file> <kw;kw;>
        # Merge rather than append. Two of these files carry no Keywords
        # line and one does, and a second Keywords= would be a duplicate
        # key — the spec allows one per group and leaves which of two wins
        # undefined, which is exactly the kind of thing that works until
        # the day a different parser reads it.
        if grep -q '^Keywords=' "$1"; then
          sed -i "s/^Keywords=/Keywords=$2/" "$1"
        else
          printf 'Keywords=%s\n' "$2" >> "$1"
        fi
      }

      # ── PCManFM ────────────────────────────────────────────────
      # Nobody who wants to browse their files looks for PCMan.
      #
      # This one is a promotion rather than a substitution, and that is
      # the file's doing rather than a preference: it already carries
      # GenericName=File Manager translated into 45 languages, so dropping
      # the branded Name keys and moving GenericName up gives the right
      # name in every one of them. An English string spliced over Name
      # alone would have left "PCMan Dateimanager" behind in German.
      #
      # Deriving matters most here of the three, because this entry is
      # load-bearing beyond its name: MimeType=inode/directory is what
      # makes the xdg.mime default below resolve, and Exec's %U is what
      # lets anything hand it a folder.
      #
      # Icon is deliberately untouched: system-file-manager resolves to
      # MoreWaita's own drawing, which is already the icon this desktop
      # wants. There is nothing to override.
      entry=${pkgs.pcmanfm}/share/applications/pcmanfm.desktop
      grep -q '^GenericName=File Manager$' "$entry"
      sed -e '/^Name\(\[[^]]*\]\)\{0,1\}=/d' \
          -e 's/^GenericName/Name/' \
          "$entry" > "$out/share/applications/pcmanfm.desktop"
      keywords "$out/share/applications/pcmanfm.desktop" \
        'pcmanfm;pcman;files;folders;browse;'

      # ── iwgtk ──────────────────────────────────────────────────
      # Name=iwgtk is a library abbreviation and a toolkit abbreviation,
      # on the one program here someone opens because the wifi is not
      # working. "WiFi Manager" also puts it where the panel's own wifi
      # widget has already taught them to look.
      #
      # A substitution, because iwgtk ships no GenericName and no
      # localized Name at all: there is nothing to promote, and nothing
      # left in another language to contradict the English string.
      #
      # Icon stays "iwgtk", which nanoIconTheme answers with Adwaita's
      # wifi glyph — see the application aliases there. That alias keys on
      # the icon name rather than on this file, which is what lets the two
      # change independently; they are now the only things still saying
      # "iwgtk", and iwd is in the keywords because it is the name the
      # wifi stack is documented under.
      entry=${pkgs.iwgtk}/share/applications/iwgtk.desktop
      grep -q '^Name=iwgtk$' "$entry"
      sed 's/^Name=iwgtk$/Name=WiFi Manager/' \
        "$entry" > "$out/share/applications/iwgtk.desktop"
      keywords "$out/share/applications/iwgtk.desktop" \
        'iwgtk;iwd;wifi;wireless;network;'

      # ── foot ───────────────────────────────────────────────────
      # "Foot" is a name for the project, not for the thing in the menu,
      # and it is the entry where that matters least to anyone who knows
      # and most to anyone who does not: a terminal is what someone looks
      # for when they have been told to run a command. Its two siblings
      # are hidden above, so this is the only terminal entry left and can
      # afford the generic name outright.
      #
      # A substitution again, and GenericName=Terminal is left in place
      # rather than promoted — it would have given "Terminal" where the
      # ask was "Terminal Emulator", and it still earns its keep as a
      # second thing fuzzel matches on.
      #
      # This is the file that needs keywords() to merge rather than
      # append: foot is the one of the three that already ships a Keywords
      # line (shell;prompt;command;commandline), and those are good
      # keywords worth keeping.
      entry=${pkgs.foot}/share/applications/foot.desktop
      grep -q '^Name=Foot$' "$entry"
      sed 's/^Name=Foot$/Name=Terminal Emulator/' \
        "$entry" > "$out/share/applications/foot.desktop"
      keywords "$out/share/applications/foot.desktop" 'foot;terminal;console;'
    '';
in
{
  # ── Overlays ────────────────────────────────────────────────
  # Celluloid resolves stream URLs through yt-dlp, and yt-dlp needs a
  # JavaScript runtime for full YouTube support (its nsig challenges).
  # nixpkgs points that at Deno, which is 255 MB unpacked — the third
  # largest thing in this system's closure, behind LibreOffice and the
  # kernel firmware, for what is a sandboxed JS interpreter run for a
  # fraction of a second per URL. quickjs-ng does the same job in about
  # 1 MB, and yt-dlp supports it directly.
  #
  # It takes both halves below, because nixpkgs' `jsRuntime` argument
  # and yt-dlp's own runtime selection are not the same switch:
  #
  #   • javascriptSupport = false drops the postPatch that hardcodes a
  #     store path into yt-dlp's *Deno* runtime class. That is all it
  #     does (see the nixpkgs expression) — it is what removes the Deno
  #     reference, not a decision to go without JavaScript.
  #   • --js-runtimes is what actually enables a runtime, and it
  #     defaults to ["deno"] alone. Its RUNTIME:PATH form names quickjs
  #     and hands it the binary directly, so nothing needs to be on
  #     PATH and nothing is searched for at runtime.
  #
  # Overriding jsRuntime instead would leave the Deno class pointing at
  # a qjs binary it then probes with `--version` and rejects — the same
  # end state, reached by a confusing route.
  #
  # Cheap to carry, unlike the ffmpeg case next door: yt-dlp is a pure
  # Python build, so this rebuilds it and Celluloid's wrapper in
  # seconds and leaves the rest of the closure on the binary cache.
  nixpkgs.overlays = [
    (final: prev: {
      # ── One ffmpeg fewer ──────────────────────────────────────
      # The system carried three: ffmpeg 8.1.2 (mpv, alsa-plugins),
      # ffmpeg-headless 8.1.2 (pipewire, gst-libav, chromaprint,
      # yt-dlp) and ffmpeg 7.1.5 — the last one there for Firefox
      # alone, because that is what nixpkgs' wrapper happens to name.
      #
      # Firefox does not link ffmpeg. wrapFirefox only adds it to
      # LD_LIBRARY_PATH, and Firefox dlopens libavcodec by soname
      # against a table of the versions it knows — 53 through 62 in
      # 153, checked with `strings libxul.so`. ffmpeg-headless 8.1.2
      # is soname 62 and is already in the closure, so pointing the
      # wrapper's ffmpeg_7 argument at it costs nothing and drops
      # ffmpeg 7.1.5 entirely.
      #
      # This is the same trick as the libpressureaudio swap in
      # audio.nix, and it works for the same reason: ffmpeg_7 is an
      # argument of the WRAPPER, a trivial builder, not of
      # firefox-unwrapped. Overriding wrapFirefox rebuilds the small
      # wrapper and nothing else — firefox-unwrapped stays byte-identical
      # and stays on the binary cache.
      #
      # Note this does not generalize to the other two. mpv and
      # pipewire *link* libavcodec at build time, so consolidating
      # those would mean recompiling them and everything downstream —
      # which is exactly the trade this overlay exists to avoid.
      wrapFirefox = prev.wrapFirefox.override { ffmpeg_7 = final.ffmpeg-headless; };

      yt-dlp = (prev.yt-dlp.override { javascriptSupport = false; }).overrideAttrs (old: {
        makeWrapperArgs = (old.makeWrapperArgs or [ ]) ++ [
          "--add-flags"
          "--js-runtimes"
          "--add-flags"
          "quickjs:${lib.getExe final.quickjs-ng}"
        ];
      });
    })
  ];

  # ── Installed packages ──────────────────────────────────────
  environment.systemPackages =
    with pkgs;
    [
      # ── Compositor + panel ──
      labwc
      nanoLabwcTheme # Adwaita titlebar-button icons for labwc
      sfwbar

      # ── Terminal + launcher ──
      foot
      fuzzel

      # ── Browser ──
      # Firefox is NOT listed here. programs.firefox (below) installs
      # it, because that is the only way to hand it preferences, and it
      # adds its own finalPackage to this same profile — naming it in
      # both places would put two Firefoxes in one buildEnv and
      # collide.

      # ── Text editor ──
      # GNOME Text Editor: a plain editor with syntax highlighting and
      # nothing else, and the one the rest of the desktop already pays
      # for — it is libadwaita, so it inherits the dark theme with no
      # configuration, and it adds four store paths (~8 MB) on top of
      # the GTK4 stack Celluloid and Evince already bring.
      #
      # It also lands in the right place in the menu, which is the point.
      # Its Categories are GNOME;GTK;Utility;TextEditor, so it appears
      # under Accessories. An IDE lists itself under Development;IDE and
      # shows up in the menu beside a compiler toolchain — accurate, and
      # the wrong answer for someone looking for Notepad.
      gnome-text-editor

      # ── File management ──
      pcmanfm
      xarchiver
      file

      # ── Media / images / documents ──
      celluloid
      image-roll
      # Evince reads PDF, PostScript, DjVu, DVI, TIFF, XPS and the
      # comic-book formats in 16 MB, because it carries no browser
      # engine. EPUB is the one gap; see the MIME map, where it is left
      # unassociated rather than pointed at something that cannot open
      # it.
      evince

      # ── Notifications ──
      mako

      # ── Screenshot / clipboard ──
      # The screen lock is gtklock, installed by programs.gtklock in
      # session.nix along with its PAM service — it is the session's
      # login gate, not a utility, so it is declared there.
      grim
      slurp
      wl-clipboard
      nano-screenshot

      # Four .desktop files hidden from the application menu, and
      # PCManFM's rewritten — see nanoDesktopEntries above for what and
      # why.
      nanoDesktopEntries

      # ── Volume / brightness ──
      # nano-osd services the XF86 media keys (see labwc/rc.xml)
      # with no resident daemon.
      # alsa-utils supplies amixer (used by nano-osd, the first-boot
      # volume seed in audio.nix and, in apulse
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
      # hidden networks, WPS, per-adapter power and diagnostics. It is
      # all the GUI this stack needs — wired is automatic under networkd
      # and VPNs are
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
      # adw-gtk3 gives GTK3 apps the libadwaita look, with the accent
      # built into it (see adwGtk3 above); GTK4/libadwaita apps follow
      # the dark color-scheme and the accent from the locked dconf
      # profile directly. The icon theme is
      # MoreWaita and the four packages below are one inheritance chain,
      # walked in this order (see nanoIconTheme above for why):
      #   nanoIconTheme — MoreWaita (see above; it wraps the upstream
      #                package rather than sitting beside it, so
      #                morewaita-icon-theme is deliberately NOT listed
      #                here — two packages owning share/icons/MoreWaita
      #                would collide on index.theme)
      #   adwaita    — modern symbolic set, places, mimetypes, and the
      #                Adwaita cursor (Wayland has no server-side one)
      #   legacy     — the named full-colour icons GNOME 46 split out of
      #                adwaita-icon-theme; without it web-browser and
      #                friends are symbolic-only and application-pdf
      #                does not resolve at all
      #   hicolor    — each app's own branded icon, the last resort
      adwGtk3
      adwaita-icon-theme
      adwaita-icon-theme-legacy
      nanoIconTheme
      hicolor-icon-theme
      # NixOS snowflake (hicolor: nix-snowflake, nix-snowflake-white)
      # — the Sfwbar Start-button icon. Nothing above the hicolor rung
      # carries it, so hicolor is what resolves it.
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
    # nanoDesktop.officeSuite and ../pkgs/office.nix.
    ++ office.packages
    # ── Settings GUI ──
    # The app and the root helper it drives through pkexec. Both or
    # neither: the helper on its own is a command nobody runs, and the
    # app without it can read the settings but not apply them. The
    # polkit action that names the helper ships inside the app.
    ++ optionals cfg.features.settingsApp [
      nanoSettings
      nanoSettings.passthru.helper
    ]
    # ── Anything the machine adds for itself ──
    # extraPackages is the Nix-value route; extraPackageNames is the
    # one a JSON settings file (and so the settings app) can take.
    ++ cfg.extraPackages
    ++ namedPackages;

  # ── Firefox ─────────────────────────────────────────────────
  # The browser is the workload on this class of machine — the largest
  # thing running, the one holding the memory, and very nearly the only
  # reason a 2012 laptop feels slow in 2025. Everything else in this
  # module is tuned around it; this is the module tuning it.
  #
  # programs.firefox rather than a bare package in systemPackages,
  # because preferences have to arrive as a policy and that option is
  # what writes one. It composes with the two wrapFirefox overlays this
  # desktop already carries (the libpressureaudio swap in audio.nix and
  # the ffmpeg_7 consolidation above): the module applies prefs by
  # overriding the WRAPPER's extraPrefsFiles, wrapFirefox's result is
  # lib.makeOverridable, and firefox-unwrapped is untouched by any of
  # the three — so this stays a cache hit and rebuilds a shell script.
  #
  # preferencesStatus = "default", not "locked". Every value below is a
  # starting point that about:config still overrides, which is the same
  # posture as the LibreOffice registry defaults in pkgs/office.nix.
  # The one thing this desktop locks is the theme, and that is because
  # it is a look rather than a decision.
  programs.firefox = {
    enable = mkDefault true;
    preferencesStatus = mkDefault "default";
    preferences = {
      # Sessionstore writes the entire session — every tab, every form
      # field, the back/forward history — every 15 seconds by default.
      # Each of those goes through zstd on the way to a compressed
      # btrfs root, on a machine where modules/boot.nix bounds the
      # dirty-page backlog specifically because it has no fast way to
      # drain one. 60 seconds is the same feature at a quarter of the
      # write rate; what it costs is up to a minute of tab state in a
      # crash, on a browser that also restores from its own recovery
      # file.
      "browser.sessionstore.interval" = 60000;
    }
    # Hardware video decoding. nanoDesktop.hardwareVideo calls this
    # "probably the largest single win available to this class of
    # machine" and installs the VA-API driver to deliver it — and then,
    # in the one application that matters, it was not being taken.
    #
    # Firefox ships hardware decoding OFF on Linux unless the driver
    # clears Mozilla's internal denylist, and the old Intel generations
    # this desktop exists for are exactly what that list is there to
    # catch. So the driver was installed, vainfo reported it working,
    # and the browser decoded 1080p on the CPU anyway — which on a
    # dual-core of this vintage is the difference between watching
    # something and watching it drop frames while the fan spins up.
    #
    # force-enabled is the documented override and it means it: it
    # bypasses the denylist rather than re-testing it, so on a driver
    # that genuinely misbehaves the failure is visual corruption or a
    # crashed content process rather than a quiet fallback. That is the
    # right trade only because the fallback here is not "slightly
    # slower" but "unusable", and because it is a default rather than a
    # lock — about:config, or this option set to "none", backs it out.
    #
    # Check the result rather than trusting it: about:support, Media
    # section, wants HARDWARE against the codec. vainfo (installed with
    # any hardwareVideo but "none") answers the other half.
    // optionalAttrs (cfg.hardwareVideo != "none") {
      "media.ffmpeg.vaapi.enabled" = true;
      "media.hardware-video-decoding.force-enabled" = true;
    }
    # nanoDesktop.browserSiteIsolation. See the option for the security
    # side of this; the memory side is that Fission's process-per-site
    # model is the single largest multiplier on RAM in this system, and
    # this system has 4 GB. processCount is the cap that applies once
    # Fission is not the thing choosing, and 4 is chosen against the
    # core count rather than the tab count.
    // optionalAttrs (!cfg.browserSiteIsolation) {
      "fission.autostart" = false;
      "dom.ipc.processCount" = 4;
    };
  };

  # ── Document types ──────────────────────────────────────────
  xdg.mime = {
    enable = mkDefault true;
    # office.mimeApps is merged in at the end: empty unless
    # officeSuite selects a suite, and it overlaps nothing in the
    # fixed set below — application/pdf in particular stays with
    # Evince, which LibreOffice Draw would otherwise claim.
    defaultApplications = {
      # Web → Firefox
      "text/html" = "firefox.desktop";
      "application/xhtml+xml" = "firefox.desktop";
      "x-scheme-handler/http" = "firefox.desktop";
      "x-scheme-handler/https" = "firefox.desktop";
      # Plain text / code → GNOME Text Editor. It declares only
      # text/plain itself, but it opens (and highlights) all of these,
      # and without the explicit entries each source type would fall
      # through to whatever else claims it.
      "text/plain" = "org.gnome.TextEditor.desktop";
      "text/x-chdr" = "org.gnome.TextEditor.desktop";
      "text/x-csrc" = "org.gnome.TextEditor.desktop";
      "text/x-c++hdr" = "org.gnome.TextEditor.desktop";
      "text/x-c++src" = "org.gnome.TextEditor.desktop";
      "text/x-java" = "org.gnome.TextEditor.desktop";
      "text/x-pascal" = "org.gnome.TextEditor.desktop";
      "text/x-perl" = "org.gnome.TextEditor.desktop";
      "text/x-python" = "org.gnome.TextEditor.desktop";
      "text/css" = "org.gnome.TextEditor.desktop";
      "text/x-diff" = "org.gnome.TextEditor.desktop";
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
      # Documents / comics → Evince
      # No application/epub+zip: Evince has no EPUB backend and nothing
      # else here reads one, so the type is deliberately left
      # unassociated rather than handed to a program that would open a
      # zip full of XHTML or fail outright — the same call the "gnome"
      # officeSuite makes for .docx.
      "application/pdf" = "org.gnome.Evince.desktop";
      "application/postscript" = "org.gnome.Evince.desktop";
      "image/vnd.djvu" = "org.gnome.Evince.desktop";
      "application/x-cbr" = "org.gnome.Evince.desktop";
      "application/x-cbz" = "org.gnome.Evince.desktop";
      "application/x-cb7" = "org.gnome.Evince.desktop";
      "application/x-cbt" = "org.gnome.Evince.desktop";
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
    // office.mimeApps;
  };
}
