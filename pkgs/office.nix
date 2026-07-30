# The office suite nanoDesktop.officeSuite selects: its packages, and the
# document types to point at them. Lives here rather than in a module because
# both halves are consumed from modules/applications.nix, which owns the
# package list and the MIME table they slot into.
{ pkgs, officeSuite }:
let
  # ── Office suite (officeSuite) ──────────────────────────────
  # LibreOffice reads its settings as a stack of configuration layers
  # (CONFIGURATION_LAYERS in program/fundamentalrc): the package's own
  # read-only registry at the bottom, the user's
  # registrymodifications.xcu at the top. Desktop-wide defaults belong
  # between the two — but the store is read-only, so we cannot drop a
  # .xcd into the package's share/registry, and configmgr's layer count
  # is fixed: appending an extra entry to CONFIGURATION_LAYERS makes
  # soffice abort with an uncaught RuntimeException before it draws
  # anything (measured, not feared).
  #
  # So rather than add a layer, re-point the existing one at a directory
  # of symlinks to every shipped .xcd plus one file of our own.
  # LibreOffice takes the list from the environment: rtl's bootstrap
  # resolves CONFIGURATION_LAYERS from there ahead of fundamentalrc, and
  # still expands the BRAND_BASE_DIR references in the rest of the
  # value. Our file declares <dependency file="main"/>, so configmgr
  # parses it after main.xcd and its values win inside the layer — while
  # the user layer still sits above it. That is what keeps these
  # defaults rather than locks: unlike the dconf profile in
  # modules/desktop.nix, a change made in Tools > Options sticks.
  nanoLibreOfficeXcd = pkgs.writeText "nano-desktop.xcd" ''
    <?xml version="1.0"?>
    <oor:data xmlns:xs="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:oor="http://openoffice.org/2001/registry">
      <dependency file="main"/>
      <oor:component-data oor:name="Common" oor:package="org.openoffice.Office">
        <node oor:name="Misc">
          <!-- Sifr: the flat monochrome icon theme, the closest thing
               LibreOffice ships to the Adwaita look the rest of the
               desktop wears. The dark variant by name rather than
               "sifr" plus LibreOffice's own dark detection, because
               this desktop is dark unconditionally (locked dconf
               color-scheme, adw-gtk3-dark) and light Sifr on a dark
               toolbar is grey-on-grey. -->
          <prop oor:name="SymbolStyle" oor:op="fuse"><value>sifr_dark</value></prop>
        </node>
      </oor:component-data>
    </oor:data>
  '';

  # The shipped registry and our defaults as one directory.
  nanoLibreOfficeRegistry = pkgs.runCommand "nano-libreoffice-registry" { } ''
    mkdir -p $out
    ln -s ${pkgs.libreoffice-fresh.unwrapped}/lib/libreoffice/share/registry/* $out/
    cp ${nanoLibreOfficeXcd} $out/nano-desktop.xcd
  '';

  # The layer list, rebuilt from the package's own fundamentalrc at
  # build time so it tracks the LibreOffice version instead of being a
  # copy pasted in here — and hard-failing if upstream ever stops
  # leading with the shipped registry layer. A defaults file that is
  # silently no longer read is the one outcome worth ruling out.
  nanoLibreOfficeLayers = pkgs.runCommand "nano-libreoffice-layers" { } ''
    layers=$(sed -n 's/^CONFIGURATION_LAYERS=//p' \
      ${pkgs.libreoffice-fresh.unwrapped}/lib/libreoffice/program/fundamentalrc)
    shipped='xcsxcu:''${BRAND_BASE_DIR}/share/registry'
    case "$layers" in
      "$shipped "*) ;;
      *)
        echo "nano-desktop: fundamentalrc no longer starts CONFIGURATION_LAYERS" >&2
        echo "with the shipped registry layer. Got: $layers" >&2
        exit 1
        ;;
    esac
    printf '%s' "xcsxcu:file://${nanoLibreOfficeRegistry}''${layers#"$shipped"}" > $out
  '';

  # soffice and friends with that layer list in their environment.
  # Wrapping the wrapped package instead of overriding it keeps the
  # whole thing to nine tiny scripts — libreoffice-fresh, 1.5 GB
  # unpacked, stays exactly what the binary cache built. Same reasoning
  # as the Firefox wrapper overlay under nixpkgs.overlays in
  # modules/audio.nix.
  # --set-default, so `CONFIGURATION_LAYERS=… soffice` still wins.
  nanoLibreOffice =
    pkgs.runCommand "libreoffice-nano-${pkgs.libreoffice-fresh.version}"
      {
        nativeBuildInputs = [ pkgs.makeWrapper ];
        inherit (pkgs.libreoffice-fresh) meta;
      }
      ''
        mkdir -p $out/bin
        ln -s ${pkgs.libreoffice-fresh}/share $out/share
        layers=$(cat ${nanoLibreOfficeLayers})
        for exe in ${pkgs.libreoffice-fresh}/bin/*; do
          makeWrapper "$exe" "$out/bin/$(basename "$exe")" \
            --set-default CONFIGURATION_LAYERS "$layers"
        done
      '';

  # What officeSuite selects. Attribute values are lazy, so only the
  # chosen branch is ever evaluated — "none" and "gnome" never so much
  # as mention the LibreOffice derivations above.
  officePackages =
    {
      libreoffice = [ nanoLibreOffice ];
      gnome = with pkgs; [
        abiword
        gnumeric
      ];
      none = [ ];
    }
    .${officeSuite};

  # Document types, pointed at the suite in use. Only types the chosen
  # applications actually handle: in "gnome" that leaves .docx and every
  # presentation format unassociated, because AbiWord does not read
  # OOXML text documents and the pair has no presentation program at
  # all. An association that mangles the file is worse than none — those
  # types fall through to the file manager's "Open With" instead.
  officeMimeApps =
    {
      libreoffice = {
        # Writer
        "application/vnd.oasis.opendocument.text" = "writer.desktop";
        "application/vnd.oasis.opendocument.text-template" = "writer.desktop";
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document" = "writer.desktop";
        "application/msword" = "writer.desktop";
        "application/rtf" = "writer.desktop";
        "text/rtf" = "writer.desktop";
        # Calc
        "application/vnd.oasis.opendocument.spreadsheet" = "calc.desktop";
        "application/vnd.oasis.opendocument.spreadsheet-template" = "calc.desktop";
        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" = "calc.desktop";
        "application/vnd.ms-excel" = "calc.desktop";
        "text/csv" = "calc.desktop";
        # Impress
        "application/vnd.oasis.opendocument.presentation" = "impress.desktop";
        "application/vnd.oasis.opendocument.presentation-template" = "impress.desktop";
        "application/vnd.openxmlformats-officedocument.presentationml.presentation" = "impress.desktop";
        "application/vnd.ms-powerpoint" = "impress.desktop";
        # Draw / Math / Base. Note that .odb is
        # opendocument.database to shared-mime-info but
        # opendocument.base in LibreOffice's own base.desktop — the
        # explicit association here is what makes double-click work,
        # since the file manager only ever sees the former.
        "application/vnd.oasis.opendocument.graphics" = "draw.desktop";
        "application/vnd.oasis.opendocument.graphics-template" = "draw.desktop";
        "application/vnd.oasis.opendocument.formula" = "math.desktop";
        "application/vnd.oasis.opendocument.database" = "base.desktop";
      };
      gnome = {
        "application/vnd.oasis.opendocument.text" = "abiword.desktop";
        "application/vnd.oasis.opendocument.text-template" = "abiword.desktop";
        "application/msword" = "abiword.desktop";
        "application/rtf" = "abiword.desktop";
        "application/x-abiword" = "abiword.desktop";
        "application/vnd.oasis.opendocument.spreadsheet" = "org.gnumeric.gnumeric.desktop";
        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" =
          "org.gnumeric.gnumeric.desktop";
        "application/vnd.ms-excel" = "org.gnumeric.gnumeric.desktop";
        "application/x-gnumeric" = "org.gnumeric.gnumeric.desktop";
        "text/csv" = "org.gnumeric.gnumeric.desktop";
      };
      none = { };
    }
    .${officeSuite};
in
{
  packages = officePackages;
  mimeApps = officeMimeApps;
}
