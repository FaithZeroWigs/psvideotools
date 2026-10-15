# psvideotools

A small collection of PowerShell scripts for video/audio processing, built on top of `ffmpeg`/`ffprobe`.

## Requirements

- PowerShell 5.1+
- `ffmpeg` and `ffprobe` available in `PATH`

## AddSubtitles.ps1

Muxes external SRT subtitle files into a video (`.mkv` or `.mp4`), embedding each track's language, an optional tag (forced / director commentary / closed caption / SDH), and setting the default subtitle track.

### What it does

- Finds all `<base>*.srt` files in the same folder as the video and adds each one as a subtitle track.
- Reads the language and an optional tag from each SRT filename: `<base>.<lang>.srt`, `<base>_<lang>.srt`, or `<base>_<tag>_<lang>.srt` (e.g. `Movie_forced_en.srt`, `Movie_director commentary_en.srt`).
- Maps recognized tags to a track title and a disposition flag:
  - `forced` → title `Forced`, forced flag
  - `director commentary` / `commentary` → title `Director Commentary`, commentary flag
  - `closed caption` / `sdh` / `cc` / `hearing impaired` → title `Closed Caption`, hearing-impaired flag
  - any other text → title-cased track title, no flag
- Backs up the original video as `<file>.<ext>.orig` and writes the subtitled result under the original file name.

### Usage

```powershell
# Add all matching SRTs, keeping existing subtitle streams (default)
.\AddSubtitles.ps1 "path\to\video.mkv"

# Drop existing subtitle streams and use only the external SRT files
.\AddSubtitles.ps1 "path\to\video.mkv" -ReplaceExistingSubtitles
```

### Parameters

| Parameter                   | Description                                                            |
|-----------------------------|------------------------------------------------------------------------|
| `-VideoFile`                | Path to the `.mkv` or `.mp4` file (required).                          |
| `-ReplaceExistingSubtitles` | Drop existing subtitle streams and use only the external SRT files.    |

### Behavior details

- Subtitle codec is chosen automatically: `srt` for `.mkv`, `mov_text` for `.mp4`.
- The first English track is set as the default subtitle; all other tracks have the default flag cleared.
- If no matching SRT files are found, the script exits without modifying anything.

## ConvertAudio3.ps1

Converts audio streams that typically lack hardware decoding support to AC3, so files play back on TVs, streamers and other devices that can't decode DTS or E-AC3.

### What it does

- Converts only streams whose codec is in the target list: `dts`, `dca`, `eac3`, `truehd`, `mlp`. Streams that devices already support (AAC, AC3, FLAC, etc.) are left untouched.
- Converts **every** matching stream, not just the first one.
- Copies video and subtitles unchanged, and preserves language tags.
- Backs up the original file as `<file>.<ext>.orig` before replacing it.

### Usage

```powershell
# Keep the originals and add an AC3 copy for each DTS/EAC3/TrueHD stream (default)
.\ConvertAudio3.ps1 "path\to\video.mkv"

# Replace the DTS/EAC3/TrueHD streams with their AC3 versions instead
.\ConvertAudio3.ps1 "path\to\video.mkv" -Replace

# Process every .mkv/.mp4 in a folder, asking for confirmation per file
.\ConvertAudio3.ps1 "path\to\videos" -ConfirmEach
```

### Parameters

| Parameter       | Description                                                                                          |
|-----------------|------------------------------------------------------------------------------------------------------|
| `-InputPath`    | Path to a `.mkv` or `.mp4` file, or to a folder of such files (required). `-InputFile` accepted as an alias. |
| `-Replace`      | Replace the converted streams with AC3 instead of keeping the originals.                             |
| `-ConfirmEach`  | Prompt for confirmation before processing each file. Off by default (no prompts).                    |

### Behavior details

- If no audio stream needs conversion, the script reports "Nothing to do" and exits without modifying the file.
- The AC3 stream derived from the source default stream becomes the new default; the original default flag is cleared.
- New AC3 streams are tagged with a `title` of `AC3 (<language>)`.
- Folder input: all `.mkv`/`.mp4` files in the folder (sorted by name) are processed, each with the same behavior as a single-file run.
- Batch runs continue after a per-file error and exit with code `1` at the end if any file failed.
- Console output is limited to the command being run plus a live progress marker; the full ffmpeg output is written to a log file instead. The log is named `<folder>.log` inside the folder when processing a folder, or `<file>.log` next to the file when processing a single file.
