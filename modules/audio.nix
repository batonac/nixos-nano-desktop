# Audio. One switch, two stacks: features.audioServer picks
# PipeWire/WirePlumber, or the server-free apulse/pressureaudio path over
# bare ALSA. The rest of the desktop follows the same flag — the panel's
# volume widget picks its backend in desktop.nix, nano-osd's media keys in
# applications.nix.
{
  config,
  lib,
  pkgs,
  ...
}:
with lib;
let
  cfg = config.nanoDesktop;

  # Bring the hardware mixer up at a level someone can hear. Several
  # machines running the server-free stack booted silent, and the
  # reason is that nothing was setting the mixer at all: with no
  # PipeWire and no ALSA state to restore, the controls sit at whatever
  # the codec driver initialises them to, and for a good number of HDA
  # codecs that is 0 and muted. There is no daemon in that path to
  # notice, so the machine simply has no sound and no visible reason
  # for it.
  #
  # 80% rather than 100%: full scale on these codecs is usually past
  # the point where the built-in speakers distort, and it is a starting
  # point, not a setting — the panel widget and the volume keys take it
  # from here, and alsa-store below remembers where they left it.
  nano-audio-init = pkgs.writeShellApplication {
    name = "nano-audio-init";
    runtimeInputs = [ pkgs.alsa-utils ];
    text = ''
      # Every card, not just card 0: the built-in codec is not reliably
      # first once a USB headset or an HDMI sink is plugged in at boot.
      for dir in /proc/asound/card[0-9]*; do
        [ -d "$dir" ] || continue
        card=''${dir#/proc/asound/card}
        # Codecs disagree about which of these exist and which carry
        # the mute switch, so set whichever are present and let the
        # rest fail. -M is the human-perceived (mapped) volume scale,
        # the same one the panel and the media keys use.
        for control in Master PCM Speaker Headphone Front; do
          amixer -q -c "$card" -M sset "$control" 80% unmute 2>/dev/null || true
        done
      done
    '';
  };
in
{
  # PipeWire + WirePlumber, gated on features.audioServer. When off,
  # the whole server (and rtkit below) is gone and audio goes through
  # apulse/pressureaudio over ALSA instead (see the nixpkgs overlay
  # and the audioServer option). alsa/pulse compat only matter when
  # the server is actually running.
  services.pipewire = {
    enable = mkDefault cfg.features.audioServer;
    alsa.enable = mkDefault true;
    pulse.enable = mkDefault true;
  };

  # RealtimeKit hands out RT scheduling to the PipeWire server; with
  # no server (features.audioServer off) nothing uses it.
  security.rtkit.enable = mkDefault cfg.features.audioServer;

  # Remember the mixer across reboots. This is the other half of the
  # silent-boot fix and the more important one: it adds NixOS's
  # alsa-store unit, which restores /var/lib/alsa/asound.state on boot
  # and writes it back on shutdown, plus the udev rule that restores
  # each card as it appears. Without it nothing persisted a volume
  # change at all — every boot started from the driver defaults.
  #
  # Set here rather than through hardware.alsa.enable (whose default it
  # normally follows) because that option's other job is installing
  # alsa-utils and the plugin path, which applications.nix already
  # does. Wanted under both stacks: PipeWire keeps its own volumes, but
  # it is still mixing into these same hardware controls.
  hardware.alsa.enablePersistence = mkDefault true;

  # Seed that state the first time, when there is none to restore.
  # ConditionPathExists is the whole design: once alsa-store has
  # written asound.state — i.e. after the first clean shutdown — this
  # unit stops running, and the user's own volume is what comes back.
  # It never overrides a setting anyone has made.
  systemd.services.nano-audio-init = {
    description = "Set an audible initial volume on first boot";
    wantedBy = [ "multi-user.target" ];
    after = [
      "sound.target"
      "alsa-store.service"
    ];
    unitConfig.ConditionPathExists = "!/var/lib/alsa/asound.state";
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = getExe nano-audio-init;
    };
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
  # `final.wrapFirefox`, not `prev.wrapFirefox`: applications.nix overrides
  # wrapFirefox too (pointing its ffmpeg_7 argument at ffmpeg-headless, to drop a
  # whole second ffmpeg from the closure). Taking it from the overlay fixpoint
  # composes the two regardless of which overlay the module system happens to
  # order first — with `prev` this one would silently win and discard the other.
  # No cycle: wrapFirefox does not refer back to firefox.
  nixpkgs.overlays = mkIf (!cfg.features.audioServer) [
    (final: prev: {
      firefox =
        (final.wrapFirefox.override { libpulseaudio = prev.libpressureaudio; }) prev.firefox-unwrapped
          { };
    })
  ];
}
