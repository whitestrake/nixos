{...}: {
  # Declare hosts mapping and user mappings explicitly.
  den.hosts = {
    x86_64-linux = {
      pascal.users.whitestrake = {};
      rapier.users.whitestrake = {};
      sortie.users.whitestrake = {};
      orthus.users.whitestrake = {};
      oculus.users.whitestrake = {};
      omnius.users.whitestrake = {};
      kronos.users.whitestrake = {};
    };
    aarch64-linux.jaeger.users.whitestrake = {};
    aarch64-darwin.andred.users.whitestrake = {};
  };
}
