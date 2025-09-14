{
  inputs,
  config,
  pkgs,
  lib,
  ...
}: {
  imports = [inputs.i915-sriov.nixosModules.default];

  # i915 SR-IOV driver
  # boot.extraModulePackages = [pkgs.i915-sriov];
  boot.kernelParams = ["intel_iommu=on" "i915.enable_guc=3" "module_blacklist=xe"];

  # Clue from https://discourse.nixos.org/t/best-way-to-handle-boot-extramodulepackages-kernel-module-conflict/30729/6
  # We will override the postInstall to xz the .ko files to "override" the in-tree module
  # Then we will aggregate the modules like NixOS does normally but with ignoreCollisions = true
  # Since our module comes first in the new list, it will override the in-tree one
  boot.extraModulePackages = [
    (pkgs.i915-sriov.overrideAttrs (super: {
      postInstall =
        (super.postInstall or "")
        + ''
          find $out -name '*.ko' -exec xz {} \;
        '';
    }))
  ];
  system.modulesTree = lib.mkForce [
    (
      (
        pkgs.aggregateModules
        (config.boot.extraModulePackages ++ [config.boot.kernelPackages.kernel])
      ).overrideAttrs {
        # earlier items in the list above override the contents of later items
        ignoreCollisions = true;
      }
    )
  ];

  # DEAD END as sr-iov module needs config flags set by DRM_I915 that can't be included when it's disabled
  # Disable stock i915 to ensure we use the patched one
  # boot.kernelPatches = [
  #   {
  #     name = "disable-i915-module";
  #     patch = null;
  #     structuredExtraConfig = with lib.kernel; {
  #       DRM_I915 = lib.mkForce module;
  #       # DRM_I915_GVT = lib.mkForce unset;
  #       # DRM_I915_GVT_KVMGT = lib.mkForce unset;
  #     };
  #   }
  # ];

  # Hardware acceleration
  hardware.graphics = {
    enable = true;
    extraPackages = with pkgs; [
      intel-media-driver # LIBVA_DRIVER_NAME=iHD
      intel-vaapi-driver # LIBVA_DRIVER_NAME=i965
    ];
  };
}
