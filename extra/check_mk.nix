{inputs, ...}: {
  nixpkgs.overlays = [inputs.check_mk-pr.overlays.default];
  imports = ["${inputs.check_mk-pr}/nixos/modules/services/monitoring/check_mk_agent.nix"];
  services.check_mk_agent.enable = true;
}
