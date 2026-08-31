{
  config,
  lib,
  self,
  ...
}: let
  classify = host:
    if host.class == "nixos"
    then "nixosConfigurations"
    else if host.class == "darwin"
    then "darwinConfigurations"
    else throw "unsupported CI host class: ${host.class}";

  targets =
    lib.concatLists
    (lib.mapAttrsToList
      (system: hosts:
        lib.mapAttrsToList
        (name: host: {
          inherit system name;
          namespace = classify host;
          output =
            (lib.getAttrFromPath host.intoAttr self)
              .config.system.build.toplevel;
        })
        hosts)
      config.den.hosts)
    ++ [
      {
        system = "x86_64-linux";
        namespace = "checks";
        name = "flake-file";
        output = self.checks.x86_64-linux.check-flake-file;
      }
      {
        system = "x86_64-linux";
        namespace = "checks";
        name = "treefmt";
        output = self.checks.x86_64-linux.treefmt;
      }
    ];

  project = pathFields:
    lib.foldl'
    (result: target: let
      path = map (field: target.${field}) pathFields;
    in
      if lib.hasAttrByPath path result
      then throw "duplicate CI projection path: ${lib.concatStringsSep "." path}"
      else
        lib.recursiveUpdate
        result
        (lib.setAttrByPath path target.output))
    {}
    targets;

  systemRoots = project ["system" "namespace" "name"];

  mergeCiRoots = roots:
    lib.foldl'
    (merged: root:
      lib.recursiveUpdateUntil
      (path: lhs: rhs:
        if
          lib.isDerivation lhs
          || lib.isDerivation rhs
          || !(builtins.isAttrs lhs && builtins.isAttrs rhs)
        then throw "duplicate CI alias path: ${lib.concatStringsSep "." path}"
        else false)
      merged
      root)
    {}
    roots;
in {
  flake.ci =
    systemRoots
    // {
      linux = mergeCiRoots [
        systemRoots.x86_64-linux
        systemRoots.aarch64-linux
      ];

      darwin = mergeCiRoots [
        systemRoots.aarch64-darwin
      ];
    };
}
