{
  self,
  lib,
  ...
}: {
  flake = {
    # CI targets grouped by architecture to facilitate parallel, matrixed builds on GitHub Actions
    ci = let
      supportedSystems = ["x86_64-linux" "aarch64-linux" "aarch64-darwin"];
      getConfigSystem = conf: conf.pkgs.system;
      nixosForSystem = sys: lib.filterAttrs (_: conf: getConfigSystem conf == sys) self.nixosConfigurations;
      darwinForSystem = sys: lib.filterAttrs (_: conf: getConfigSystem conf == sys) self.darwinConfigurations;

      # Check if a custom package is actively enabled on a configuration (NixOS or Darwin)
      isPackageEnabled = pkgName: conf: let
        cfg = conf.config;
        getPkgName = p: p.pname or p.name or "";

        # 1. Search in environment.systemPackages
        inSystemPackages = lib.any (p: lib.hasInfix pkgName (getPkgName p)) (cfg.environment.systemPackages or []);

        # 2. Search in Home Manager users packages
        inHomePackages =
          if cfg ? home-manager.users
          then
            lib.any (
              userConf:
                lib.any (p: lib.hasInfix pkgName (getPkgName p)) (userConf.home.packages or [])
            ) (builtins.attrValues cfg.home-manager.users)
          else false;

        # 3. Search in systemd service definitions (Linux)
        inSystemdServices =
          if cfg ? systemd.services
          then
            lib.any (
              serviceName: let
                service = cfg.systemd.services.${serviceName};
                execStartStr =
                  if service ? serviceConfig.ExecStart
                  then builtins.toString service.serviceConfig.ExecStart
                  else "";
                servicePkg =
                  if service ? package && service.package != null
                  then getPkgName service.package
                  else "";
              in
                lib.hasInfix pkgName serviceName
                || lib.hasInfix pkgName servicePkg
                || lib.hasInfix pkgName execStartStr
            ) (builtins.attrNames cfg.systemd.services)
          else false;

        # 4. Search in launchd agents and daemons (Darwin)
        inLaunchd =
          if cfg ? launchd
          then let
            scanLaunchd = jobs:
              lib.any (
                jobName: let
                  job = jobs.${jobName};
                  program =
                    if job ? serviceConfig.Program
                    then builtins.toString job.serviceConfig.Program
                    else "";
                  programArgs =
                    if job ? serviceConfig.ProgramArguments
                    then builtins.toString job.serviceConfig.ProgramArguments
                    else "";
                in
                  lib.hasInfix pkgName jobName
                  || lib.hasInfix pkgName program
                  || lib.hasInfix pkgName programArgs
              ) (builtins.attrNames jobs);
          in
            scanLaunchd (cfg.launchd.agents or {}) || scanLaunchd (cfg.launchd.daemons or {})
          else false;
      in
        inSystemPackages || inHomePackages || inSystemdServices || inLaunchd;
    in
      lib.genAttrs supportedSystems (sys: {
        # NixOS system toplevels for this architecture
        nixos = lib.mapAttrs (_: conf: conf.config.system.build.toplevel) (nixosForSystem sys);

        # Darwin system configurations for this architecture
        darwin = lib.mapAttrs (_: conf: conf.system) (darwinForSystem sys);

        # Custom packages that are actually enabled on at least one configuration on this architecture
        packages = lib.filterAttrs (
          name: _:
            lib.any (conf: isPackageEnabled name conf) (lib.attrValues (nixosForSystem sys) ++ lib.attrValues (darwinForSystem sys))
        ) (self.packages.${sys} or {});

        # Checks for this architecture (filtering out deploy-rs to prevent duplication)
        checks = lib.filterAttrs (name: _: !(lib.hasPrefix "deploy" name)) (self.checks.${sys} or {});
      });
  };
}
