{den, ...}: {
  # Declare hosts mapping and user mappings explicitly.
  den.hosts = {
    x86_64-linux = {
      pascal.users.whitestrake.aspect = den.aspects.user-whitestrake;
      rapier.users.whitestrake.aspect = den.aspects.user-whitestrake;
      sortie.users.whitestrake.aspect = den.aspects.user-whitestrake;
      orthus = {
        users.whitestrake.aspect = den.aspects.user-whitestrake;
        builder = {
          enable = true;
          publicHostKey = "c3NoLWVkMjU1MTkgQUFBQUMzTnphQzFsWkRJMU5URTVBQUFBSUI0YjJjYXpXdWt0OHZyNEV0a1J4b29SQkhrYSswVXVNSTlSejlpeWt3dFcgcm9vdEBvcnRodXM=";
        };
      };
      oculus.users.whitestrake.aspect = den.aspects.user-whitestrake;
      omnius.users.whitestrake.aspect = den.aspects.user-whitestrake;
      kronos = {
        users.whitestrake.aspect = den.aspects.user-whitestrake;
        wsl.enable = true;
      };
    };
    aarch64-linux = {
      jaeger = {
        users.whitestrake.aspect = den.aspects.user-whitestrake;
        builder = {
          enable = true;
          publicHostKey = "c3NoLWVkMjU1MTkgQUFBQUMzTnphQzFsWkRJMU5URTVBQUFBSUdmMlhib1Q0L0N3L2JWeDdVSkZEZVdsVjNnRVJQZXhKc2hBQ0hSZTlqY3Ygcm9vdEBqYWVnZXI=";
        };
      };
    };
    aarch64-darwin = {
      andred.users.whitestrake.aspect = den.aspects.user-whitestrake;
    };
  };
}
