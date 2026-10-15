{den, ...}: {
  den.aspects.andred = {
    includes = [den.aspects.dev-tools];

    # Use the Bitwarden desktop app's SSH agent. The socket path is the Mac App
    # Store build's sandbox container; a .dmg install uses ~/.bitwarden-ssh-agent.sock.
    provides.whitestrake.homeManager = {
      config,
      lib,
      ...
    }: let
      socket = "${config.home.homeDirectory}/Library/Containers/com.bitwarden.desktop/Data/.bitwarden-ssh-agent.sock";
    in {
      # Shells: ssh, ssh-add, and git's SSH commit signing all read SSH_AUTH_SOCK.
      home.sessionVariables.SSH_AUTH_SOCK = socket;

      # GUI apps launched from Finder or the Dock don't read shell profiles, so
      # also set it in the launchd user session at login.
      launchd.agents.bitwarden-ssh-auth-sock = {
        enable = true;
        config = {
          ProgramArguments = ["/bin/launchctl" "setenv" "SSH_AUTH_SOCK" socket];
          RunAtLoad = true;
        };
      };
    };
  };
}
