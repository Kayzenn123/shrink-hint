#!/usr/bin/env bash
# test.sh — test suite for shrink-hint. No dependencies; fixtures are
# generated with ffmpeg (lavfi) into test/.fixtures at run time.
set -uo pipefail
cd "$(dirname "$0")"
BIN="$PWD/bin/shrink-hint"
FIX="$PWD/test/.fixtures"

pass=0; fail=0
ok()   { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
notok(){ fail=$((fail+1)); printf 'FAIL %s\n%s\n' "$1" "${2:-}"; }

# --- source the script for unit tests (main guard prevents execution)
# shellcheck disable=SC1090
source "$BIN"

mkfixtures() {
  rm -rf "$FIX"; mkdir -p "$FIX"
  command -v ffmpeg >/dev/null || { echo "ffmpeg needed for fixtures"; exit 1; }
  # old-codec video, high bitrate -> SHRINK to h264
  ffmpeg -v error -y -f lavfi -i "testsrc=size=320x240:duration=3:rate=30" \
    -c:v mpeg4 -b:v 8M "$FIX/oldclip.mp4"
  # h264 at genuinely high bitrate (noise barely compresses) -> SHRINK to hevc
  # (kept < 1MB so the repo stays lean: 320x240, 1s, high target bitrate)
  ffmpeg -v error -y -f lavfi -i "color=size=320x240:duration=1:rate=30:color=black,noise=alls=80:allf=t" \
    -c:v libx264 -b:v 3M -pix_fmt yuv420p "$FIX/h264big.mp4"
  # h264 sane -> OK
  ffmpeg -v error -y -f lavfi -i "testsrc=size=640x480:duration=3:rate=30" \
    -c:v libx264 -crf 28 -preset veryfast -pix_fmt yuv420p "$FIX/h264ok.mp4"
  # uncompressed wav -> SHRINK to opus
  ffmpeg -v error -y -f lavfi -i "sine=frequency=440:duration=2" \
    -c:a pcm_s16le -ar 48000 "$FIX/tone.wav"
  # big noisy png -> SHRINK to webp (kept < 1MB)
  ffmpeg -v error -y -f lavfi -i "color=size=640x480:duration=1:rate=1:color=gray,noise=alls=30:allf=t" \
    -frames:v 1 "$FIX/noisy.png"
  # non-media + corrupt inputs
  echo "hello world" > "$FIX/notes.txt"
  echo "not a video at all" > "$FIX/corrupt.mp4"
  # guard: every fixture must exist (ffmpeg option typos fail silently otherwise)
  for f in oldclip.mp4 h264big.mp4 h264ok.mp4 tone.wav noisy.png notes.txt corrupt.mp4; do
    [ -s "$FIX/$f" ] || { echo "fixture missing: $f"; exit 1; }
  done
}

mkfixtures # generate once; every test below depends on it

# 1: unit — old codec video suggests h264 re-encode
out=$(suggest_video mpeg4 320 240 8000000 3000000)
v=$(printf '%s' "$out" | sed -n 1p); c=$(printf '%s' "$out" | sed -n 3p)
{ [ "$v" = "SHRINK" ] && [[ "$c" == *"libx264"* ]]; } \
  && ok "unit: mpeg4 -> SHRINK libx264" \
  || notok "unit: mpeg4 -> SHRINK libx264" "$out"

# 2: unit — av1 already efficient
out=$(suggest_video av1 1920 1080 2000000 15000000)
[ "$(printf '%s' "$out" | sed -n 1p)" = "OK" ] \
  && ok "unit: av1 -> OK" || notok "unit: av1 -> OK" "$out"

# 3: unit — h264 sane bitrate is OK
out=$(suggest_video h264 640 480 1500000 600000)
[ "$(printf '%s' "$out" | sed -n 1p)" = "OK" ] \
  && ok "unit: h264 sane bitrate -> OK" || notok "unit: h264 sane bitrate -> OK" "$out"

# 3b: unit — h264 bloated bitrate suggests hevc
out=$(suggest_video h264 640 480 12000000 4500000)
v=$(printf '%s' "$out" | sed -n 1p); c=$(printf '%s' "$out" | sed -n 3p)
{ [ "$v" = "SHRINK" ] && [[ "$c" == *"libx265"* ]]; } \
  && ok "unit: h264 bloated -> SHRINK libx265" \
  || notok "unit: h264 bloated -> SHRINK libx265" "$out"

# 4: unit — pcm audio suggests opus
out=$(suggest_audio pcm_s16le 1536000 500000)
v=$(printf '%s' "$out" | sed -n 1p); c=$(printf '%s' "$out" | sed -n 3p)
{ [ "$v" = "SHRINK" ] && [[ "$c" == *"libopus"* ]]; } \
  && ok "unit: pcm -> SHRINK libopus" || notok "unit: pcm -> SHRINK libopus" "$out"

# 5: unit — small png is OK
out=$(suggest_image png 100 100 40000)
[ "$(printf '%s' "$out" | sed -n 1p)" = "OK" ] \
  && ok "unit: small png -> OK" || notok "unit: small png -> OK" "$out"

# 6: unit — big png suggests webp
out=$(suggest_image png 1280 960 2000000)
v=$(printf '%s' "$out" | sed -n 1p); c=$(printf '%s' "$out" | sed -n 3p)
{ [ "$v" = "SHRINK" ] && [[ "$c" == *"libwebp"* ]]; } \
  && ok "unit: big png -> SHRINK libwebp" || notok "unit: big png -> SHRINK libwebp" "$out"

# 7: unit — probe parses ffprobe flat output
probe_file "$FIX/oldclip.mp4"
{ [ "$P_VCODEC" = "mpeg4" ] && [ "$P_W" = "320" ] && [ "$P_H" = "240" ]; } \
  && ok "unit: probe parses mpeg4 clip" \
  || notok "unit: probe parses mpeg4 clip" "vc=$P_VCODEC ${P_W}x${P_H}"

# 8: unit — corrupt file yields empty codecs (unknown)
probe_file "$FIX/corrupt.mp4"
{ [ -z "$P_VCODEC" ] && [ -z "$P_ACODEC" ]; } \
  && ok "unit: corrupt file -> no streams" \
  || notok "unit: corrupt file -> no streams" "vc=$P_VCODEC ac=$P_ACODEC"

# 9: cli — --version exit 0
"$BIN" --version >/dev/null 2>&1 \
  && ok "cli: --version exit 0" || notok "cli: --version exit 0"

# 10: cli — unknown flag exit 2
"$BIN" --nope >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && ok "cli: bad flag exit 2" || notok "cli: bad flag exit 2 (got $rc)"

# 11: cli — missing input path exit 1
"$BIN" "$FIX/does-not-exist.mp4" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && ok "cli: missing path exit 1" || notok "cli: missing path exit 1 (got $rc)"

# 12: cli — ffprobe missing gives a clear error (PATH has a bash shim, no ffprobe)
mkdir -p "$FIX/noprobebin"
printf '#!/bin/sh\nexec /bin/bash "$@"\n' > "$FIX/noprobebin/bash"
chmod +x "$FIX/noprobebin/bash"
out=$(env PATH="$FIX/noprobebin" "$BIN" "$FIX/oldclip.mp4" 2>&1); rc=$?
{ [ "$rc" -eq 1 ] && [[ "$out" == *"ffprobe"* ]]; } \
  && ok "cli: no ffprobe -> clear error exit 1" \
  || notok "cli: no ffprobe -> clear error exit 1" "rc=$rc out=$out"

# 13: e2e — table scan of fixture dir: exit 0, expected verdicts
out=$(NO_COLOR=1 "$BIN" --table "$FIX" 2>/dev/null); rc=$?
{ [ "$rc" -eq 0 ] \
  && [[ "$out" == *"SHRINK"* ]] \
  && grep -q "oldclip.mp4" <<<"$out" \
  && grep -q "tone.wav" <<<"$out" \
  && grep -q "noisy.png" <<<"$out"; } \
  && ok "e2e: --table scan exit 0 with SHRINK rows" \
  || notok "e2e: --table scan" "rc=$rc out=$out"

# 13b: e2e — real high-bitrate h264 file gets hevc suggestion
out=$(NO_COLOR=1 "$BIN" --table "$FIX/h264big.mp4" "$FIX/noisy.png" 2>/dev/null)
{ grep -q "SHRINK" <<<"$out" && grep -q "h264big.mp4" <<<"$out"; } \
  && ok "e2e: h264big/noisy real files -> SHRINK" \
  || notok "e2e: h264big/noisy real files -> SHRINK" "$out"

# 14: e2e — --json is valid JSON with expected fields
out=$("$BIN" --json "$FIX/oldclip.mp4" "$FIX/h264ok.mp4" 2>/dev/null)
echo "$out" | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d['tool']=='shrink-hint'
assert len(d['files'])==2
assert d['files'][0]['verdict']=='SHRINK'
assert 'libx264' in d['files'][0]['command'] or 'libx265' in d['files'][0]['command']
assert d['files'][1]['verdict']=='OK'
" 2>/dev/null \
  && ok "e2e: --json valid, verdicts correct" \
  || notok "e2e: --json valid" "$out"

# 15: e2e — stdin file list works
out=$(printf '%s\n%s\n' "$FIX/tone.wav" "$FIX/notes.txt" | NO_COLOR=1 "$BIN" --table 2>/dev/null); rc=$?
{ [ "$rc" -eq 0 ] && grep -q "tone.wav" <<<"$out" && grep -q "UNKNOWN" <<<"$out"; } \
  && ok "e2e: stdin file list" || notok "e2e: stdin file list" "rc=$rc out=$out"

# 16: e2e — recursive scan finds nested file
mkdir -p "$FIX/nested/deep"; cp "$FIX/tone.wav" "$FIX/nested/deep/"
out=$(NO_COLOR=1 "$BIN" --table -r "$FIX/nested" 2>/dev/null); rc=$?
{ [ "$rc" -eq 0 ] && grep -q "tone.wav" <<<"$out"; } \
  && ok "e2e: -r recursive scan" || notok "e2e: -r recursive scan" "rc=$rc out=$out"

# 17: NO_COLOR strips ANSI codes
out=$(NO_COLOR=1 "$BIN" --table "$FIX/oldclip.mp4" 2>/dev/null)
[[ "$out" != *$'\e['* ]] \
  && ok "NO_COLOR strips ANSI" || notok "NO_COLOR strips ANSI" "$out"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
