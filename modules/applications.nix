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
    inherit pkgs;
    inherit (cfg) officeSuite;
  };

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
  # (progress-color in ../mako/config). The notification id is cached
  # under XDG_RUNTIME_DIR and re-used with -r, so repeated keypresses
  # update one on-screen card in place instead of stacking. Bound to
  # the XF86 audio/brightness keys in ../labwc/rc.xml.
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
  # Unicode data already packaged in nixpkgs. See ../unicode/
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
        python3 ${../unicode/build-index.py} \
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

  # labwc titlebar theme carrying the GNOME/Adwaita window-button icons.
  # labwc finds button images by theme name on XDG_DATA_DIRS/themes, so
  # the SVGs must live in share/themes (linked via pathsToLink) rather
  # than /etc/xdg. rc.xml references it as <theme><name>NanoAdwaita.
  # Inactive-window buttons are derived from the active SVGs by dimming
  # (white → the inactive label grey), so only the active icons are
  # kept in-tree under ../labwc/theme.
  nanoLabwcTheme = pkgs.runCommand "nano-labwc-theme" { } ''
    dst=$out/share/themes/NanoAdwaita/labwc
    mkdir -p "$dst"
    cp ${../labwc/theme/NanoAdwaita/labwc}/themerc "$dst/"
    for f in ${../labwc/theme/NanoAdwaita/labwc}/*-active.svg; do
      base=$(basename "$f" -active.svg)
      cp "$f" "$dst/$base-active.svg"
      sed -e 's/#ffffff/#9a9a9a/g' \
          -e 's/fill-opacity="0.09"/fill-opacity="0.05"/g' \
          "$f" > "$dst/$base-inactive.svg"
    done
  '';
in
{
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
    # nanoDesktop.officeSuite and ../pkgs/office.nix.
    ++ office.packages
    ++ cfg.extraPackages;

  # ── Document types ──────────────────────────────────────────
  xdg.mime = {
    enable = mkDefault true;
    # office.mimeApps is merged in at the end: empty unless
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
    // office.mimeApps;
  };
}
