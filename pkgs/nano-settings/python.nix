# The interpreter the tests and the type check run under, in one place so
# that what the dev shell checks and what ./tests.nix checks cannot drift
# apart. PyGObject comes from nixpkgs rather than from a wheel because it is
# a compiled extension bound to this exact GTK and this exact
# GObject-Introspection; the stubs are what give `from gi.repository import
# Adw` a static surface for mypy to check against.
{ pkgs }:
pkgs.python3.withPackages (ps: [
  ps.pygobject3
  ps.pygobject-stubs
  ps.pytest
  ps.pytest-cov
  ps.mypy
])
