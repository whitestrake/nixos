{system}: let
  flake = builtins.getFlake (toString ../.);
  package = flake.packages.${system}.nix-fast-build;
in
  assert package.version == "2.0.2";
    package.overridePythonAttrs (old: {
      postPatch =
        (old.postPatch or "")
        + ''
          substituteInPlace nix_fast_build/__init__.py \
            --replace-fail 'assert task.done(), f"Task {task.get_name()} is not done"' 'await task'
        '';
    })
