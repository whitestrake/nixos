# Sources den fetches while this flake evaluates, beyond the flake's own inputs.
#
# den loads nix-effects and the gen hub with builtins.fetchTarball, at the revs
# in den's templates/ci/flake.lock. The gen hub then loads each gen-* library
# from its own flake.lock, and every library loads its gen-* dependencies from
# *its* flake.lock in turn, so the revisions can differ from the hub's. This
# walks that graph the way gen's root shims resolve it (`dep [ "gen-X" ]`, a
# root input of the library's own lock, following `follows` paths).
#
# Nix substitutes a sha256-pinned fetchTarball from a binary cache before it
# contacts GitHub, and Determinate Nix does the same for a fetchTree with a
# narHash, so caching these lets a store without GitHub archive access (a
# Claude cloud session) evaluate den.
#
# `fetch` turns a github lock node into its source tree; it is an argument so
# the graph walk can be exercised without network access.
{
  den,
  fetch ? locked:
    builtins.fetchTarball {
      url = "https://github.com/${locked.owner}/${locked.repo}/archive/${locked.rev}.zip";
      sha256 = locked.narHash;
    },
}: let
  readLock = src: builtins.fromJSON (builtins.readFile "${src}/flake.lock");
  denLock = builtins.fromJSON (builtins.readFile "${den}/templates/ci/flake.lock");

  # A lock's root input is a node key, or a `follows` path resolved from the root.
  resolve = lock: let
    following = node: inp: let
      v = lock.nodes.${node}.inputs.${inp};
    in
      if builtins.isString v
      then v
      else builtins.foldl' following lock.root v;
  in
    name: following lock.root name;

  isGitHub = locked: (locked.type or null) == "github";
  item = locked: {
    key = "${locked.owner}/${locked.repo}/${locked.rev}";
    inherit locked;
  };

  # The gen-* libraries a source's own lock pins, if it has a lock.
  genDeps = src: let
    lock = readLock src;
    names = builtins.attrNames (lock.nodes.${lock.root}.inputs or {});
    gen = builtins.filter (n: builtins.substring 0 4 n == "gen-") names;
  in
    if builtins.pathExists "${src}/flake.lock"
    then builtins.filter isGitHub (map (n: lock.nodes.${resolve lock n}.locked) gen)
    else [];

  roots = builtins.filter (name: denLock.nodes ? ${name}) ["nix-effects" "gen"];

  closure = builtins.genericClosure {
    startSet = map (name: item denLock.nodes.${name}.locked) roots;
    operator = x:
      if x.locked.repo == "gen" || builtins.substring 0 4 x.locked.repo == "gen-"
      then map item (genDeps (fetch x.locked))
      else [];
  };
in
  map (x: fetch x.locked) closure
