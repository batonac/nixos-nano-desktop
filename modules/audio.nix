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
