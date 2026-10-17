# Sources den fetches with builtins.fetchTarball while this flake evaluates:
# nix-effects and the gen hub, at the revs in den's templates/ci/flake.lock.
# Nix substitutes a sha256-pinned fetchTarball from a binary cache before it
# contacts GitHub, so caching these lets a store without GitHub archive access
# load them. (gen's libraries then load each other with builtins.fetchTree,
# which Nix never substitutes, so caching those would not help.)
{den}: let
  lock = builtins.fromJSON (builtins.readFile "${den}/templates/ci/flake.lock");
  tarball = name: let
    l = lock.nodes.${name}.locked;
  in
    builtins.fetchTarball {
      url = "https://github.com/${l.owner}/${l.repo}/archive/${l.rev}.zip";
      sha256 = l.narHash;
    };
in
  map tarball (builtins.filter (name: lock.nodes ? ${name}) ["nix-effects" "gen"])
