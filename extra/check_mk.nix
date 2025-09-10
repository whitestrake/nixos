{
  inputs,
  config,
  ...
}: {
  nixpkgs.overlays = [
    (final: prev: {
      checkmk-agent = final.callPackage "${inputs.check_mk-pr}/pkgs/by-name/ch/checkmk-agent/package.nix" {};
    })
  ];
  imports = ["${inputs.check_mk-pr}/nixos/modules/services/monitoring/cmk-agent.nix"];
  services.cmk-agent.enable = true;
  environment.systemPackages = [config.services.cmk-agent.package];
}
