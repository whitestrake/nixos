{
  lib,
  pkgs,
}:
pkgs.writeShellApplication {
  name = "vf-exercise";
  runtimeInputs = [
    pkgs.coreutils
    pkgs.gawk
    pkgs.gnugrep
    pkgs.gnused
    pkgs.systemd
    pkgs.ffmpeg-full
    pkgs.libva-utils
  ];
  # Self-contained: don't depend on the host's /run/opengl-driver.
  runtimeEnv = {
    LIBVA_DRIVER_NAME = "iHD";
    LIBVA_DRIVERS_PATH = "${pkgs.intel-media-driver}/lib/dri";
    ONEVPL_SEARCH_PATH = "${pkgs.vpl-gpu-rt}/lib";
  };
  text = builtins.readFile ./vf-exercise.sh;

  meta = {
    description = "Exercise an Intel iGPU VF through the VAAPI and QSV paths media servers use";
    license = lib.licenses.mit;
    mainProgram = "vf-exercise";
    platforms = lib.platforms.linux;
  };
}
