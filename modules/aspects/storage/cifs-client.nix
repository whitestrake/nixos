{...}: {
  den.aspects.cifs-client = {
    nixos = {
      config,
      lib,
      ...
    }: let
      cfg = config.storage.cifsMounts;
    in {
      options.storage.cifsMounts = lib.mkOption {
        type = lib.types.attrsOf (lib.types.submodule {
          options = {
            device = lib.mkOption {
              type = lib.types.str;
              description = "The CIFS share device path (e.g. //server/share)";
            };
            uid = lib.mkOption {
              type = lib.types.int;
              description = "User ID to own the mounted files";
            };
            gid = lib.mkOption {
              type = lib.types.nullOr lib.types.int;
              default = null;
              description = "Group ID to own the mounted files (defaults to uid)";
            };
            credentials = lib.mkOption {
              type = lib.types.str;
              description = "Path to the credentials file";
            };
          };
        });
        default = {};
        description = "Declarative CIFS mounts";
      };

      config = lib.mkIf (cfg != {}) {
        fileSystems =
          lib.mapAttrs (path: mount: {
            inherit (mount) device;
            fsType = "cifs";
            noCheck = true;
            options = [
              "soft"
              "nofail"
              "_netdev"
              "x-systemd.automount"
              "x-systemd.idle-timeout=60"
              "x-systemd.mount-timeout=5"
              "x-systemd.device-timeout=5"
              "file_mode=0660"
              "dir_mode=0770"
              "credentials=${mount.credentials}"
              "uid=${toString mount.uid}"
              "gid=${toString (
                if mount.gid != null
                then mount.gid
                else mount.uid
              )}"
            ];
          })
          cfg;
      };
    };
  };
}
