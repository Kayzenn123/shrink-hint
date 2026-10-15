# shrink-hint

> Interactive TUI advisor: scan media files, get concrete ffmpeg compression suggestions. Daily Tools #9.

## Why

Folders full of raw screen recordings, WAV voice takes, and giant PNG screenshots are
easy to accumulate and annoying to triage: `ffprobe` shows you numbers, but never tells
you what to *do*. shrink-hint probes each file (codec, resolution, bitrate, duration)
and pairs it with one actionable verdict — `SHRINK`, `OK`, or `UNKNOWN` — plus a
copy-paste-ready `ffmpeg` command and an estimated resulting size.

Unlike `compression-cli` (PNG-only, needs Node + sharp) or raw MediaInfo dumps,
shrink-hint covers video, audio, and images in one zero-dependency Bash script
(only `ffprobe` required), never touches your files (read-only), and puts the
advice in a keyboard-driven TUI instead of a wall of text.

## Install

```bash
git clone https://github.com/Kayzenn123/shrink-hint.git
cd shrink-hint
chmod +x bin/shrink-hint
# optional: ln -s "$PWD/bin/shrink-hint" ~/.local/bin/shrink-hint
```

Requires: Bash 4+, `ffprobe` (ships with ffmpeg). No other dependencies.

## Usage

```bash
shrink-hint [options] <file|dir>...     # TUI when stdout is a terminal
shrink-hint -r <dir>...                 # scan folders recursively
shrink-hint --table <dir>               # plain table (default when piped)
shrink-hint --json <dir>                # machine-readable JSON
find clips -type f | shrink-hint --table # read file list from stdin
```

| Flag | Function | Default |
| --- | --- | --- |
| `-r, --recursive` | recurse into directories | off |
| `--table` | print a plain table instead of TUI | auto (non-TTY) |
| `--json` | print machine-readable JSON | off |
| `--tui` | force the interactive TUI | auto (TTY) |
| `--help` | show help | — |
| `--version` | show version | — |

TUI keys: `↑/↓` or `j/k` to move, `q` or `Esc` to quit. Colors are disabled
automatically when output is not a TTY, and `NO_COLOR=1` is honored.

Exit codes: `0` ok · `1` runtime error (e.g. ffprobe missing) · `2` usage error.

## Example output

Command:

```bash
NO_COLOR=1 bin/shrink-hint --table runs/src/archive
```

Output (real, copied from an actual run):

```text
VERDICT  FILE                                             SIZE  DETAIL
SHRINK   screen-recording.mp4                             677K  Re-encode mpeg4 -> h264 (crf 23)
SHRINK   podcast-take1.wav                                431K  Compress lossless/PCM -> opus 96k
OK       screenshot-dashboard.png                         208K  Small png, not worth converting
OK       foto-liburan.jpg                                 1.1M  JPEG size already modest
SHRINK   musik-320.mp3                                    159K  Downsize mp3 320k -> opus 128k
```

Selecting `screen-recording.mp4` in the TUI shows the detail pane (real run):

```text
DETAIL runs/src/archive/screen-recording.mp4
  meta: mpeg4 1280x720 0:05 677K
  verdict: SHRINK — Re-encode mpeg4 -> h264 (crf 23)
  run: ffmpeg -i "screen-recording.mp4" -c:v libx264 -crf 23 -preset medium -c:a aac -b:a 128k "OUTPUT.mp4"
  est. size: ~203K (typical -70%)
```

JSON mode feeding a summary script (real run):

```bash
bin/shrink-hint -r --json runs/src/archive | python3 -c "
import json,sys
d=json.load(sys.stdin)
print(len(d['files']),'files,',
      sum(1 for f in d['files'] if f['verdict']=='SHRINK'),'shrinkable')
"
```

```text
6 files, 4 shrinkable
```

## How it works

1. Each input file is probed with `ffprobe -of flat` (key=value lines, no `jq`
   needed); the lowest-index video and audio streams are kept.
2. A pure suggestion engine maps codec + bitrate + resolution + size to a
   verdict:
   - legacy video codecs (mpeg4, mpeg2, wmv…) → re-encode to h264 crf 23;
   - h264 above a per-resolution bitrate ceiling → re-encode to hevc crf 28;
   - PCM/FLAC/WAV → opus 96k; oversized mp3 → opus 128k;
   - big PNG/BMP/TIFF → webp q80; big JPEG → re-encode q4; GIF → mp4.
3. Size estimates multiply the current size by a typical-ratio factor and are
   always shown with `~` and the word "typical" — they are guidance, not promises.
4. Output is a Bash-native TUI (`tput` + ANSI, arrow-key navigation), a plain
   table, or JSON. The tool is strictly read-only.

File layout: `bin/shrink-hint` (single script, ~370 lines; suggestion functions
are sourceable for unit tests), `test.sh` (19 tests, fixtures generated with
ffmpeg lavfi — no binaries committed).

## Limitations

- Estimates are typical-ratio rules of thumb (e.g. h264→hevc ~50%), not
  measurements of your content; noisy/fast-motion footage compresses worse.
- Verdicts are heuristics: a "bloated" h264 that you want to keep lossless for
  editing will still be flagged SHRINK — the tool cannot know your intent.
- Suggested `ffmpeg` commands are printed for you to copy, never executed;
  you must replace `INPUT`/`OUTPUT.mp4` and check codec availability
  (e.g. `libx265`, `libopus`) in your ffmpeg build.
- Only the first video and first audio streams are analyzed; subtitles,
  chapters, and HDR metadata are ignored.
- Files `ffprobe` cannot parse are reported as `UNKNOWN`, not skipped silently.

## Development

```bash
bash test.sh   # 19 tests: unit + CLI + end-to-end; fixtures generated on the fly
```

## License

MIT

---
Ringkasan (Bahasa Indonesia): shrink-hint adalah penasihat kompresi media
berbasis terminal — pindai file video/audio/gambar, lihat metadata penting
(codec, resolusi, bitrate), lalu dapatkan verdict SHRINK/OK plus perintah
ffmpeg siap copy-paste dan estimasi ukuran hasil. Antarmuka utama berupa TUI
interaktif murni Bash (tanpa library), dengan mode `--table` dan `--json`
untuk pipeline. Tool ini read-only (tidak mengubah file) dan hanya butuh
ffprobe. Batasan utama: estimasi ukuran adalah rentang tipikal, bukan janji;
perintah yang disarankan tidak dijalankan otomatis.
