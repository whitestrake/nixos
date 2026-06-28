# Copy this file to modules/aspects/hosts/<hostname>/<hostname>.nix.
# The example is inert while it lives directly under modules/aspects/hosts/.
{
  den,
  inputs,
  ...
}: let
  hostName = builtins.baseNameOf ./.;
in
  if hostName == "hosts"
  then {}
  else {
    flake-file.inputs.disko = {
      url = "github:nix-community/disko/latest";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    den.aspects.${hostName} = {
      includes = [
        den.aspects.server
        den.aspects.docker
      ];

      nixos = {config, ...}: {
        imports = [
          inputs.disko.nixosModules.disko
          (import ../_disko.uefi.default.nix {
            disks = ["/dev/vda"];
            zpoolName = config.networking.hostName;
          })
          # Created by `nixos-anywhere --generate-hardware-config`.
          ./_hardware.nix
        ];

        system.stateVersion = "26.05";

        # OVMF / UEFI VM: systemd-boot reads kernels from the ESP at /boot.
        boot.loader.systemd-boot.enable = true;
        boot.loader.systemd-boot.editor = false;
        boot.loader.systemd-boot.configurationLimit = 20;
        boot.loader.efi.canTouchEfiVariables = true;
        boot.zfs.devNodes = "/dev/disk/by-partuuid";
        boot.zfs.forceImportRoot = false;
        services.qemuGuest.enable = true;
        services.zfs.autoScrub.enable = true;

        networking.hostId = throw ''
          Replace networking.hostId for ${hostName}.

          Generate one with:
            nix run nixpkgs#openssl -- rand -hex 4
        '';
      };
    };
  }
