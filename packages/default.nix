{
  lib,
  pkgs,
  unstablePkgs,
  import-tree,
}: let
  callPackage = lib.callPackageWith (pkgs // {inherit unstablePkgs;});

  # Retrieve files under the package directory.
  # Note: import-tree.files returns a flat list of paths to .nix files.
  files = ((import-tree.withLib lib).addPath ./.).files;
  relevantFiles = builtins.filter (p: builtins.baseNameOf p != "default.nix") files;

  # Map files to names (stripping .nix extension)
  fileNames = builtins.map (p: lib.removeSuffix ".nix" (builtins.baseNameOf p)) relevantFiles;

  # Safeguard: Assert that there are no name collisions (e.g. from nested files).
  # Currently we assume a flat structure where each package attribute name is unique.
  hasCollisions = builtins.length fileNames != builtins.length (lib.unique fileNames);

  packagesList =
    builtins.map (path: {
      name = lib.removeSuffix ".nix" (builtins.baseNameOf path);
      value = callPackage path {};
    })
    relevantFiles;
in
  if hasCollisions
  then throw "local-packages: Duplicate package filenames detected. Nested path structure is not supported by the flat naming strategy."
  else builtins.listToAttrs packagesList
