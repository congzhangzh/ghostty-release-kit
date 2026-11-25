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
	# One size per scene, its first frame's: a scene can change size (focus: the window, then
	# the whole screen), and ffmpeg rebuilds its filters at each change, which starts palettegen
	# over: run 45310313404's focus GIF kept 29 of its 100 frames. (Keeping one filter graph
	# garbled the frames after a second change.) So a frame of another size is fitted into the
	# first size (scaled, letterboxed) as a copy, and the scene's list is rewritten to use it.
	list=$d/frames.txt
	first=$(sed -n 's/^file //p' "$list" | head -1 | tr -d '\r')
	size0=$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0 "$d/$first")
	w0=${size0%,*} h0=${size0#*,}
	norm=$out/.norm-$scene
	rm -rf "$norm" && mkdir -p "$norm"
	fitted=0
	# ffmpeg reads stdin (its keyboard commands) unless -nostdin: here stdin is the list, and each
	# fitted frame ate bytes of the next lines ("duration" read as "ration", run 45638034138).
	while IFS= read -r line; do
		line=${line%$'\r'}
		case $line in
		"file "*)
			f=${line#file }
			size=$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0 "$d/$f")
			if [ "$size" != "$size0" ]; then
				ffmpeg -nostdin -v error -y -i "$d/$f" -vf "scale=$w0:$h0:force_original_aspect_ratio=decrease:flags=lanczos,pad=$w0:$h0:(ow-iw)/2:(oh-ih)/2:color=0x1d1f21" "$norm/$f"
				fitted=$((fitted + 1))
				echo "file '$norm/$f'"
			else
				echo "file '$d/$f'"
			fi ;;
		*) echo "$line" ;;
		esac
	done < "$list" > "$norm/frames.txt"
	list=$norm/frames.txt
	[ "$fitted" -eq 0 ] || echo "$scene: $fitted frames fitted into ${w0}x${h0}"
	for try in "880 10 128" "760 10 96" "640 8 64"; do
		set -- $try
		ffmpeg -v error -y -f concat -safe 0 -i "$list" \
			-vf "fps=$2,scale=$1:-2:flags=lanczos,split[a][b];[a]palettegen=max_colors=$3:stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle" \
			-loop 0 "$gif"
		size=$(stat -c %s "$gif")
		[ "$size" -le "$max" ] && break
	done
	echo "$(basename "$gif"): $size bytes ($1 px, $2 fps, $3 colours)"
	seg=$out/.seg-$scene.mp4
	ffmpeg -v error -y -f concat -safe 0 -i "$list" \
		-vf "fps=30,scale=1280:720:force_original_aspect_ratio=decrease:flags=lanczos,pad=1280:720:(ow-iw)/2:(oh-ih)/2:color=0x1d1f21,format=yuv420p" \
		-c:v libx264 -preset slow -crf 24 -movflags +faststart "$seg"
	segs+=("$seg")
	rm -rf "$norm"
done
[ ${#segs[@]} -gt 0 ] || { echo "no scenes in $in" >&2; exit 1; }
list=$out/.segs.txt
: > "$list"
for s in "${segs[@]}"; do echo "file '$s'" >> "$list"; done
ffmpeg -v error -y -f concat -safe 0 -i "$list" -c copy -movflags +faststart "$out/demo-all.mp4"
rm -f "${segs[@]}" "$list"
echo "demo-all.mp4: $(stat -c %s "$out/demo-all.mp4") bytes"
