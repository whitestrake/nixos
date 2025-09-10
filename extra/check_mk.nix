{inputs, ...}: {
  nixpkgs.overlays = [
    (final: prev: {
      checkmk-agent = import "${inputs.check_mk-pr}/pkgs/by-name/ch/checkmk-agent/package.nix" {
        inherit
          (final)
          fetchurl
          rpmextract
          stdenv
          makeWrapper
          gzip
          lib
          nixosTests
          systemd
          procps
          util-linux
          gnugrep
          perl
          coreutils
          findutils
          iproute2
          ethtool
          multipath-tools
          gnused
          python3
          openssl
          gawk
          zfs
          lvm2
          openvswitch
          chrony
          ipmitool
          freeipmi
          dmraid
          storcli
          megacli
          postfix
          varnish
          ntp
          ;
      };
    })
  ];
  imports = ["${inputs.check_mk-pr}/nixos/modules/services/monitoring/cmk-agent.nix"];
  services.cmk-agent.enable = true;
}
