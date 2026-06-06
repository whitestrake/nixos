#!/usr/bin/env bash
# CI eval gate: force-evaluate every non-IFD flake output to a .drvPath.
#
# This does NOT build anything and needs NO substituters/cachix — it only needs
# the locked flake inputs. It therefore cannot race the jobs that push to
# whitestrake.cachix.org, and fails fast (~1 min) if the flake does not evaluate.
#
# The IFD-backed deploy checks (deploy-schema, deploy-schema-fast, deploy-activate)
# are intentionally excluded: they are built and executed natively per-system by the
# `validate-deployment` matrix, which has cachix and the correct job ordering. Forcing
# them here would re-introduce the original eval-time IFD race.
set -euo pipefail
FLAKE="${1:-.}"
# Resolve to an absolute path so getFlake accepts it (a bare "." is invalid in a Nix expr).
if [ -e "$FLAKE" ]; then
  FLAKE="$(realpath "$FLAKE")"
fi

nix eval --raw --impure --no-substitute --expr '
let
  flake = builtins.getFlake "'"$FLAKE"'";
  lib   = flake.inputs.nixpkgs.lib;
  isDrv = x: (x.type or null) == "derivation";
  # IFD checks intentionally excluded (covered by validate-deployment):
  ifd   = [ "deploy-schema" "deploy-schema-fast" "deploy-activate" ];
  force = d: builtins.seq d.drvPath d.drvPath;

  forceConfigs = set:
    lib.concatStringsSep "" (lib.mapAttrsToList
      (_: cfg: force cfg.config.system.build.toplevel) set);

  forceSysSet = set:                       # packages / devShells: { sys = { name = drv; } }
    lib.concatStringsSep "" (lib.mapAttrsToList
      (_: s: lib.concatStringsSep "" (lib.mapAttrsToList
        (_: force) (lib.filterAttrs (_: isDrv) s))) set);

  forceChecks = set:                       # checks minus IFD names
    lib.concatStringsSep "" (lib.mapAttrsToList
      (_: cks: lib.concatStringsSep "" (lib.mapAttrsToList
        (_: force) (lib.filterAttrs (n: v: isDrv v && !(builtins.elem n ifd)) cks))) set);

  parts = [
    (forceConfigs (flake.outputs.nixosConfigurations  or {}))
    (forceConfigs (flake.outputs.darwinConfigurations or {}))
    (forceSysSet  (flake.outputs.packages   or {}))
    (forceSysSet  (flake.outputs.devShells  or {}))
    (forceChecks  (flake.outputs.checks     or {}))
  ];
in builtins.deepSeq parts "ok"
'
echo "eval-gate: ok"
