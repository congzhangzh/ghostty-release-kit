#!/usr/bin/env bash
# fonts-test.v3.sh <exe> <out> (v3, color = a channel spread > 35 on > 20 pixels: the line is `中文 日本語 ☕ 😀`; color is judged on the shell's echo of ☕
# (U+2615, emoji by default, in the BMP): Wine's console breaks 😀's surrogate pair into U+FFFD, and the
# preedit cannot show color (the core renders it as text, grayscale). Emoji come from Ghostty's own
# embedded Noto Color Emoji, so no "fallback" is logged for them. v2 drew the line as a preedit. v1: which font Ghostty falls back to for Chinese, Japanese and emoji, with
# no font config: types `echo 中文 日本語 😀` through the test pipe, then reads Ghostty's log ("found
# codepoint 0x… in fallback face=…") and counts colored pixels in a pane screenshot (a color emoji).
# Pipe only, so it runs under Wine (RUN=wine, the default; FONTS=<dir> copies open fonts into the
# prefix's Fonts: Noto Sans CJK SC + Noto Color Emoji, pinned in fonts.sha256) and natively on Windows
# (RUN= ; Git Bash, where --ctl, not /ctl: MSYS turns a leading / into a path; measures what Windows
# itself has: YaHei, Yu Gothic, Segoe UI Emoji).
set -u
exe=$1 out=$2; mkdir -p "$out"; out=$(cd "$out" && pwd)
RUN=${RUN-wine} PY=${PY:-python3}
export GHOSTTY_TEST_CONTROL=1 GHOSTTY_WHATSNEW=off GHOSTTY_LOG=stderr
if [ "$RUN" = wine ]; then
	export WINEPREFIX=$out/wineprefix WINEDEBUG=-all WINEDLLOVERRIDES="mscoree,mshtml=" GHOSTTY_PRESENT=readback
	[ -d "$WINEPREFIX" ] || wineboot -i > "$out/wineboot.log" 2>&1
	if [ -n "${FONTS:-}" ]; then
		(cd "$FONTS" && sha256sum -c fonts.sha256 > /dev/null) || { echo "FAIL fonts: checksums"; exit 1; }
		cp "$FONTS"/*.ttf "$FONTS"/*.otf "$WINEPREFIX/drive_c/windows/Fonts/"
	fi
fi
ctl() { timeout 30 $RUN "$exe" --ctl "$1" 2> /dev/null | tr -d '\r'; }
$RUN "$exe" > "$out/ghostty.log" 2>&1 & pid=$!
for _ in $(seq 60); do sleep 1; ctl '{"cmd":"hello"}' | grep -q '"ok":true' && break; done; sleep 4
ctl '{"cmd":"text","text":"echo 中文 日本語 ☕ 😀\r"}' > /dev/null; sleep 4
ctl '{"cmd":"read"}' > "$out/read.json"
ctl '{"cmd":"screenshot","target":"pane","format":"png"}' > "$out/shot.json"
kill $pid 2> /dev/null; [ "$RUN" = wine ] && wineserver -k 2> /dev/null
$PY -I -X utf8 - "$out" << 'PYEOF'
import base64, json, re, struct, sys, zlib
out = sys.argv[1]
log = open(out + "/ghostty.log", encoding="utf-8", errors="replace").read()
found = dict(re.findall(r"found codepoint 0x([0-9A-F]+) in fallback face=(.*)", log))
fails = 0
def fact(name, ok, got):
    global fails
    print(("ok   " if ok else "FAIL ") + name + ("" if ok else f" (got {got})"))
    fails += 0 if ok else 1
screen = json.load(open(out + "/read.json", encoding="utf-8")).get("text", "")
fact("1. CJK and ☕ went through the shell and came back", screen.count("中文 日本語 ☕") >= 2, screen[-80:])
rt = screen.count("😀") >= 2
print("#    the emoji through the shell: " + ("came back" if rt else "broken (" + str(screen.count("\ufffd")) + " U+FFFD): the console, not the font"))
for cp, what in (("4E2D", "中 (Chinese)"), ("65E5", "日 (Japanese, may share 中's face)"), ("672C", "本")):
    print(f"#    {what}: {found.get(cp, '(no fallback logged)')}")
fact("2. a fallback face for 中", "4E2D" in found, "none")
r = json.load(open(out + "/shot.json", encoding="utf-8")); d = base64.b64decode(r["data"])
w, h = struct.unpack(">II", d[16:24]); i = 8; z = b""
while i < len(d):
    n = struct.unpack(">I", d[i:i + 4])[0]; t = d[i + 4:i + 8]
    if t == b"IDAT": z += d[i + 8:i + 8 + n]
    i += 12 + n
raw = zlib.decompress(z); colored = 0
for y in range(h):
    row = raw[y * (1 + 4 * w) + 1:(y + 1) * (1 + 4 * w)]
    for x in range(0, 4 * w, 4):
        r_, g_, b_ = row[x], row[x + 1], row[x + 2]
        if max(r_, g_, b_) - min(r_, g_, b_) > 35: colored += 1  # text on the default bg: <= ~12; ☕ peaks at ~60
print(f"#    colored pixels: {colored}")
fact("3. the emoji is drawn in color", colored > 20, colored)
open(out + "/shot.png", "wb").write(d)
print("PASS" if fails == 0 else f"FAIL ({fails})")
PYEOF
