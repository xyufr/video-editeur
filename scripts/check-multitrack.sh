#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
CHECK_DIR="$(mktemp -d /tmp/video-editeur-multitrack.XXXXXX)"
for entry in 'a red' 'b blue' 'c green'; do
  read -r name color <<< "$entry"
  ffmpeg -hide_banner -loglevel error -y -f lavfi -i "color=$color:s=320x180:r=30:d=2" -f lavfi -i "sine=frequency=440:duration=2" -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest "$CHECK_DIR/$name.mp4"
done
# Red picture with black letterbox bars recorded into the file (20 px top and bottom).
ffmpeg -hide_banner -loglevel error -y -f lavfi -i "color=red:s=320x140:r=30:d=2" -vf "pad=320:180:0:20:black" -c:v libx264 -pix_fmt yuv420p "$CHECK_DIR/d.mp4"
# Edit list starting with 0.1 s of no picture (empty edit), as some recorders write.
ffmpeg -hide_banner -loglevel error -y -f lavfi -i "color=red:s=320x180:r=25:d=2" -c:v libx264 -pix_fmt yuv420p -output_ts_offset 0.1 "$CHECK_DIR/e.mp4"
for language in zh en; do
  dist/VideoEditeur.app/Contents/MacOS/VideoEditeur --smoke-multitrack "$CHECK_DIR" -editor.interfaceLanguage "$language"
done
printf 'Artifacts: %s\n' "$CHECK_DIR"
