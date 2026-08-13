# The machine-readable form of ../../modules/options.nix, generated at build
# time and read by nano-settings at runtime. Types, enum values and defaults
# come from here rather than being restated in Python, so the GUI cannot drift
# from the module — add an option or a new enum member over there and the app
# picks it up on the next rebuild with nothing else to change.
#
# This works because modules/options.nix is standalone: it takes { lib, ... }
# and declares options and nothing else, so evalModules can run it with no
# pkgs, no disko and no NixOS module set behind it. That is what keeps this
# derivation cheap enough to sit in the closure of an ordinary application.
{ lib, pkgs }:
let
  eval = lib.evalModules { modules = [ ../../modules/options.nix ]; };

  # Whether a JSON settings file can express this option at all. listOf
  # package is the one that cannot — a derivation does not survive
  # fromJSON, which is the whole reason nanoDesktop.extraPackageNames
  # exists — so it is dropped rather than rendered as a row the app could
  # not honour.
  elemName = opt: opt.type.nestedTypes.elemType.name or null;
  representable =
    opt: opt.type.name != "listOf" || (elemName opt != "package" && elemName opt != null);

  # Defaults are read through tryEval: an option declared without one
  # throws on access, and a schema that fails to build over a missing
  # default would take the whole desktop's rebuild with it.
  defaultOf =
    opt:
    let
      attempt = builtins.tryEval (opt.default or null);
    in
    if attempt.success then attempt.value else null;

  render = opt: {
    type = if opt.type.name == "listOf" then "list" else opt.type.name;
    elemType = elemName opt;
    enum = opt.type.functor.payload.values or null;
    default = defaultOf opt;
    # The full reasoning from options.nix. The app shows the curated
    # one-liner from presentation.py on the row and hangs this off the
    # expander beneath it, so the argument for every setting stays one
    # click from the switch that changes it.
    description = opt.description or "";
  };

  # Walk one level of the option tree. Anything carrying _type = "option"
  # is a leaf; anything else is a group (in practice only `features`), and
  # is recursed into once. _module is the module system's own bookkeeping.
  walk =
    attrs:
    lib.pipe attrs [
      (lib.filterAttrs (name: _: name != "_module"))
      (lib.mapAttrs (
        _: value:
        if value._type or null == "option" then
          (if representable value then render value else null)
        else
          walk value
      ))
      (lib.filterAttrs (_: value: value != null))
    ];
in
pkgs.writeText "nano-desktop-schema.json" (builtins.toJSON (walk eval.options.nanoDesktop))
