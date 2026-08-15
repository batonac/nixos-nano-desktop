# The accent palette, generated at build time from ../accent.nix and read by
# nano-settings at runtime.
#
# The same trade ./schema.nix makes, for the same reason. The settings app
# draws the accent as nine coloured circles, and the colour in the circle has
# to be the colour this desktop will actually paint: the one modules/desktop.nix
# splices into labwc, sfwbar, foot, fuzzel and mako, and the one
# modules/applications.nix rebuilds the GTK3 theme around. Restating the hex
# values in Python would make the app a fourth place that must agree with the
# other three — and a swatch that is nearly right is the kind of wrong nobody
# sees and everybody notices.
#
# Only the palette. The names, their order and the default all reach the app
# already, through the option's enum in ./schema.nix.
{ lib, pkgs }:
let
  accents = import ../accent.nix { inherit lib; };
in
pkgs.writeText "nano-desktop-palette.json" (builtins.toJSON accents.palette)
