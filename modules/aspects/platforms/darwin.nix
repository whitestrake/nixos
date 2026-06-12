{...}: {
  den.aspects.darwin = {
    darwin = {
      config,
      lib,
      pkgs,
      ...
    }: {
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
      programs.zsh.enable = true;

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

      # Because we disable nix-darwin's management of the nix daemon, we must
      # manually inject our evaluated nix.settings into Determinate's custom config
      environment.etc."nix/nix.custom.conf".text = with lib; ''
        trusted-users = ${concatStringsSep " " config.nix.settings.trusted-users}
        extra-substituters = ${concatStringsSep " " config.nix.settings.substituters}
        extra-trusted-public-keys = ${concatStringsSep " " config.nix.settings.trusted-public-keys}
      '';
    };
  };
}
