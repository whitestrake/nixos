{
  lib,
  pkgs,
}:
pkgs.writeShellApplication {
  name = "i915-sriov-transcode-test";
  runtimeInputs = [
    pkgs.coreutils
    pkgs.ffmpeg
  ];
  text = ''
    if [ "$#" -gt 1 ]; then
      echo "Usage: i915-sriov-transcode-test [render-device]" >&2
      exit 2
    fi

    device="''${1:-/dev/dri/renderD128}"
    if [ ! -c "$device" ]; then
      echo "FAIL: $device is not a character device" >&2
      exit 1
    fi

    workdir="$(mktemp -d)"
    trap 'rm -rf "$workdir"' EXIT

    ffmpeg -nostdin -hide_banner -loglevel error \
      -f lavfi -i "testsrc2=size=1920x1080:rate=30" \
      -frames:v 300 -c:v libx264 -preset ultrafast -pix_fmt yuv420p \
      "$workdir/input.mp4"

    ffmpeg -nostdin -hide_banner -loglevel warning \
      -hwaccel vaapi -hwaccel_device "$device" -hwaccel_output_format vaapi \
      -i "$workdir/input.mp4" \
      -vf "scale_vaapi=w=1280:h=720:format=nv12" \
      -frames:v 300 -c:v h264_vaapi -an \
      "$workdir/output.mp4"

    result="$(
      ffprobe -v error -count_frames -select_streams v:0 \
        -show_entries stream=codec_name,width,height,nb_read_frames \
        -of csv=p=0 "$workdir/output.mp4"
    )"
    if [ "$result" != "h264,1280,720,300" ]; then
      echo "FAIL: unexpected output: $result" >&2
      exit 1
    fi

    echo "PASS: VAAPI decode, scale, and encode via $device ($result)"
  '';

  meta = {
    description = "End-to-end Intel SR-IOV VAAPI transcode test";
    license = lib.licenses.mit;
    mainProgram = "i915-sriov-transcode-test";
    platforms = lib.platforms.linux;
  };
}
