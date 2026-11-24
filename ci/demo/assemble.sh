#!/usr/bin/env bash
# assemble.sh (lane B, 2026-11-23): the demo GIFs and MP4 from demo.exe's frames.
#
#   ci/demo/assemble.sh <frames dir> <out dir>
#
# <frames dir> has one folder per scene (<n>-<family>/, with f*.png or f*.bmp and frames.txt,
# ffmpeg's concat list with each frame's real duration). For each: demo-<family>.gif (palette
# made for that scene; 880 px wide, smaller and slower when the GIF would pass 3 MB), and all
# scenes in order as one demo-all.mp4 (H.264, 1280x720 letterboxed). Needs ffmpeg.
set -euo pipefail
in=$(cd "$1" && pwd) out=$2
mkdir -p "$out"
out=$(cd "$out" && pwd)
max=$((3 * 1024 * 1024))
segs=()
for d in "$in"/*/; do
	d=${d%/}
	[ -f "$d/frames.txt" ] || continue
	scene=$(basename "$d")
	family=${scene#*-}
	gif=$out/demo-$family.gif
	for try in "880 10 128" "760 10 96" "640 8 64"; do
		set -- $try
		ffmpeg -v error -y -f concat -safe 0 -i "$d/frames.txt" \
			-vf "fps=$2,scale=$1:-2:flags=lanczos,split[a][b];[a]palettegen=max_colors=$3:stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle" \
			-loop 0 "$gif"
		size=$(stat -c %s "$gif")
		[ "$size" -le "$max" ] && break
	done
	echo "$(basename "$gif"): $size bytes ($1 px, $2 fps, $3 colours)"
	seg=$out/.seg-$scene.mp4
	ffmpeg -v error -y -f concat -safe 0 -i "$d/frames.txt" \
		-vf "fps=30,scale=1280:720:force_original_aspect_ratio=decrease:flags=lanczos,pad=1280:720:(ow-iw)/2:(oh-ih)/2:color=0x1d1f21,format=yuv420p" \
		-c:v libx264 -preset slow -crf 24 -movflags +faststart "$seg"
	segs+=("$seg")
done
[ ${#segs[@]} -gt 0 ] || { echo "no scenes in $in" >&2; exit 1; }
list=$out/.segs.txt
: > "$list"
for s in "${segs[@]}"; do echo "file '$s'" >> "$list"; done
ffmpeg -v error -y -f concat -safe 0 -i "$list" -c copy -movflags +faststart "$out/demo-all.mp4"
rm -f "${segs[@]}" "$list"
echo "demo-all.mp4: $(stat -c %s "$out/demo-all.mp4") bytes"
