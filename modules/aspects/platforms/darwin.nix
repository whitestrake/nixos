{den, ...}: {
  den.aspects.darwin = {
    includes = [den.aspects.common];

    darwin = {pkgs, ...}: {
      # Fix broken fish signatures after stripping
      nixpkgs.overlays = [
        (final: prev: {
          fish = prev.fish.overrideAttrs (old: {
            postFixup =
              (old.postFixup or "")
              + prev.lib.optionalString prev.stdenv.isDarwin ''
                /usr/bin/codesign --force --sign - $out/bin/fish || true
                /usr/bin/codesign --force --sign - $out/bin/fish_indent || true
                /usr/bin/codesign --force --sign - $out/bin/fish_key_reader || true
              '';
            sandboxProfile = "";
            __sandboxProfile = "";
          });
        })
      ];

      # macOS System Settings
      security.pam.services.sudo_local.touchIdAuth = true;
      system.defaults.LaunchServices.LSQuarantine = false;

      fonts.packages = with pkgs; [
        nerd-fonts.meslo-lg
        nerd-fonts.fira-code
        nerd-fonts.inconsolata
        nerd-fonts.droid-sans-mono
      ];

      environment.systemPackages = with pkgs; [
        watch
        go
        caddy
        xcaddy
        duplicacy
        zulu
        samba
        cacert
      ];

      environment.shells = with pkgs; [fish];

      # Homebrew
      homebrew = {
        enable = true;
        onActivation = {
          autoUpdate = true;
          upgrade = true;
          cleanup = "zap";
          extraFlags = ["--force-cleanup"];
        };
        brews = ["bitwarden-cli"];
        casks = [
          "music-decoy"
          "finetune"
          "visual-studio-code"
          "iina"
          "raycast"
          "warp"
          "obsidian"
          "soduto"
          "kando"
          "jordanbaird-ice@beta"
        ];
      };

      environment.variables = {
        SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
        CURL_CA_BUNDLE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
        NIX_SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
      };

      # Determinate Nix handles nix daemon on macOS
      nix.enable = false;
    };
  };
}
