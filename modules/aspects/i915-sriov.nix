{inputs, ...}: {
  flake-file.inputs.i915-sriov = {
    url = "github:strongtz/i915-sriov-dkms";
    inputs.nixpkgs.follows = "nixpkgs-unstable";
  };

  den.aspects.i915-sriov = {
    nixos = {
      lib,
      pkgs,
      ...
    }: let
      i915-sriov = pkgs.i915-sriov.overrideAttrs (old: {
        requiredSystemFeatures = (old.requiredSystemFeatures or []) ++ ["big-parallel"];
      });

      # Kernel hold: 6.18.55 backported the one-argument
      # drm_client_dev_suspend/resume, which i915-sriov-dkms master only
      # expects from 6.19. Hold 6.18.54 until the input gains the
      # drm_client_dev_suspend_one_arg conftest (already on its kernel-v6.18
      # branch), then warn so this block gets removed.
      defaultKernel = pkgs.linuxPackages.kernel;
      upstreamFixed = lib.hasInfix "drm_client_dev_suspend_one_arg" (builtins.readFile "${inputs.i915-sriov}/Makefile");
      affected = lib.versionAtLeast defaultKernel.version "6.18.55" && lib.versionOlder defaultKernel.version "6.19";
      heldKernel = pkgs.linux_6_18.override {
        argsOverride = rec {
          version = "6.18.54";
          modDirVersion = version;
          src = pkgs.fetchurl {
            url = "mirror://kernel/linux/kernel/v6.x/linux-${version}.tar.xz";
            hash = "sha256:1b5c7v7vxl27z3xrdnqxgyzdv2b8xy464majpv8bn0l1vl10pwwx";
          };
        };
      };
    in {
      imports = [inputs.i915-sriov.nixosModules.default];
      boot.extraModulePackages = [i915-sriov];
      boot.kernelParams = ["intel_iommu=on" "i915-sriov.enable_guc=3" "module_blacklist=xe"];

      boot.kernelPackages = lib.mkIf (affected && !upstreamFixed) (pkgs.linuxPackagesFor heldKernel);
      warnings = lib.optional (upstreamFixed || lib.versionAtLeast defaultKernel.version "6.19") ''
        i915-sriov: the 6.18.54 kernel hold in modules/aspects/i915-sriov.nix is no longer needed
        (default kernel ${defaultKernel.version}); remove it.
      '';

      hardware.graphics = {
        enable = true;
        extraPackages = with pkgs; [
          intel-media-driver
          intel-compute-runtime
          vpl-gpu-rt
        ];
      };
    };
  };
}
