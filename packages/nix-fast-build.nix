{unstablePkgs}:
unstablePkgs.nix-fast-build.overridePythonAttrs (old: {
  postPatch =
    (old.postPatch or "")
    + ''
      substituteInPlace nix_fast_build/options.py \
        --replace-fail \
          '        fail_fast=a.fail_fast,' \
          $'        retries=a.retries,\n        fail_fast=a.fail_fast,'
    '';
})
