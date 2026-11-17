{
  # Guest side of the Intel iGPU SR-IOV setup: bind the passed-through VF
  # (Alder Lake-P GT2, 8086:46a6) with the kernel's in-tree xe driver.
  # The hosts run the PF on xe from i915-sriov-dkms, which carries the Gen12
  # INDIRECT_CTX_OFFSET fix the VF side doesn't need.
  #
  # No hardware.graphics here: Plex and Jellyfin bring their own VAAPI
  # stack and only need /dev/dri, and vf-exercise points libva and oneVPL
  # at its own drivers.
  den.aspects.xe-vf = {
    nixos = {pkgs, ...}: {
      boot.kernelParams = [
        # Keep i915 off the VF, which it would otherwise claim first.
        "i915.force_probe=!46a6"
        # xe still lists pre-Lunar Lake parts as force-probe only.
        "xe.force_probe=46a6"
      ];

      environment.systemPackages = [pkgs.myPkgs.vf-exercise];

      # A quick pass over every transcode path at each boot, so a host or guest
      # kernel that breaks the VF fails a unit (and alerts) straight away.
      systemd.services.vf-exercise = {
        description = "Exercise the GPU VF";
        wantedBy = ["multi-user.target"];
        after = ["systemd-modules-load.service"];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${pkgs.myPkgs.vf-exercise}/bin/vf-exercise quick";
          Nice = 10;
          PrivateTmp = true;
        };
      };
    };
  };
}
