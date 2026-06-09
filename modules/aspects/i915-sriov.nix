{inputs, ...}: {
  flake-file.inputs.i915-sriov = {
    url = "github:strongtz/i915-sriov-dkms/2026.03.05.2";
    inputs.nixpkgs.follows = "nixpkgs-unstable";
  };

  den.aspects.i915-sriov = {
    nixos = {pkgs, ...}: {
      imports = [inputs.i915-sriov.nixosModules.default];
      boot.extraModulePackages = [pkgs.i915-sriov];
      boot.kernelParams = ["intel_iommu=on" "i915-sriov.enable_guc=3" "module_blacklist=xe"];

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
