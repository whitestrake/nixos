{inputs, ...}: {
  imports = [
    inputs.den.flakeModule
    (inputs.den.namespace "whitestrake" true)
  ];
}
