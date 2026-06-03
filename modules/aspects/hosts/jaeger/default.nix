{
  den,
  inputs,
  ...
}: {
  den.aspects.jaeger = {
    includes = [
      den.aspects.server-base
      den.aspects.docker
      den.aspects.user-builder
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
