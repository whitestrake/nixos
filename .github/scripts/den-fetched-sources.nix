# Sources den fetches while this flake evaluates, beyond the flake's own
# inputs: nix-effects and the gen hub with builtins.fetchTarball at the revs in
# den's templates/ci/flake.lock, then every gen library that the hub and each
# library's default.nix load with builtins.fetchTree from their own flake.lock.
# Evaluating this fetches them all into the store; the result lists their paths
# for the Cache sources job to push. Nix substitutes each of them by narHash,
# so a store without GitHub archive access can then evaluate this flake.
{den}: let
  denLock = builtins.fromJSON (builtins.readFile "${den}/templates/ci/flake.lock");
  tarball = name: let
    l = denLock.nodes.${name}.locked;
  in
    builtins.fetchTarball {
      url = "https://github.com/${l.owner}/${l.repo}/archive/${l.rev}.zip";
      sha256 = l.narHash;
    };
  fromDen = builtins.filter (name: denLock.nodes ? ${name}) ["nix-effects" "gen"];

  isGen = l: l.type or null == "github" && builtins.match "gen(-.*)?" l.repo != null;
  # The gen libraries a source's root flake.lock pins, resolving follows paths
  # the way gen's own resolver does.
  genDeps = src: let
    file = "${src}/flake.lock";
    lock = builtins.fromJSON (builtins.readFile file);
    following = node: inp: let
      v = (lock.nodes.${node}.inputs or {}).${inp};
    in
      if builtins.isString v
      then v
      else builtins.foldl' following lock.root v;
    roots = builtins.attrNames (lock.nodes.${lock.root}.inputs or {});
  in
    if builtins.pathExists file
    then builtins.filter isGen (map (inp: lock.nodes.${following lock.root inp}.locked or {}) roots)
    else [];
  item = l: {
    key = "${l.owner}/${l.repo}/${l.rev}";
    locked = l;
  };
  libraries = builtins.genericClosure {
    startSet = map item (
      if denLock.nodes ? gen
      then genDeps (tarball "gen")
      else []
    );
    operator = i: map item (genDeps (builtins.fetchTree i.locked));
  };
in
  map tarball fromDen ++ map (i: (builtins.fetchTree i.locked).outPath) libraries
