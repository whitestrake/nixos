{den, ...}: let
  # The Bitwarden desktop app's SSH agent socket. This is the Mac App Store
  # build's sandbox container; a .dmg install uses ~/.bitwarden-ssh-agent.sock.
  socket = "Library/Containers/com.bitwarden.desktop/Data/.bitwarden-ssh-agent.sock";
in {
  den.aspects.andred = {
    includes = [den.aspects.dev-tools];

    # launchd hands every app it starts the SSH_AUTH_SOCK of macOS's own
    # ssh-agent, overriding `launchctl setenv`, so point ssh at Bitwarden in the
    # system ssh_config instead. This covers ssh and git from GUI apps too.
    darwin.programs.ssh.extraConfig = ''
      Host *
        IdentityAgent ~/${socket}
    '';

    # Shells: ssh-add and git's SSH commit signing read SSH_AUTH_SOCK directly.
    provides.whitestrake.homeManager = {config, ...}: {
      home.sessionVariables.SSH_AUTH_SOCK = "${config.home.homeDirectory}/${socket}";
    };
  };
}
