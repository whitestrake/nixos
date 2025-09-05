{
  disks ? ["/dev/sda"],
  zpoolName ? "rpool",
  ...
}: {
  disko.devices = {
    disk = {
      first = {
        type = "disk";
        device = builtins.elemAt disks 0;
        content = {
          type = "gpt";
          partitions = {
            esp = {
              type = "EF00";
              size = "1G";
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot";
                mountOptions = [
                  "defaults"
                ];
              };
            };
            root = {
              size = "100%";
              content = {
                type = "zfs";
                pool = zpoolName;
              };
            };
          };
        };
      };
    };
    zpool = {
      "${zpoolName}" = {
        type = "zpool";
        options = {
          ashift = "12";
        };
        rootFsOptions = {
          mountpoint = "none";
          compression = "zstd";
          acltype = "posixacl";
          xattr = "sa";
          atime = "off";
        };
        datasets = {
          "system" = {
            type = "zfs_fs";
            options.mountpoint = "none";
          };
          "system/root" = {
            type = "zfs_fs";
            mountpoint = "/";
          };
          "local" = {
            type = "zfs_fs";
            options.mountpoint = "none";
          };
          "local/reserved" = {
            type = "zfs_fs";
            options.mountpoint = "none";
            options.refreservation = "2G";
          };
          "local/nix" = {
            type = "zfs_fs";
            mountpoint = "/nix";
          };
          "local/tmp" = {
            type = "zfs_fs";
            mountpoint = "/tmp";
          };
          "user" = {
            type = "zfs_fs";
            options.mountpoint = "none";
          };
          "user/home" = {
            type = "zfs_fs";
            mountpoint = "/home";
          };
          "user/docker" = {
            type = "zfs_fs";
            mountpoint = "/opt/docker";
          };
        };
      };
    };
  };
}
