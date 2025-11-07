{
  inputs,
  config,
  pkgs,
  ...
}: {
  imports = [inputs.i915-sriov.nixosModules.default];

  # i915 SR-IOV driver
  boot.kernelParams = ["intel_iommu=on" "i915-sriov.enable_guc=3" "module_blacklist=xe"];
  boot.initrd.kernelModules = ["i915-sriov"];

  # Override the installPhase step to rename the output package to a different package so we can early load the kernel module
  # This has more reliable module loading
  boot.extraModulePackages = [
    (pkgs.i915-sriov.overrideAttrs (super: {
      installPhase = ''
        ${pkgs.xz}/bin/xz -z -k -f drivers/gpu/drm/i915/i915.ko
        install -D drivers/gpu/drm/i915/i915.ko.xz $out/lib/modules/${config.boot.kernelPackages.kernel.modDirVersion}/kernel/drivers/gpu/drm/i915-sriov/i915-sriov.ko.xz
        ${pkgs.xz}/bin/xz -z -k -f compat/intel_sriov_compat.ko
        install -D compat/intel_sriov_compat.ko.xz $out/lib/modules/${config.boot.kernelPackages.kernel.modDirVersion}/kernel/compat/gpu/drm/i915-sriov/intel_sriov_compat.ko.xz
      '';
    }))
  ];

  # Hardware acceleration
  hardware.graphics = {
    enable = true;
    extraPackages = with pkgs; [
      intel-media-driver # LIBVA_DRIVER_NAME=iHD
      intel-vaapi-driver # LIBVA_DRIVER_NAME=i965
    ];
  };
}
