{
  inputs,
  pkgs,
  ...
}: {
  # i915 SR-IOV driver
  imports = [inputs.i915-sriov.nixosModules.default];
  boot.extraModulePackages = [pkgs.i915-sriov];
  boot.kernelParams = ["intel_iommu=on" "i915-sriov.enable_guc=3" "module_blacklist=xe"];

  # Hardware acceleration
  hardware.graphics = {
    enable = true;
    extraPackages = with pkgs; [
      intel-media-driver # Broadwell+ VA-API driver
      intel-compute-runtime # OpenCL/Tone Mapping
      vpl-gpu-rt # QSV VPL runtime
    ];
  };
}
