# psvideotools

A small collection of PowerShell scripts for video/audio processing, built on top of `ffmpeg`/`ffprobe`.

## Requirements

- PowerShell 5.1+
- `ffmpeg` and `ffprobe` available in `PATH`

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
```

### Parameters

| Parameter    | Description                                                                    |
|--------------|--------------------------------------------------------------------------------|
| `-InputFile` | Path to the `.mkv` or `.mp4` file (required).                                  |
| `-Replace`   | Replace the converted streams with AC3 instead of keeping the originals.       |

### Behavior details

- If no audio stream needs conversion, the script reports "Nothing to do" and exits without modifying the file.
- The AC3 stream derived from the source default stream becomes the new default; the original default flag is cleared.
- New AC3 streams are tagged with a `title` of `AC3 (<language>)`.
