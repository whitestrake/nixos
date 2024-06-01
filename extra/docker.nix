{
  virtualisation.docker.enable = true;
  virtualisation.docker.autoPrune.enable = true;
  systemd.tmpfiles.rules = ["d /opt/docker 0770 nobody docker"];
}
