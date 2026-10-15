# psvideotools

PowerShell scripts that wrap `ffmpeg`/`ffprobe` for video/audio processing.
`README.md` is the user-facing reference for behavior; keep it in sync when
scripts change.

## Requirements

- PowerShell 5.1+ (Windows PowerShell); keep scripts compatible with PowerShell 7+.
- `ffmpeg` and `ffprobe` available on `PATH`.

## Scripts

- `AddSubtitles.ps1 -VideoFile <path> [-ReplaceExistingSubtitles]` — mux external
  `<base>*.srt` files into a `.mkv`/`.mp4`, setting language, tag-based title and
  disposition, and the default subtitle track.
- `ConvertAudio3.ps1 -InputPath <file|folder> [-Replace] [-ConfirmEach]` — transcode
  DTS/E-AC3/TrueHD/MLP audio streams to AC3 for devices that can't decode them.
  Console shows only the command plus a live progress marker; full ffmpeg output
  goes to a log (`<folder>.log` or `<file>.log` next to the input).

## Commands

- No build step, linter, or test suite exists. Syntax-check a script with the
  PowerShell parser:

  ```powershell
  $errors = $null
  [System.Management.Automation.Language.Parser]::ParseFile(
      (Resolve-Path .\ConvertAudio3.ps1).Path, [ref]$null, [ref]$errors)
  $errors
  ```

- Verify behavior by running against a **copy** of a sample `.mkv`/`.mp4` and
  inspecting the result with `ffprobe` (streams, language, dispositions).

## Conventions

- Use advanced parameters: `param(...)` with `[Parameter(Mandatory = $true)]`.
- Use `-LiteralPath` on file cmdlets; paths may contain spaces or special chars.
- Back up the original as `<file>.<ext>.orig` (via `Rename-Item`) before replacing
  it, and never overwrite an existing `.orig` backup.
- Prefer invoking external tools with an argument array and the call operator
  (`& ffmpeg @args`) over building a command string and running it with
  `Invoke-Expression`. `ConvertAudio3.ps1` uses the array form; `AddSubtitles.ps1`
  still uses `Invoke-Expression` — migrate it when you next touch that file.
- Normalize language codes through the `$lang_maps` hashtable.
- Keep both containers working: `.mkv` uses `srt` subtitles, `.mp4` uses
  `mov_text`, and MP4 subtitle handling may need a no-subtitle retry.

## Gotchas

- Scripts mutate files in place (rename original, write output under the original
  name). Always test on copies.
- There is no `$ErrorActionPreference`/`Set-StrictMode`; check `$LASTEXITCODE`
  after external calls and surface real ffmpeg/ffprobe errors.

## Instruction sources

- `README.md` — documented behavior and parameters.
