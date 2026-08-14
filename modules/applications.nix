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

  namedPackages = lib.filter (package: package != null) (map resolvePackageName cfg.extraPackageNames);

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
  # Why MoreWaita and not Colloid, which this replaced: Colloid aliases
  # app names onto generic category icons — apps/scalable/code.svg is a
  # symlink to text-editor.svg, and 868 of its 6296 app entries are
  # aliases of that kind. That is not cosmetic here, because Sfwbar
  # tries the raw Wayland app_id as an icon name *before* it reads
  # app_id.desktop's Icon= key (app_info_lookup_id, src/appinfo.c), so
  # VS Code — app_id "code", Icon=vscode — hit Colloid's alias and got a
  # notepad in the taskbar, never reaching the vscode icon Colloid also
  # ships. MoreWaita carries no "code" at all, so the same lookup falls
  # through to code.desktop and resolves vscode properly. That holds in
  # general: MoreWaita only adds icons, so a name it does not carry
  # falls through to hicolor — the app's own branded icon, which is the
  # right icon in the wrong style rather than the wrong icon.
  #
  # adwaita-icon-theme-legacy is the load-bearing part of the chain. It
  # is where GNOME 46 put the named full-colour icons it removed from
  # adwaita-icon-theme (application-pdf, web-browser, document-new,
  # audio-volume-*, battery-*, the dialog-* set), which is what made a
  # plain Adwaita unusable here before. MoreWaita's index.theme already
  # names it in Inherits=, so it only has to be installed.
  #
  # Two things are added on top of upstream. First, four names this
  # desktop asks for by hand that nothing in the chain carries — an
  # unresolved name in the labwc menu or the Sfwbar panel is a blank
  # entry rather than a worse one. Second, 24px line-art variants of the
  # places/devices icons, which is the part worth explaining:
  #
  # libfm asks for plain names (user-home, folder, drive-harddisk) for
  # both the PCManFM side pane and its file lists, and Adwaita answers
  # those with full-colour art at every size. Colloid did not — it drew
  # the same names as monochrome line art in its fixed 16/22/24 dirs and
  # kept the colour art for scalable, so the side pane and list view came
  # out monochrome while the icon view stayed colour. That split is worth
  # keeping, so it is rebuilt here from Adwaita's own symbolic art: a
  # 24x24 Threshold directory covers 16–32px (side pane 24, list view 24)
  # and Adwaita's colour art is linked into scalable for everything above
  # (icon view 48, thumbnails 128).
  #
  # The recolour is the same trick Colloid used, arrived at differently:
  # Colloid set fill="currentColor" against an embedded #dedede
  # stylesheet. These are copies rather than symbolic lookups — GTK only
  # recolours a name ending in -symbolic — so the fill is rewritten
  # instead, from Adwaita's #2e3436 to the same #dedede.
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

    # The 16–32px line-art set described above. Driven off Adwaita rather
    # than a hand-kept list: every places/devices name it draws both ways
    # gets the treatment, which is the same 36 names Colloid covered.
    for cat in places devices; do
      mkdir -p "$dst/24x24/$cat" "$dst/scalable/$cat"
      for f in "$adw"/scalable/$cat/*.svg; do
        n=$(basename "$f" .svg)
        sym=$(find -L "$adw/symbolic" -name "$n-symbolic.svg" | head -1)
        [ -n "$sym" ] || continue
        sed 's/#2e3436/#dedede/g' "$sym" > "$dst/24x24/$cat/$n.svg"
        # Only where MoreWaita has no art of its own — its own drawings win.
        if [ ! -e "$dst/scalable/$cat/$n.svg" ] && [ ! -L "$dst/scalable/$cat/$n.svg" ]; then
          ln -s "$f" "$dst/scalable/$cat/$n.svg"
        fi
      done
    done

    # The 24x24 dirs go at the FRONT of Directories=: GTK breaks a
    # size-match tie by list order, and scalable/* matches 24 just as
    # exactly as a Threshold dir centred on it does.
    sed 's|^Directories=|Directories=24x24/places,24x24/devices,|' \
      "$mw/index.theme" > "$dst/index.theme"
    for cat in Places Devices; do
      printf '\n[24x24/%s]\nSize=24\nContext=%s\nType=Threshold\nThreshold=8\n' \
        "$(echo "$cat" | tr 'A-Z' 'a-z')" "$cat" >> "$dst/index.theme"
    done
  '';

  # ── Hidden application entries ──────────────────────────────
  # Three .desktop files that packages we do want install alongside
  # what we want, and that only make the application menu harder to
  # read. There is no build-time switch for any of them, so they are
  # hidden after the fact.
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
  # Hidden makes GIO refuse to load the entry at all. Neither file
  # carries a MimeType, so nothing loses a document association.
  nanoHiddenDesktopEntries =
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
      ]
      ++ optional cfg.features.printing "cups.desktop";
    in
    pkgs.runCommand "nano-hidden-desktop-entries" { meta.priority = -10; } ''
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

      # Three .desktop files hidden from the application menu — see
      # nanoHiddenDesktopEntries above for what and why.
      nanoHiddenDesktopEntries

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
      # adw-gtk3 gives GTK3 apps the libadwaita look; GTK4/libadwaita
      # apps follow the dark color-scheme directly. The icon theme is
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
      adw-gtk3
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
