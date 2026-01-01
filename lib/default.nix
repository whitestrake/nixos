{
  mkCifs = {
    device,
    uid,
    gid ? uid,
    credentials,
  }: {
    inherit device;
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
      "credentials=${credentials}"
      "uid=${toString uid}"
      "gid=${toString gid}"
    ];
  };
}
