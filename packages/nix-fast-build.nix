{unstablePkgs}:
unstablePkgs.nix-fast-build.overridePythonAttrs (old: {
  postPatch =
    (old.postPatch or "")
    + ''
      substituteInPlace nix_fast_build/options.py \
        --replace-fail \
          '        fail_fast=a.fail_fast,' \
          $'        retries=a.retries,\n        fail_fast=a.fail_fast,'
    ''
    + unstablePkgs.lib.optionalString (old.version == "2.0.2") ''
      substituteInPlace nix_fast_build/__init__.py \
        --replace-fail \
          'assert task.done(), f"Task {task.get_name()} is not done"' \
          'await task'
    '';
})
