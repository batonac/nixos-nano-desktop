# The Adwaita accent palette.
#
# Nine colours, named as GNOME's org.gnome.desktop.interface accent-color
# setting names them, valued as adw_accent_color_to_rgba() returns them —
# checked against libadwaita 1.9 rather than copied from a blog post, because
# a value that is nearly right is the kind of wrong nobody sees and everybody
# notices.
#
# Imported by three places that must agree: modules/options.nix (which turns
# `order` into the option's enum, and so into the settings app's dropdown),
# modules/desktop.nix (which splices the hex into the config files of the
# programs that draw their own accent) and modules/applications.nix (which
# rebuilds the GTK3 theme around it). It takes only lib so that options.nix
# stays evaluable on its own — see pkgs/nano-settings/schema.nix.
{ lib }:
{
  # The order GNOME offers them in, which is a colour wheel rather than the
  # alphabet. This is the order the dropdown shows, so it is worth keeping.
  order = [
    "blue"
    "teal"
    "green"
    "yellow"
    "orange"
    "red"
    "pink"
    "purple"
    "slate"
  ];

  palette = {
    blue = "#3584e4";
    teal = "#2190a4";
    green = "#3a944a";
    yellow = "#c88800";
    orange = "#ed5b00";
    red = "#e62d42";
    pink = "#d56199";
    purple = "#9141ac";
    slate = "#6f8396";
  };

  # What the desktop falls back to. Also the colour every config file in
  # ../config is written with, so that a checkout reads as what it renders.
  default = "blue";

  # A hex colour a config file or a systemd Exec line can be given, or null.
  # Everything here that takes a colour from the settings file goes through
  # this: /etc/nixos/nanoDesktop-settings.json is a file people edit by hand
  # and a GUI writes, and neither is a reason for a stray quote to reach a
  # unit file — or for one mistyped character to leave a machine that cannot
  # evaluate. Unparseable means "use the default", the same forgiveness
  # modules/applications.nix extends to a mistyped package name.
  sanitizeColor =
    fallback: value:
    let
      text = lib.toLower (lib.removePrefix "#" (toString value));
      isHex = builtins.match "[0-9a-f]{6}" text != null;
    in
    if isHex then "#${text}" else fallback;
}
