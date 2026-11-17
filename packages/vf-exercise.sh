#!/usr/bin/env bash
# Exercise an Intel iGPU, usually an SR-IOV VF, through the paths Plex and Jellyfin use:
# VAAPI decode, scale and encode (including low power), 10-bit HEVC, VAAPI and QSV tone
# mapping. Fails if any step fails or the driver logs a hang, reset or error meanwhile.
#
#   quick  (default, about 20 s) one pass of every path on a generated 1080p HDR10 clip
#   full   quick, then a benchmark and a soak of parallel lanes
#
# Options:
#   --device PATH          render node (default /dev/dri/renderD128)
#   --min-entrypoints N    fewest VAAPI entrypoints to accept (default 59, an Alder Lake VF)
#   --minutes N            full: soak length (default 10)
#   --media FILE           full: also loop the first minute of this file, tone-mapped, in the soak
#
# Needs ffmpeg with VAAPI and QSV, vainfo and journalctl. With the Intel media driver and the
# oneVPL runtime outside the default search paths, set LIBVA_DRIVERS_PATH and ONEVPL_SEARCH_PATH.
set -euo pipefail

mode=quick device=/dev/dri/renderD128 min_entrypoints=59 minutes=10 media=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    quick | full) mode=$1 ;;
    --device) device=$2; shift ;;
    --min-entrypoints) min_entrypoints=$2; shift ;;
    --minutes) minutes=$2; shift ;;
    --media) media=$2; shift ;;
    *) sed -n '2,/^set /{/^set /d;s/^# \{0,1\}//;p}' "$0" >&2; exit 2 ;;
  esac
  shift
done
export LIBVA_DRIVER_NAME="${LIBVA_DRIVER_NAME:-iHD}"

start=$(date '+%Y-%m-%d %H:%M:%S')
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failed=0

ff() { ffmpeg -nostdin -hide_banner -loglevel error -y "$@"; }
va=(-init_hw_device "vaapi=va:$device" -filter_hw_device va)
vadec=(-hwaccel vaapi -hwaccel_device va -hwaccel_output_format vaapi)
qsv=(-init_hw_device "vaapi=va:$device" -init_hw_device qsv=qs@va -filter_hw_device qs)
hdr10='setparams=color_primaries=bt2020:color_trc=smpte2084:colorspace=bt2020nc'

frames() { ffprobe -v error -select_streams v:0 -count_packets -show_entries stream=nb_read_packets -of csv=p=0 "$1"; }

# step NAME OUTPUT FRAMES ffmpeg-args...: run, check the frame count, print fps.
step() {
  local name=$1 out=$2 want=$3 t0 t1 got log
  shift 3
  t0=$(date +%s.%N)
  if log=$(ff "$@" "$out" 2>&1) && got=$(frames "$out") && [ "$got" = "$want" ]; then
    t1=$(date +%s.%N)
    printf 'ok    %-16s %s fps\n' "$name" "$(awk -v n="$want" -v a="$t0" -v b="$t1" 'BEGIN { printf "%.0f", n / (b - a) }')"
  else
    printf 'FAIL  %-16s frames %s of %s\n' "$name" "${got:-?}" "$want"
    [ -z "$log" ] || printf '%s\n' "$log" | tail -5 | sed 's/^/      /'
    failed=1
  fi
}

# Hang, reset and error lines from the GPU driver since this run started.
driver_errors() {
  journalctl -k -q --no-pager -o cat --since "$start" 2>/dev/null | grep -E '^(xe|i915) [0-9a-f]{4}:' |
    grep -iE 'timedout job|trying reset|reset started|engine reset|coredump has been created|wedged|gpu hang|context reset|cat error|\*ERROR\*' || true
}

check_log() {
  local e
  e=$(driver_errors)
  if [ -z "$e" ]; then
    echo "ok    kernel log       no GPU hangs, resets or errors"
  else
    echo "FAIL  kernel log"
    printf '%s\n' "$e" | head -5 | sed 's/^/      /'
    failed=1
  fi
}

quick() {
  local i drv n
  for i in $(seq 30); do [ -c "$device" ] && break; sleep 1; done
  if [ ! -c "$device" ]; then echo "FAIL  device           $device not present"; exit 1; fi
  drv=$(basename "$(readlink -f "/sys/class/drm/$(basename "$device")/device/driver")")
  n=$(vainfo --display drm --device "$device" 2>/dev/null | grep -c VAEntrypoint || true)
  if [ "$n" -ge "$min_entrypoints" ]; then
    printf 'ok    %-16s %s, %s VAAPI entrypoints\n' device "$drv" "$n"
  else
    printf 'FAIL  %-16s %s, %s VAAPI entrypoints (want %s)\n' device "$drv" "$n" "$min_entrypoints"
    failed=1
  fi

  local src=$work/hdr10.mkv
  step hevc10-encode "$src" 300 "${va[@]}" -f lavfi -i testsrc2=size=1920x1080:rate=30 -frames:v 300 \
    -vf "$hdr10,format=p010,hwupload" -c:v hevc_vaapi -profile:v main10 -b:v 20M
  [ -s "$src" ] || { echo "FAIL  no source clip, stopping"; exit 1; }
  step h264 "$work/h264.mkv" 300 "${va[@]}" "${vadec[@]}" -i "$src" \
    -vf scale_vaapi=w=1280:h=720:format=nv12 -c:v h264_vaapi -b:v 4M
  step h264-lowpower "$work/h264lp.mkv" 300 "${va[@]}" "${vadec[@]}" -i "$src" \
    -vf scale_vaapi=w=1280:h=720:format=nv12 -c:v h264_vaapi -low_power 1 -b:v 4M
  step hevc "$work/hevc.mkv" 300 "${va[@]}" "${vadec[@]}" -i "$src" \
    -vf scale_vaapi=w=1280:h=720:format=nv12 -c:v hevc_vaapi -b:v 4M
  step tonemap-vaapi "$work/tmva.mkv" 300 "${va[@]}" "${vadec[@]}" -i "$src" \
    -vf tonemap_vaapi=format=nv12:p=bt709:t=bt709:m=bt709,scale_vaapi=w=1280:h=720 -c:v h264_vaapi -b:v 4M
  step tonemap-qsv "$work/tmqsv.mkv" 300 "${qsv[@]}" -hwaccel qsv -hwaccel_output_format qsv -c:v hevc_qsv -i "$src" \
    -vf vpp_qsv=w=1280:h=720:format=nv12:tonemap=1 -c:v h264_qsv -low_power 1 -b:v 4M
}

# Median fps of five runs after a discarded warm-up, 4K HEVC 10-bit to 1080p.
bench() {
  local enc=$1 src=$2 i t0 t1
  for i in 0 1 2 3 4 5; do
    t0=$(date +%s.%N)
    ff "${va[@]}" "${vadec[@]}" -i "$src" -vf scale_vaapi=w=1920:h=1080:format=nv12 -c:v "$enc" -b:v 8M -f null - || return 1
    t1=$(date +%s.%N)
    [ "$i" = 0 ] || awk -v a="$t0" -v b="$t1" 'BEGIN { printf "%.0f\n", 600 / (b - a) }'
  done | sort -n | sed -n 3p
}

lane() {
  local n=0 bad=0 end=$1
  shift
  while [ "$(date +%s)" -lt "$end" ]; do
    if ff "$@" -f null - >/dev/null 2>&1; then n=$((n + 1)); else bad=$((bad + 1)); fi
  done
  echo "$n $bad"
}

full() {
  local src4k=$work/hdr10-4k.mkv src=$work/hdr10.mkv h264 hevc end
  step hevc10-4k "$src4k" 600 "${va[@]}" -f lavfi -i testsrc2=size=3840x2160:rate=30 -frames:v 600 \
    -vf "$hdr10,format=p010,hwupload" -c:v hevc_vaapi -profile:v main10 -b:v 40M
  h264=$(bench h264_vaapi "$src4k") || h264=fail
  hevc=$(bench hevc_vaapi "$src4k") || hevc=fail
  if [ "$h264" = fail ] || [ "$hevc" = fail ]; then
    echo "FAIL  benchmark        h264 $h264, hevc $hevc"; failed=1
  else
    echo "ok    benchmark        4K HEVC10 to 1080p: h264 $h264 fps, hevc $hevc fps (median of 5)"
  fi

  end=$(( $(date +%s) + minutes * 60 ))
  echo "      soak             $minutes min of parallel lanes"
  lane "$end" "${va[@]}" "${vadec[@]}" -i "$src" -vf scale_vaapi=w=1280:h=720:format=nv12 -c:v h264_vaapi >"$work/l1" &
  lane "$end" "${va[@]}" "${vadec[@]}" -i "$src" -vf scale_vaapi=w=1920:h=1080:format=nv12 -c:v hevc_vaapi >"$work/l2" &
  lane "$end" "${qsv[@]}" -hwaccel qsv -hwaccel_output_format qsv -c:v hevc_qsv -i "$src" \
    -vf vpp_qsv=w=1280:h=720:format=nv12:tonemap=1 -c:v h264_qsv -low_power 1 >"$work/l3" &
  if [ -n "$media" ]; then
    lane "$end" "${va[@]}" "${vadec[@]}" -t 60 -i "$media" -map 0:v:0 \
      -vf tonemap_vaapi=format=nv12:p=bt709:t=bt709:m=bt709,scale_vaapi=w=1280:h=720 -c:v h264_vaapi >"$work/l4" &
  fi
  wait
  local ok=0 bad=0 a b f
  for f in "$work"/l[0-9]; do read -r a b <"$f"; ok=$((ok + a)); bad=$((bad + b)); done
  if [ "$bad" = 0 ] && [ "$ok" -gt 0 ]; then
    echo "ok    soak             $ok jobs, none failed"
  else
    echo "FAIL  soak             $bad of $((ok + bad)) jobs failed"; failed=1
  fi
}

echo "vf-exercise $mode on $(hostname) $(uname -r), $device"
quick
[ "$mode" = quick ] || full
check_log
if [ "$failed" = 0 ]; then echo PASS; else echo FAIL; exit 1; fi
