{...}: {
  users.users.mediaserver = {
    isSystemUser = true;
    group = "mediaserver";
    uid = 1001;
  };
  users.groups.mediaserver.gid = 1001;
}
