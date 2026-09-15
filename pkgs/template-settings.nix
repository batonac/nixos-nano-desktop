# What the guided ISO leaves out, so the image fits a GitHub Release (2 GiB
# per asset). The full desktop closure at squashfs compression was measured
# at about 3 GB, and LibreOffice is roughly a third of that. Without a
# browser it would not be a desktop, so Firefox stays.
#
# A file of its own rather than a value in flake.nix, because three things
# read it and the third used to be missed. The installer (flake.nix) bakes
# it into the guided template AND seeds it into the installed machine's
# settings file, so the reconcile on first boot has nothing to fetch and the
# install is complete offline. The settings app (nano-settings/schema.nix)
# reads it to tell the owner that every other choice for the option is a
# download and needs a network — and that app is imported twice: by
# flake.nix for the flake's own package output, and by modules/applications.nix
# for the copy a machine actually installs. While this lived in flake.nix,
# only the first import was told, so on every installed machine the notice
# on the row and the offline gate on Apply were dead code. Both imports now
# default to this file, which is what makes that impossible to repeat.
#
# Installs that do not go through the guided ISO — nix run, nixos-anywhere,
# the unattended ISO — keep the module's default for officeSuite. Their
# settings app shows the same notice, whose wording is not quite theirs (their
# media did ship LibreOffice) but whose gate is: moving to a suite that is not
# installed is a download on any machine, and moving to "none" never is.
{
  nanoDesktop.officeSuite = "none";
}
