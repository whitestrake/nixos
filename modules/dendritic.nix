{inputs, ...}: {
  imports = [
    (inputs.flake-file.flakeModules.dendritic or {})
    (inputs.den.flakeModules.dendritic or inputs.den.flakeModule)
    (inputs.den.namespace "whitestrake" true)
  ];
}
