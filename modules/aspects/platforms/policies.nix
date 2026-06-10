{
  den,
  lib,
  ...
}: {
  # Platform aspects are selected automatically from host metadata.
  #
  # Keep host aspects focused on machine-specific and role-specific composition:
  # they should not manually include den.aspects.linux, den.aspects.wsl, or
  # den.aspects.darwin. A host gets exactly one platform aspect here:
  #
  # - darwin hosts get den.aspects.darwin from host.class.
  # - WSL hosts get den.aspects.wsl from host.wsl.enable.
  # - other nixos hosts get den.aspects.linux.
  #
  # Role aspects such as den.aspects.server are layered onto the platform chosen
  # here; they should not include platform aspects themselves.
  den.policies.host-to-platform = {host, ...}: let
    isWsl = (host.wsl or {}).enable or false;
  in
    lib.optionals (host.class == "darwin") [
      (den.lib.policy.include den.aspects.darwin)
    ]
    ++ lib.optionals (host.class == "nixos" && isWsl) [
      (den.lib.policy.include den.aspects.wsl)
    ]
    ++ lib.optionals (host.class == "nixos" && !isWsl) [
      (den.lib.policy.include den.aspects.linux)
    ];

  den.schema.host.includes = [
    den.policies.host-to-platform
  ];
}
