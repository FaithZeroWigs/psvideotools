param (
    [Parameter(Mandatory = $true)]
    [Alias("InputFile")]
    [string]$InputPath,
    [switch]$Replace,
    [switch]$ConfirmEach
)

# Audio codecs that typically lack device support and should be converted to AC3.
$convertCodecs = @("dts", "dca", "eac3", "truehd", "mlp")

# Ensure ffmpeg/ffprobe are available in PATH
if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) {
    Write-Error "ffmpeg is not found in PATH. Please install ffmpeg and ensure it is accessible."
    exit 1
}
if (-not (Get-Command ffprobe -ErrorAction SilentlyContinue)) {
    Write-Error "ffprobe is not found in PATH. It usually ships with ffmpeg."
    exit 1
}

# Validate input path
if (-not (Test-Path -LiteralPath $InputPath)) {
    Write-Error "Input path '$InputPath' does not exist."
    exit 1
}

# Determine processing targets: a single file, or all .mkv/.mp4 files inside a folder.
$isFolderInput = (Get-Item -LiteralPath $InputPath).PSIsContainer
$targets = @()
if ($isFolderInput) {
    $targets = @(
        Get-ChildItem -LiteralPath $InputPath -File |
            Where-Object {
                ($_.Extension -ieq ".mkv" -or $_.Extension -ieq ".mp4") -and
                -not ($_.BaseName -like "*.temp" -and
                    (Test-Path -LiteralPath (Join-Path $_.DirectoryName (($_.BaseName -replace '\.temp$', '') + $_.Extension))))
            } |
            Sort-Object Name |
            ForEach-Object { $_.FullName }
    )
    if ($targets.Count -lt 1) {
        Write-Error "No .mkv or .mp4 files found in folder '$InputPath'."
        exit 1
    }
} else {
    $targets = @((Resolve-Path -LiteralPath $InputPath).Path)
}

# Detailed ffmpeg output goes to a log: '<folder>.log' inside the folder when
# processing a folder, or '<file>.log' next to the file otherwise.
$inputRoot = (Resolve-Path -LiteralPath $InputPath).Path
if ($isFolderInput) {
    $logPath = Join-Path $inputRoot ((Split-Path -Leaf $inputRoot) + ".log")
} else {
    $logPath = Join-Path ([System.IO.Path]::GetDirectoryName($inputRoot)) ([System.IO.Path]::GetFileNameWithoutExtension($inputRoot) + ".log")
}

function Get-AudioStreams([string]$path) {
    # Grab stdout+stderr so we can surface the real ffprobe error if it fails
    $out = & ffprobe -v error -show_entries stream=index,codec_type,codec_name:stream_disposition=default,forced:stream_tags=language -of json -- $path 2>&1
    $rc = $LASTEXITCODE

    if ($rc -ne 0 -or [string]::IsNullOrWhiteSpace($out)) {
        throw "ffprobe failed ($rc). Output: $out"
    }

    $obj = $out | ConvertFrom-Json
    if (-not $obj.streams) { return @() }

    $result = @()
    $audioIndex = 0
    foreach ($s in @($obj.streams)) {
        if ($s.codec_type -eq "audio") {
            $lang = ""
            if ($s.tags -and $s.tags.language) { $lang = [string]$s.tags.language }

            $isDefault = $false
            $isForced = $false
            if ($s.disposition) {
                $isDefault = [bool]$s.disposition.default
                $isForced = [bool]$s.disposition.forced
            }

            $result += [pscustomobject]@{
                index     = $audioIndex   # audio-relative index (for 0:a:N mapping)
                codec     = [string]$s.codec_name
                lang      = $lang
                isDefault = $isDefault
                isForced  = $isForced
            }
            $audioIndex++
        }
    }
    return $result
}


function Invoke-Convert([string]$inPath, [string]$outPath, $audioStreams, [bool]$keepSubs, [bool]$replace, [string]$ext, [string]$logPath) {
    $convertStreams = @($audioStreams | Where-Object { $convertCodecs -contains $_.codec })

    # Build ordered output-audio stream definitions.
    # mode "copy" => copy the source stream; mode "ac3" => encode source to AC3.
    $defs = @()
    if (-not $replace) {
        # Keep all originals, then append an AC3 twin for each converted stream.
        foreach ($a in $audioStreams) { $defs += [pscustomobject]@{ inputIndex = $a.index; mode = "copy"; src = $a } }
        foreach ($a in $convertStreams) { $defs += [pscustomobject]@{ inputIndex = $a.index; mode = "ac3";  src = $a } }
    } else {
        # Converted streams are replaced by their AC3 version; everything else is copied.
        foreach ($a in $audioStreams) {
            if ($convertCodecs -contains $a.codec) {
                $defs += [pscustomobject]@{ inputIndex = $a.index; mode = "ac3"; src = $a }
            } else {
                $defs += [pscustomobject]@{ inputIndex = $a.index; mode = "copy"; src = $a }
            }
        }
    }

    $ffmpegArgs = @(
        "-hide_banner",
        "-y",
        "-i", $inPath,

        "-map", "0:v?"
    )

    foreach ($d in $defs) { $ffmpegArgs += @("-map", "0:a:$($d.inputIndex)") }

    if ($keepSubs) {
        $ffmpegArgs += @("-map", "0:s?")
    }

    $ffmpegArgs += @("-c:v", "copy")

    for ($j = 0; $j -lt $defs.Count; $j++) {
        $d = $defs[$j]
        if ($d.mode -eq "ac3") {
            $ffmpegArgs += @("-c:a:$j", "ac3")

            $disp = "0"
            if ($d.src.isDefault) { $disp = "default" }
            elseif ($d.src.isForced) { $disp = "forced" }
            $ffmpegArgs += @("-disposition:a:$j", $disp)

            $title = "AC3"
            if ($d.src.lang) { $title = "AC3 ($($d.src.lang))" }
            $ffmpegArgs += @("-metadata:s:a:$j", "title=$title")
        } else {
            $ffmpegArgs += @("-c:a:$j", "copy")

            # Clear default on the copied original when its AC3 twin takes over.
            if (-not $replace -and ($convertCodecs -contains $d.src.codec)) {
                $ffmpegArgs += @("-disposition:a:$j", "0")
            }
        }
    }

    if ($keepSubs) {
        if ($ext -eq ".mp4") {
            # MP4 generally supports mov_text subtitles (text-based). Copying subs often fails.
            $ffmpegArgs += @("-c:s", "mov_text")
        } else {
            $ffmpegArgs += @("-c:s", "copy")
        }
    }

    if ($ext -eq ".mp4") {
        $ffmpegArgs += @("-movflags", "+faststart")
    }

    $ffmpegArgs += @($outPath)

    Write-Host "Running: ffmpeg $($ffmpegArgs -join ' ')"
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $writer = New-Object System.IO.StreamWriter($logPath, $true)
    $spinner = @("|", "/", "-", "\")
    $spin = 0
    $prevLen = 0
    try {
        $writer.WriteLine("")
        $writer.WriteLine("=== ffmpeg: $inPath")
        $writer.WriteLine("Command: ffmpeg $($ffmpegArgs -join ' ')")
        & ffmpeg @ffmpegArgs 2>&1 | ForEach-Object {
            $line = [string]$_
            $writer.WriteLine($line)
            if ($line -match "frame=") {
                $marker = $spinner[$spin % 4] + " " + $line.TrimEnd()
                $pad = " " * [Math]::Max(0, $prevLen - $marker.Length)
                Write-Host -NoNewline ("`r  " + $marker + $pad)
                $prevLen = $marker.Length + 2
                $spin++
            } elseif ($line -match "error|Error") {
                Write-Host $line
            }
        }
        $rc = $LASTEXITCODE
    } finally {
        $writer.Close()
        $ErrorActionPreference = $prevEAP
    }
    Write-Host ""
    return $rc
}

function Write-Log([string]$logPath, [string]$text) {
    $writer = New-Object System.IO.StreamWriter($logPath, $true)
    $writer.WriteLine($text)
    $writer.Close()
}

function Write-Fail([string]$msg) {
    Write-Host "ERROR: $msg" -ForegroundColor Red
}

function Convert-OneFile([string]$file, [bool]$replace, [string]$logPath) {
    $fullPath = (Resolve-Path -LiteralPath $file).Path
    $ext = [System.IO.Path]::GetExtension($fullPath).ToLowerInvariant()
    if ($ext -ne ".mkv" -and $ext -ne ".mp4") {
        Write-Fail "Unsupported input extension '$ext'. This script supports .mkv and .mp4."
        return $false
    }

    $dir = [System.IO.Path]::GetDirectoryName($fullPath)
    $base = [System.IO.Path]::GetFileNameWithoutExtension($fullPath)

    # Temp output uses SAME container as input
    $tempOut = Join-Path $dir ($base + ".temp" + $ext)

    # Backup original (same behavior as your script)
    $backup = $fullPath + ".orig"
    if (Test-Path -LiteralPath $backup) {
        Write-Fail "Backup file already exists: '$backup' (won't overwrite)."
        return $false
    }

    try {
        $audioStreams = @(Get-AudioStreams $fullPath)
    } catch {
        Write-Fail $_
        return $false
    }

    if ($audioStreams.Count -lt 1) {
        Write-Fail "No audio streams found in '$fullPath'."
        return $false
    }

    $convertStreams = @($audioStreams | Where-Object { $convertCodecs -contains $_.codec })
    if ($convertStreams.Count -lt 1) {
        Write-Host "No audio streams require conversion (target codecs: $($convertCodecs -join ', ')). Nothing to do."
        Write-Log $logPath "Nothing to do: $fullPath"
        return $true
    }

    # Remove any stale temp file/directory
    if (Test-Path -LiteralPath $tempOut) {
        Remove-Item -LiteralPath $tempOut -Recurse -Force -ErrorAction SilentlyContinue
    }

    $mode = if ($replace) { "replace" } else { "add" }
    Write-Host "Converting $($convertStreams.Count) audio stream(s) to AC3 (mode: $mode) for file: $fullPath ..."
    Write-Log $logPath "Converting $($convertStreams.Count) audio stream(s) to AC3 (mode: $mode): $fullPath"

    $keepSubs = $true
    $rc = Invoke-Convert -inPath $fullPath -outPath $tempOut -audioStreams $audioStreams -keepSubs $keepSubs -replace $replace -ext $ext -logPath $logPath

    # If MP4 + subtitles fails, retry without subtitles (common when subs are not MP4-compatible)
    if ($rc -ne 0 -and $ext -eq ".mp4" -and $keepSubs) {
        Write-Warning "Conversion failed with subtitles for MP4. Retrying without subtitles..."
        Write-Log $logPath "WARNING: MP4 conversion with subtitles failed; retrying without subtitles."
        if (Test-Path -LiteralPath $tempOut) {
            Remove-Item -LiteralPath $tempOut -Recurse -Force -ErrorAction SilentlyContinue
        }
        $rc = Invoke-Convert -inPath $fullPath -outPath $tempOut -audioStreams $audioStreams -keepSubs $false -replace $replace -ext $ext -logPath $logPath
    }

    if ($rc -ne 0) {
        Write-Fail "ffmpeg exited with code $rc for $fullPath"
        Write-Log $logPath "ERROR: ffmpeg exited with code $rc for $fullPath"
        return $false
    }

    # Refuse to proceed unless the temp output is a real file; a leftover
    # directory (or anything else) here must not be renamed over the original.
    if (-not (Test-Path -LiteralPath $tempOut -PathType Leaf)) {
        Write-Fail "Temp output '$tempOut' is not a file. Skipping replacement of '$fullPath' (original untouched)."
        Write-Log $logPath "ERROR: temp output '$tempOut' is not a file; original not replaced."
        return $false
    }

    Write-Host "Renaming original file to: $backup"
    Rename-Item -LiteralPath $fullPath -NewName $backup

    Write-Host "Renaming converted file to: $fullPath"
    Rename-Item -LiteralPath $tempOut -NewName $fullPath

    Write-Host "Conversion complete. Original file backed up as '$backup'."
    Write-Log $logPath "Complete: $fullPath (backup: $backup)"
    return $true
}

$failed = @()
foreach ($target in $targets) {
    if ($ConfirmEach) {
        $answer = Read-Host "Convert '$target'? [y/N]"
        if ($answer -notmatch '^[yY]') {
            Write-Host "Skipping '$target'."
            continue
        }
    }

    if (-not (Convert-OneFile -file $target -replace $Replace -logPath $logPath)) {
        $failed += $target
    }
}

if ($failed.Count -gt 0) {
    Write-Host ""
    Write-Host "Failed files:" -ForegroundColor Red
    $failed | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}
exit 0
