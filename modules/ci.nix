{
  config,
  lib,
  self,
  ...
}: let
  targets =
    lib.concatLists
    (lib.mapAttrsToList
      (system: hosts:
        lib.mapAttrsToList
        (_: host: {
          path = [system] ++ host.intoAttr;
          output =
            (lib.getAttrFromPath host.intoAttr self)
              .config.system.build.toplevel;
        })
        hosts)
      config.den.hosts)
    ++ [
      {
        path = ["x86_64-linux" "checks" "flake-file"];
        output = self.checks.x86_64-linux.check-flake-file;
      }
      {
        path = ["x86_64-linux" "checks" "treefmt"];
        output = self.checks.x86_64-linux.treefmt;
      }
    ];

  systemRoots =
    lib.foldl'
    (result: target:
      if lib.hasAttrByPath target.path result
      then throw "duplicate CI projection path: ${lib.concatStringsSep "." target.path}"
      else
        lib.recursiveUpdate
        result
        (lib.setAttrByPath target.path target.output))
    {}
    targets;

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
