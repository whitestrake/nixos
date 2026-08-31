{
  config,
  lib,
  self,
  ...
}: let
  classify = host:
    if host.class == "nixos"
    then {
      kind = "nixosConfiguration";
      platform = "linux";
    }
    else if host.class == "darwin"
    then {
      kind = "darwinConfiguration";
      platform = "darwin";
    }
    else throw "unsupported CI host class: ${host.class}";

  configurations =
    lib.concatLists
    (lib.mapAttrsToList
      (system: hosts:
        lib.mapAttrsToList
        (name: host: let
          classification = classify host;
        in {
          inherit system name;
          inherit (classification) kind platform;
          output =
            (lib.getAttrFromPath host.intoAttr self)
              .config.system.build.toplevel;
        })
        hosts)
      config.den.hosts);

  project = pathFields:
    lib.foldl'
    (result: configuration: let
      path = map (field: configuration.${field}) pathFields;
    in
      if lib.hasAttrByPath path result
      then throw "duplicate CI projection path: ${lib.concatStringsSep "." path}"
      else
        lib.recursiveUpdate
        result
        (lib.setAttrByPath path configuration.output))
    {}
    configurations;

  bySystem = project ["system" "kind" "name"];
  configurationsByPlatform = project ["platform" "kind" "name"];

  byPlatform = lib.recursiveUpdate configurationsByPlatform {
    linux.check = {
      flake-file = self.checks.x86_64-linux.check-flake-file;
      treefmt = self.checks.x86_64-linux.treefmt;
    };
  };
in {
  flake.ci = {
    inherit byPlatform bySystem;
  };
}
