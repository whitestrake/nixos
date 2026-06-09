{...}: {
  # Declare hosts mapping and user mappings explicitly.
  den.hosts = {
    x86_64-linux = {
      pascal.users.whitestrake = {};
      rapier.users.whitestrake = {};
      sortie.users.whitestrake = {};
      orthus = {
        users.whitestrake = {};
        builder = {
          enable = true;
          publicHostKey = "c3NoLWVkMjU1MTkgQUFBQUMzTnphQzFsWkRJMU5URTVBQUFBSUI0YjJjYXpXdWt0OHZyNEV0a1J4b29SQkhrYSswVXVNSTlSejlpeWt3dFcgcm9vdEBvcnRodXM=";
        };
      };
      oculus.users.whitestrake = {};
      omnius.users.whitestrake = {};
      kronos = {
        users.whitestrake = {};
        wsl.enable = true;
      };
    };
    aarch64-linux = {
      jaeger = {
        users.whitestrake = {};
        builder = {
          enable = true;
          publicHostKey = "c3NoLWVkMjU1MTkgQUFBQUMzTnphQzFsWkRJMU5URTVBQUFBSUdmMlhib1Q0L0N3L2JWeDdVSkZEZVdsVjNnRVJQZXhKc2hBQ0hSZTlqY3Ygcm9vdEBqYWVnZXI=";
        };
      };
    };
    aarch64-darwin = {
      andred.users.whitestrake = {};
    };
  };
}
