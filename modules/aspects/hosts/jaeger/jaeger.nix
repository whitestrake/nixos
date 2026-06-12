{den, ...}: {
  den.aspects.jaeger = {
    nixBuilder = {host, ...}: [
      {
        inherit (host) name system;
        publicHostKey = "c3NoLWVkMjU1MTkgQUFBQUMzTnphQzFsWkRJMU5URTVBQUFBSUdmMlhib1Q0L0N3L2JWeDdVSkZEZVdsVjNnRVJQZXhKc2hBQ0hSZTlqY3Ygcm9vdEBqYWVnZXI=";
      }
    ];

    includes = [
      den.aspects.server
      den.aspects.docker
    ];

    nixos = {...}: {
      imports = [
        ./_hardware.nix
      ];
      system.stateVersion = "24.05";

      # Use the systemd-boot EFI boot loader.
      boot.loader.systemd-boot.enable = true;
      boot.loader.efi.canTouchEfiVariables = true;

      # Fixes sshAgentAuth for aarch64 systems
      security.sudo-rs.enable = true;
    };
  };
}
