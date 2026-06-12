{...}: {
  den.aspects.user-mediaserver.nixos.users = {
    users.mediaserver = {
      isSystemUser = true;
      group = "mediaserver";
      uid = 1001;
    };
    groups.mediaserver.gid = 1001;
  };
}
