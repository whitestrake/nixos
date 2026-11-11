{
  # Guest side of the Intel iGPU SR-IOV setup: bind the passed-through VF
  # (Alder Lake-P GT2, 8086:46a6) with the kernel's in-tree xe driver.
  # The hosts run the PF on xe from i915-sriov-dkms, which carries the Gen12
  # INDIRECT_CTX_OFFSET fix the VF side doesn't need.
  #
  # No hardware.graphics here: Plex and Jellyfin bring their own VAAPI
  # stack and only need /dev/dri, and i915-sriov-transcode-test points
  # libva at intel-media-driver itself.
  den.aspects.xe-vf = {
    nixos = {
      boot.kernelParams = [
        # Keep i915 off the VF, which it would otherwise claim first.
        "i915.force_probe=!46a6"
        # xe still lists pre-Lunar Lake parts as force-probe only.
        "xe.force_probe=46a6"
      ];
    };
  };
}
