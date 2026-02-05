{pkgs, ...}:
pkgs.lz4.overrideAttrs (old: {
  postInstall =
    (old.postInstall or "")
    + ''
      ln -s lz4 $out/bin/lz4c
    '';
})
