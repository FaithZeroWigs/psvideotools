param (
    [Parameter(Mandatory = $true)]
    [string]$InputFile,
    [switch]$Replace
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

# Validate input file
if (-not (Test-Path -LiteralPath $InputFile)) {
    Write-Error "Input file '$InputFile' does not exist."
    exit 1
}

$fullPath = (Resolve-Path -LiteralPath $InputFile).Path
$ext = [System.IO.Path]::GetExtension($fullPath).ToLowerInvariant()
if ($ext -ne ".mkv" -and $ext -ne ".mp4") {
    Write-Error "Unsupported input extension '$ext'. This script supports .mkv and .mp4."
    exit 1
}

$dir = [System.IO.Path]::GetDirectoryName($fullPath)
$base = [System.IO.Path]::GetFileNameWithoutExtension($fullPath)

# Temp output uses SAME container as input
$tempOut = Join-Path $dir ($base + ".temp" + $ext)

# Backup original (same behavior as your script)
$backup = $fullPath + ".orig"
if (Test-Path -LiteralPath $backup) {
    Write-Error "Backup file already exists: '$backup' (won't overwrite)."
    exit 1
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


function Invoke-Convert([string]$inPath, [string]$outPath, $audioStreams, [bool]$keepSubs, [bool]$replace) {
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

    $args = @(
        "-hide_banner",
        "-i", $inPath,

        "-map", "0:v?"
    )

    foreach ($d in $defs) { $args += @("-map", "0:a:$($d.inputIndex)") }

    if ($keepSubs) {
        $args += @("-map", "0:s?")
    }

    $args += @("-c:v", "copy")

    for ($j = 0; $j -lt $defs.Count; $j++) {
        $d = $defs[$j]
        if ($d.mode -eq "ac3") {
            $args += @("-c:a:$j", "ac3")

            $disp = "0"
            if ($d.src.isDefault) { $disp = "default" }
            elseif ($d.src.isForced) { $disp = "forced" }
            $args += @("-disposition:a:$j", $disp)

            $title = "AC3"
            if ($d.src.lang) { $title = "AC3 ($($d.src.lang))" }
            $args += @("-metadata:s:a:$j", "title=$title")
        } else {
            $args += @("-c:a:$j", "copy")

            # Clear default on the copied original when its AC3 twin takes over.
            if (-not $replace -and ($convertCodecs -contains $d.src.codec)) {
                $args += @("-disposition:a:$j", "0")
            }
        }
    }

    if ($keepSubs) {
        if ($ext -eq ".mp4") {
            # MP4 generally supports mov_text subtitles (text-based). Copying subs often fails.
            $args += @("-c:s", "mov_text")
        } else {
            $args += @("-c:s", "copy")
        }
    }

    if ($ext -eq ".mp4") {
        $args += @("-movflags", "+faststart")
    }

    $args += @($outPath)

    Write-Host "Running: ffmpeg $($args -join ' ')"
    & ffmpeg @args
    return $LASTEXITCODE
}

try {
    $audioStreams = @(Get-AudioStreams $fullPath)
} catch {
    Write-Error $_
    exit 1
}

if ($audioStreams.Count -lt 1) {
    Write-Error "No audio streams found in '$fullPath'."
    exit 1
}

$convertStreams = @($audioStreams | Where-Object { $convertCodecs -contains $_.codec })
if ($convertStreams.Count -lt 1) {
    Write-Host "No audio streams require conversion (target codecs: $($convertCodecs -join ', ')). Nothing to do."
    exit 0
}

# Remove any stale temp file
if (Test-Path -LiteralPath $tempOut) {
    Remove-Item -LiteralPath $tempOut -Force
}

$mode = if ($Replace) { "replace" } else { "add" }
Write-Host "Converting $($convertStreams.Count) audio stream(s) to AC3 (mode: $mode) for file: $fullPath ..."

$keepSubs = $true
$rc = Invoke-Convert -inPath $fullPath -outPath $tempOut -audioStreams $audioStreams -keepSubs $keepSubs -replace $Replace

# If MP4 + subtitles fails, retry without subtitles (common when subs are not MP4-compatible)
if ($rc -ne 0 -and $ext -eq ".mp4" -and $keepSubs) {
    Write-Warning "Conversion failed with subtitles for MP4. Retrying without subtitles..."
    if (Test-Path -LiteralPath $tempOut) {
        Remove-Item -LiteralPath $tempOut -Force
    }
    $rc = Invoke-Convert -inPath $fullPath -outPath $tempOut -audioStreams $audioStreams -keepSubs $false -replace $Replace
}

if ($rc -ne 0) {
    Write-Error "ffmpeg encountered an error during conversion."
    exit 1
}

Write-Host "Renaming original file to: $backup"
Rename-Item -LiteralPath $fullPath -NewName $backup

Write-Host "Renaming converted file to: $fullPath"
Rename-Item -LiteralPath $tempOut -NewName $fullPath

Write-Host "Conversion complete. Original file backed up as '$backup'."
