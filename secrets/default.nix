{inputs, ...}: {
  # https://github.com/Mic92/sops-nix
  imports = [inputs.sops-nix.nixosModules.sops];
  sops = {
    # Default secret file
    defaultSopsFile = ../secrets/secrets.yaml;
    # Auto import SSH host key to age
    age.sshKeyPaths = ["/etc/ssh/ssh_host_ed25519_key"];
    # Default key location
    age.keyFile = "/var/lib/sops-nix/key.txt";
    # Create key if it doesn't exist
    age.generateKey = true;
  };
}
