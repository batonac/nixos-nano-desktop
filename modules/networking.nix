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
  # ── Networking ──────────────────────────────────────────────
  # iwd + systemd-networkd, no NetworkManager. iwd is the supplicant
  # (~2.7 MB resident against NetworkManager's ~17 MB, measured with
  # both running) and networkd owns IP configuration for every
  # interface, so one DHCP client covers wired and wireless alike.
  #
  # This is a resident-memory win, not a disk win: the measured
  # closure delta is only about -8 MB. NetworkManager itself
  # stays in the store no matter what is set here, because blueman
  # links its GObject typelib for the Bluetooth PAN/DUN plugin — so
  # the ~360 MB closure leaves only if features.bluetooth is off too.
  # The daemon does not run either way, which is the part that counts.
  #
  # networking.useDHCP — on by default, left alone here — is what
  # makes this work with no per-interface configuration: under
  # useNetworkd it expands to the generic 99-ethernet-default-dhcp and
  # 99-wireless-client-dhcp units, which match on interface *type*
  # rather than name (so nothing here needs to know this laptop calls
  # its port enp0s25) and give wifi a higher route metric, so a
  # plugged-in cable wins automatically.
  #
  # The trade, stated plainly. networkd pulls systemd-resolved in with
  # it — NixOS defaults resolved on whenever networkd is enabled, and
  # networkd has no other way to publish DHCP-supplied nameservers —
  # so the resident saving is smaller than the 17 MB above buys you; a
  # caching stub resolver is what you get for the difference. And iwd
  # is 802.11 only: this stack has no VPN plugins, no ModemManager /
  # WWAN, no captive-portal detection and no connection sharing. VPNs
  # become declarative (networking.wireguard and friends) instead of a
  # GUI. A machine that needs any of those — or a card whose driver
  # only ever behaved under wpa_supplicant, older Intel parts with
  # fragile firmware being the usual suspects — should set
  # networking.networkmanager.enable = true alongside
  # networking.useNetworkd = false and wireless.iwd.enable = false.
  #
  # Saved networks live in iwd's own store (/var/lib/iwd) rather than
  # NM's connection store, so a machine migrating off the
  # NetworkManager stack re-enters wifi passphrases once.
  networking = {
    hostName = cfg.hostName;
    networkmanager.enable = mkDefault false;
    wireless.iwd = {
      enable = mkDefault true;
      settings = {
        # Both are iwd's own defaults; spelled out because the split
        # of responsibilities is the whole point of this stack.
        # networkd does addressing, iwd stays a pure supplicant.
        General.EnableNetworkConfiguration = false;
        Settings.AutoConnect = true;
      };
    };
    useNetworkd = mkDefault true;
    firewall = {
      enable = mkDefault false;
      allowedTCPPorts = [
        7236
        7250
      ];
      allowedUDPPorts = [
        7236
        5353
      ];
    };
  };

  # Release network-online.target as soon as *one* interface is up.
  # The upgrade timer below waits on that target, and the default
  # (every managed link must be online) means an unplugged ethernet
  # port on a laptop running fine over wifi holds it until
  # systemd-networkd-wait-online gives up on its timeout.
  systemd.network.wait-online.anyInterface = mkDefault true;

  services.avahi = {
    enable = mkDefault cfg.features.networkDiscovery;
    nssmdns4 = mkDefault true;
    nssmdns6 = mkDefault true;
    # Resolve, don't advertise. Everything this desktop actually
    # wants from mDNS is on the query side: .local name resolution
    # (nssmdns above) and the printer/scanner browsing that
    # system-config-printer and sane-airscan do at add time.
    # Publishing is the other direction — announcing this host and
    # its addresses to the segment — which nothing here consumes,
    # and which costs periodic multicast on an otherwise idle wifi
    # link (radio wakeups on battery) plus a standing description of
    # the machine to anyone on the network. Flip publish.enable back
    # on for a workstation that other hosts need to find by name.
    publish.enable = mkDefault false;
  };

  # No SSH server, and no options to turn one on. This is a
  # single-user micro desktop sitting in front of a person, not a
  # host anyone logs into remotely — a listening sshd would be a
  # standing inbound surface bought with nothing this target uses.
  # A machine that genuinely needs remote access should set
  # services.openssh itself.
}
