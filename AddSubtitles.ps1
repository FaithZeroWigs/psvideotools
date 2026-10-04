param(
    [Parameter(Mandatory=$true)]
    [string]$VideoFile,
    
    [Parameter(Mandatory=$false)]
    [switch]$ReplaceExistingSubtitles
)

$BaseName   = [System.IO.Path]::GetFileNameWithoutExtension($VideoFile)
$Folder     = [System.IO.Path]::GetDirectoryName($VideoFile)
$VideoExt   = [System.IO.Path]::GetExtension($VideoFile)
$OrigFile   = Join-Path $Folder "$($BaseName)$VideoExt.orig"
$OutputFile = Join-Path $Folder "$($BaseName)$VideoExt"

# Get matching SRTs
$SubtitleFiles = Get-ChildItem -LiteralPath $Folder -Filter "$BaseName*.srt" -File

if (-not $SubtitleFiles) {
    Write-Host "No matching SRT files found."
    return
}

# Rename the original video to a ".orig" copy so the subtitled output
# can take over the original file name.
Rename-Item -LiteralPath $VideoFile -NewName "$($BaseName)$VideoExt.orig" -Force
Write-Host "Renaming original to '$($BaseName)$VideoExt.orig'."
$VideoFile = $OrigFile

# Decide on subtitle codec based on extension
if ($VideoExt -eq ".mkv") {
    $subtitleCodec = "srt"
} else {
    $subtitleCodec = "mov_text"
}

# FFmpeg input for video
$inputs = @("-i `"$VideoFile`"")

$lang_maps = @{
    "en"  = "eng"
    "eng" = "eng"
    "ro"  = "rum"
    "fr"  = "fra"
}

# Check for existing subtitle streams
$ffprobeCmd = "ffprobe -v error -select_streams s -count_packets -show_entries stream=index -of csv=p=0 `"$VideoFile`" 2>$null"
$existingSubCount = 0
try {
    $existingSubStreams = Invoke-Expression $ffprobeCmd
    if ($existingSubStreams) {
        $existingSubCount = ($existingSubStreams | Measure-Object).Count
    }
} catch {
    $existingSubCount = 0
}

Write-Host "There are $existingSubCount existing subtitle stream(s) in the file."

# Map video and audio from the first input
# Probe all streams so nothing is dropped (data tracks, thumbnails, etc.)
$ffprobeStreamsCmd = "ffprobe -v error -show_entries stream=index,codec_type:stream_tags=language -of csv=p=0 `"$VideoFile`""
$allStreams = Invoke-Expression $ffprobeStreamsCmd
$maps = @()

# Map every stream individually so data tracks, thumbnails etc. are preserved.
# Subtitle streams are kept or dropped depending on -ReplaceExistingSubtitles.
$sIndex = 0
$keptExistingSubs = $false
$subLangs = @()   # language of each output subtitle stream, by output subtitle index
$subFlags = @()   # disposition flag (forced/comment/hearing_impaired) per output subtitle stream, or "" if none

foreach ($line in ($allStreams | Where-Object { $_.Trim() -ne "" })) {
    $parts     = $line -split ","
    $streamIdx = $parts[0].Trim()
    $codecType = if ($parts.Count -gt 1) { $parts[1].Trim() } else { "" }

    if ($codecType -eq "subtitle") {
        if (-not $ReplaceExistingSubtitles) {
            $maps += "-map 0:$streamIdx"
            $existingLang = if ($parts.Count -gt 2) { $parts[2].Trim().ToLower() } else { "" }
            if ($lang_maps.ContainsKey($existingLang)) { $existingLang = $lang_maps[$existingLang] }
            $subLangs += $existingLang
            $subFlags += ""
            $sIndex++
            $keptExistingSubs = $true
        }
        # else: skip — will be replaced by the external SRTs below
    } else {
        $maps += "-map 0:$streamIdx"
    }
}

if ($keptExistingSubs) {
    Write-Host "Keeping $existingSubCount existing subtitle stream(s) from original video file."
} elseif ($ReplaceExistingSubtitles -and $existingSubCount -gt 0) {
    Write-Host "Replacing $existingSubCount existing subtitle stream(s) with external SRT files only."
} else {
    Write-Host "No existing subtitles found in video file."
}

# Add each SRT as another input
$count    = 1
$metadata = @()

foreach ($sub in $SubtitleFiles) {
    $inputs += "-i `"$($sub.FullName)`""
    $maps   += "-map $count"

    # Extract language and optional tag from filename.
    # Convention: "<base>.<lang>.srt", "<base>-<lang>.srt", "<base>_<lang>.srt",
    # or "<base>_<tag>_<lang>.srt" where <tag> is optional free-form text
    # (e.g. "forced", "director commentary", "closed caption").
    $subBase = $sub.BaseName -replace [regex]::Escape($BaseName), ""
    $subBase = $subBase.TrimStart(".", "_", "-")

    $parts = $subBase -split "[._-]"
    $lang  = $parts[-1]
    $tag   = if ($parts.Count -gt 1) { ($parts[0..($parts.Count - 2)] -join " ") } else { "" }
    $tag   = ($tag -replace "[_-]+", " ").Trim()

    if ($lang_maps.ContainsKey($lang)) {
        $lang = $lang_maps[$lang]
    }

    $title = ""
    $flag  = ""

    if ($tag -ne "") {
        $tagKey = $tag.ToLower()
        switch -Regex ($tagKey) {
            "^forced$"                                                { $title = "Forced";             $flag = "forced" }
            "^director\s*commentary$|^commentary$"                    { $title = "Director Commentary"; $flag = "comment" }
            "^closed\s*captions?$|^sdh$|^cc$|^hearing\s*impaired$"    { $title = "Closed Caption";     $flag = "hearing_impaired" }
            default {
                $title = [System.Globalization.CultureInfo]::InvariantCulture.TextInfo.ToTitleCase($tagKey)
            }
        }
    }

    Write-Host "Find srt '$sub' for '$lang' language$(if ($tag) { ", tag '$tag'" })."

    $metadata += "-metadata:s:s:$sIndex language=$lang"
    if ($title -ne "") {
        $metadata += "-metadata:s:s:$sIndex title=`"$title`""
    }
    $subLangs += $lang.ToLower()
    $subFlags += $flag

    $count++
    $sIndex++
}

# Default subtitle: the first English track, if there is one.
# All other subtitle tracks get their default flag cleared so English is the only default.
# If no English track is available, dispositions are left untouched.
$dispositions = @()
$englishIdx = [array]::IndexOf($subLangs, "eng")
if ($englishIdx -ge 0) {
    for ($i = 0; $i -lt $subLangs.Count; $i++) {
        $dispo = @()
        if ($i -eq $englishIdx) { $dispo += "default" } else { $dispo += "0" }
        if ($subFlags[$i]) { $dispo += $subFlags[$i] }
        $dispositions += "-disposition:s:$i $($dispo -join '+')"
    }
    Write-Host "Setting English subtitle (subtitle stream #$englishIdx) as the default."
} else {
    for ($i = 0; $i -lt $subLangs.Count; $i++) {
        if ($subFlags[$i]) {
            $dispositions += "-disposition:s:$i $($subFlags[$i])"
        }
    }
    Write-Host "No English subtitles available; leaving default subtitle flags unchanged."
}

# Build and run ffmpeg command
$ffmpegCmd = "ffmpeg $($inputs -join ' ') $($maps -join ' ') $($metadata -join ' ') $($dispositions -join ' ') -c copy -c:s $subtitleCodec `"$OutputFile`""

Write-Host "Running: $ffmpegCmd"
Invoke-Expression $ffmpegCmd