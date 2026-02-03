{
  config,
  pkgs,
  lib,
  ...
}: {
  imports = [../secrets];
  sops.secrets.beszelEnv = {};

  services.beszel.agent = {
    enable = lib.mkDefault true;
    package = pkgs.myPkgs.beszel;
    environmentFile = config.sops.secrets.beszelEnv.path;
    environment.SYSTEM_NAME = lib.mkDefault (lib.strings.toSentenceCase config.networking.hostName);
  };

  # Set static user to allow receiving dbus rule
  users.users.beszel-agent.isSystemUser = true;
  users.users.beszel-agent.group = "beszel-agent";
  users.groups.beszel-agent = {};

  # dbus rule to allow ListUnits
  services.dbus.packages = [
    (pkgs.writeTextDir "share/dbus-1/system.d/beszel-agent.conf" ''
      <?xml version="1.0" encoding="UTF-8"?> <!-- -*- XML -*- -->

      <!DOCTYPE busconfig PUBLIC
                "-//freedesktop//DTD D-BUS Bus Configuration 1.0//EN"
                "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">

      <busconfig>
        <policy user="beszel-agent">
          <allow
            send_destination="org.freedesktop.systemd1"
            send_type="method_call"
            send_path="/org/freedesktop/systemd1"
            send_member="org.freedesktop.systemd1.Manager.ListUnits"
          />
        </policy>
      </busconfig>
    '')
  ];
}
