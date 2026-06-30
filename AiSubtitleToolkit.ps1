param(
    [switch]$WorkerMode,
    [switch]$ExtractWorkerMode,
    [switch]$MockWorkerMode,
    [switch]$RunSelfTests,
    [string]$InputPath,
    [string]$Direction,
    [string]$LogFile,
    [string]$ProgressFile,
    [string]$ResultFile,
    [string]$DoneFile
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Security

$ErrorActionPreference = 'Stop'

$AppName = 'AI Subtitle Toolkit'
$ConfigDir = Join-Path $env:APPDATA 'AiSubtitleToolkit'
$LegacyConfigDir = Join-Path $env:APPDATA 'GeminiSrtTranslator'
$KeyFile = Join-Path $ConfigDir 'key.bin'
$LegacyKeyFile = Join-Path $LegacyConfigDir 'key.bin'
$ModelName = 'gemini-3.5-flash'
$ChunkSize = 20
$VideoExtensions = @('.mkv', '.mp4', '.avi', '.mov', '.m4v', '.webm')
$TextSubtitleCodecs = @('subrip', 'ass', 'ssa', 'mov_text', 'webvtt', 'text')

$RLM = [char]0x200F
$LRI = [char]0x2066
$RLI = [char]0x2067
$PDI = [char]0x2069

function Ensure-ConfigDir {
    if (-not (Test-Path -LiteralPath $ConfigDir)) {
        New-Item -ItemType Directory -Path $ConfigDir -Force | Out-Null
    }
}

function Ensure-KeyMigration {
    if ((Test-Path -LiteralPath $KeyFile) -or -not (Test-Path -LiteralPath $LegacyKeyFile)) {
        return
    }

    Ensure-ConfigDir
    Copy-Item -LiteralPath $LegacyKeyFile -Destination $KeyFile -Force
}

function Save-ApiKey {
    param([string]$ApiKey)

    Ensure-ConfigDir
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($ApiKey)
    $protected = [System.Security.Cryptography.ProtectedData]::Protect(
        $bytes,
        $null,
        [System.Security.Cryptography.DataProtectionScope]::CurrentUser
    )
    [System.IO.File]::WriteAllBytes($KeyFile, $protected)
}

function Load-ApiKey {
    Ensure-KeyMigration
    if (-not (Test-Path -LiteralPath $KeyFile)) {
        return $null
    }

    try {
        $protected = [System.IO.File]::ReadAllBytes($KeyFile)
        $bytes = [System.Security.Cryptography.ProtectedData]::Unprotect(
            $protected,
            $null,
            [System.Security.Cryptography.DataProtectionScope]::CurrentUser
        )
        return [System.Text.Encoding]::UTF8.GetString($bytes)
    } catch {
        return $null
    }
}

function Show-ApiKeyDialog {
    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'Gemini API Key'
    $form.StartPosition = 'CenterParent'
    $form.Size = New-Object System.Drawing.Size(620, 430)
    $form.MinimumSize = New-Object System.Drawing.Size(620, 430)

    $label = New-Object System.Windows.Forms.Label
    $label.Location = New-Object System.Drawing.Point(16, 16)
    $label.Size = New-Object System.Drawing.Size(570, 215)
    $label.Text = @"
This app uses the Gemini API to translate SRT subtitles.

How to get an API key:
1. Open Google AI Studio:
   https://aistudio.google.com/app/apikey
2. Sign in with your Google account.
3. Click "Create API key".
4. If prompted, create or choose a Google Cloud project.
5. Copy the API key.
6. Paste it below and click Save.

The key is saved encrypted for your Windows user in:
%APPDATA%\AiSubtitleToolkit\key.bin

It will be loaded automatically on future runs.
"@
    $form.Controls.Add($label)

    $link = New-Object System.Windows.Forms.LinkLabel
    $link.Location = New-Object System.Drawing.Point(16, 240)
    $link.Size = New-Object System.Drawing.Size(570, 24)
    $link.Text = 'Open Google AI Studio API Keys page'
    $link.Add_LinkClicked({
        Start-Process 'https://aistudio.google.com/app/apikey'
    })
    $form.Controls.Add($link)

    $textBox = New-Object System.Windows.Forms.TextBox
    $textBox.Location = New-Object System.Drawing.Point(16, 275)
    $textBox.Size = New-Object System.Drawing.Size(570, 24)
    $textBox.UseSystemPasswordChar = $true
    $form.Controls.Add($textBox)

    $showCheck = New-Object System.Windows.Forms.CheckBox
    $showCheck.Location = New-Object System.Drawing.Point(16, 306)
    $showCheck.Size = New-Object System.Drawing.Size(160, 24)
    $showCheck.Text = 'Show key'
    $showCheck.Add_CheckedChanged({
        $textBox.UseSystemPasswordChar = -not $showCheck.Checked
    })
    $form.Controls.Add($showCheck)

    $saveButton = New-Object System.Windows.Forms.Button
    $saveButton.Location = New-Object System.Drawing.Point(390, 340)
    $saveButton.Size = New-Object System.Drawing.Size(90, 32)
    $saveButton.Text = 'Save'
    $saveButton.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $form.Controls.Add($saveButton)

    $cancelButton = New-Object System.Windows.Forms.Button
    $cancelButton.Location = New-Object System.Drawing.Point(495, 340)
    $cancelButton.Size = New-Object System.Drawing.Size(90, 32)
    $cancelButton.Text = 'Cancel'
    $cancelButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $form.Controls.Add($cancelButton)

    $form.AcceptButton = $saveButton
    $form.CancelButton = $cancelButton

    if ($form.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) {
        return $null
    }

    $key = $textBox.Text.Trim()
    if (-not $key) {
        [System.Windows.Forms.MessageBox]::Show(
            'No API key was entered.',
            $AppName,
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
        return $null
    }

    Save-ApiKey $key
    return $key
}

function Get-ApiKey {
    $key = Load-ApiKey
    if ($key) {
        return $key
    }
    return Show-ApiKeyDialog
}

function Test-Hebrew {
    param([string]$Text)
    return $Text -match '[\u0590-\u05FF]'
}

function Normalize-AssAlignment {
    param([string]$Line)
    $line = [regex]::Replace($Line, '\{[\\/]אנ(\d+)\}', '{\an$1}')
    return [regex]::Replace($line, '\{[\\/]an(\d+)\}', '{\an$1}')
}

function Add-AfterTrailingPunctuation {
    param([string]$Text)
    return [regex]::Replace($Text, '([.!?,:;])(\s*)$', "`$1$RLM`$2")
}

function Prefix-AfterLeadingSpace {
    param([string]$Text, [string]$Prefix)
    $match = [regex]::Match($Text, '^\s*')
    return $Text.Substring(0, $match.Length) + $Prefix + $Text.Substring($match.Length)
}

function Suffix-BeforeTrailingSpace {
    param([string]$Text, [string]$Suffix)
    $trimmedLength = $Text.TrimEnd().Length
    if ($trimmedLength -gt 0 -and $Text.Substring(0, $trimmedLength).EndsWith($Suffix)) {
        return $Text
    }
    return $Text.Substring(0, $trimmedLength) + $Suffix + $Text.Substring($trimmedLength)
}

function Fix-SubtitleLineRtl {
    param([string]$Line)

    $line = [regex]::Replace($Line, '[\u200E\u200F\u202A-\u202E\u2066-\u2069]', '')
    $line = Normalize-AssAlignment $line

    $tagPattern = '(\{\\[^}]*\}|</?[^>]+>)'
    $parts = [regex]::Split($line, $tagPattern)
    $textIndexes = New-Object System.Collections.Generic.List[int]

    for ($i = 0; $i -lt $parts.Count; $i++) {
        if ($parts[$i] -and -not [regex]::IsMatch($parts[$i], "^$tagPattern$")) {
            $textIndexes.Add($i)
        }
    }

    if ($textIndexes.Count -eq 0) {
        return $line
    }

    $joinedText = (($textIndexes | ForEach-Object { $parts[$_] }) -join '')
    if (-not (Test-Hebrew $joinedText)) {
        return $line
    }

    for ($i = 0; $i -lt $textIndexes.Count; $i++) {
        $idx = $textIndexes[$i]
        $parts[$idx] = [regex]::Replace(
            $parts[$idx],
            "[A-Za-z0-9]+(?:[._:/@#+&%'-][A-Za-z0-9]+)*",
            { param($m) "$LRI$($m.Value)$PDI" }
        )
    }

    $first = $textIndexes[0]
    $last = $textIndexes[$textIndexes.Count - 1]
    $parts[$first] = Prefix-AfterLeadingSpace $parts[$first] $RLI
    $parts[$last] = Add-AfterTrailingPunctuation $parts[$last]
    $parts[$last] = Suffix-BeforeTrailingSpace $parts[$last] $PDI

    return ($parts -join '')
}

function Clean-AndFixRtl {
    param([string]$SrtText)

    $lines = $SrtText -split "`n", 0, 'SimpleMatch'
    $fixed = foreach ($line in $lines) {
        $stripped = $line.Trim().TrimStart([char]0xFEFF)
        if (-not $stripped -or $stripped -match '^\d+$' -or $stripped.Contains('-->')) {
            $line
        } else {
            Fix-SubtitleLineRtl $line
        }
    }
    return ($fixed -join "`n")
}

function Convert-SrtToTranslationItems {
    param([string]$Content)

    $content = $Content -replace "`r`n", "`n"
    $content = $content -replace "`r", "`n"
    $blocks = [regex]::Split($content.Trim(), "\n\s*\n")
    $items = New-Object System.Collections.Generic.List[object]

    foreach ($block in $blocks) {
        $lines = $block -split "`n"
        if ($lines.Count -ge 3) {
            $text = (($lines[2..($lines.Count - 1)] -join "`n") -replace "`n", " `n ")
            $items.Add([pscustomobject]@{
                Index = $lines[0]
                Timestamp = $lines[1]
                Text = $text
            })
        }
    }

    Write-Output -NoEnumerate $items
}

function Get-SubtitleLanguageProfile {
    param([string]$Content)

    $items = Convert-SrtToTranslationItems $Content
    $sample = (($items | Select-Object -First 80 | ForEach-Object { $_.Text }) -join ' ')

    $sample = [regex]::Replace($sample, '<[^>]+>|\{\\[^}]*\}', ' ')
    $sample = [regex]::Replace($sample, '\s+', ' ')

    $hebrewCount = ([regex]::Matches($sample, '[\u0590-\u05FF]')).Count
    $latinCount = ([regex]::Matches($sample, '[A-Za-z]')).Count

    $likelyLanguage = 'Unknown'
    if ($hebrewCount -ge 20 -and $hebrewCount -ge ($latinCount * 2)) {
        $likelyLanguage = 'Hebrew'
    } elseif ($latinCount -ge 40 -and $latinCount -ge ($hebrewCount * 2)) {
        $likelyLanguage = 'English'
    }

    return [pscustomobject]@{
        LikelyLanguage = $likelyLanguage
        HebrewCount = $hebrewCount
        LatinCount = $latinCount
        BlockCount = $items.Count
    }
}

function Test-TranslationDirectionLooksValid {
    param([string]$InputPath, [string]$Direction)

    $content = [System.IO.File]::ReadAllText($InputPath, [System.Text.Encoding]::UTF8)
    $profile = Get-SubtitleLanguageProfile $content

    if ($Direction -eq 'Hebrew to English' -and $profile.LikelyLanguage -eq 'English') {
        return [pscustomobject]@{
            IsValid = $false
            Message = "This subtitle already looks English.`r`n`r`nSelected direction: Hebrew to English.`r`nDetected: English-like text.`r`n`r`nSwitch to English to Hebrew, or choose a Hebrew subtitle."
            Profile = $profile
        }
    }

    if ($Direction -eq 'English to Hebrew' -and $profile.LikelyLanguage -eq 'Hebrew') {
        return [pscustomobject]@{
            IsValid = $false
            Message = "This subtitle already looks Hebrew.`r`n`r`nSelected direction: English to Hebrew.`r`nDetected: Hebrew-like text.`r`n`r`nSwitch to Hebrew to English, or choose an English subtitle."
            Profile = $profile
        }
    }

    return [pscustomobject]@{
        IsValid = $true
        Message = ''
        Profile = $profile
    }
}

function Invoke-GeminiTranslation {
    param(
        [string[]]$Texts,
        [string]$ApiKey,
        [string]$Direction
    )

    if ($Direction -eq 'Hebrew to English') {
        $instruction = 'Translate each subtitle string from Hebrew to natural English. Preserve SRT/HTML/ASS tags, line-break placeholders, names, punctuation, and meaning. Return only a JSON array of strings in the same order.'
    } else {
        $instruction = 'Translate each subtitle string from English to natural Hebrew. Preserve SRT/HTML/ASS tags, line-break placeholders, names, punctuation, and meaning. Return only a JSON array of strings in the same order.'
    }

    $prompt = $instruction + "`nInput:`n" + ($Texts | ConvertTo-Json -Compress)
    $payload = @{
        contents = @(
            @{
                parts = @(
                    @{ text = $prompt }
                )
            }
        )
        generationConfig = @{
            responseMimeType = 'application/json'
        }
    } | ConvertTo-Json -Depth 10

    $uri = "https://generativelanguage.googleapis.com/v1beta/models/$ModelName`:generateContent?key=$ApiKey"
    $response = Invoke-RestMethod -Method Post -Uri $uri -ContentType 'application/json' -Body ([System.Text.Encoding]::UTF8.GetBytes($payload))
    return Convert-GeminiResponseToStringArray -Response $response
}

function Convert-GeminiResponseToStringArray {
    param([object]$Response)

    if (-not $Response) {
        throw 'Gemini returned an empty response.'
    }
    if (-not $Response.candidates -or $Response.candidates.Count -lt 1) {
        $reason = $Response.promptFeedback.blockReason
        if ($reason) {
            throw "Gemini returned no candidates. Prompt was blocked: $reason."
        }
        throw 'Gemini returned no candidates.'
    }

    $candidate = $Response.candidates[0]
    if ($candidate.finishReason -and $candidate.finishReason -ne 'STOP') {
        throw "Gemini response finished with reason: $($candidate.finishReason)."
    }
    if (-not $candidate.content -or -not $candidate.content.parts -or $candidate.content.parts.Count -lt 1) {
        throw 'Gemini returned a candidate without text content.'
    }

    $jsonText = [string]$candidate.content.parts[0].text
    if (-not $jsonText.Trim()) {
        throw 'Gemini returned empty text content.'
    }

    try {
        $parsed = @($jsonText | ConvertFrom-Json)
    } catch {
        $preview = $jsonText
        if ($preview.Length -gt 300) {
            $preview = $preview.Substring(0, 300) + '...'
        }
        throw "Gemini returned invalid JSON: $preview"
    }

    if ($parsed.Count -lt 1) {
        throw 'Gemini returned an empty translation array.'
    }

    Write-Output -NoEnumerate $parsed
}

function Get-OutputPath {
    param([string]$InputPath, [string]$Direction)

    $dir = Split-Path -Parent $InputPath
    $name = [System.IO.Path]::GetFileNameWithoutExtension($InputPath)

    if ($Direction -eq 'Hebrew to English') {
        $base = $name -replace '(?i)\.(heb|he)$', ''
        return Join-Path $dir "$base.eng.srt"
    }

    $base = $name -replace '(?i)\.(eng|en)$', ''
    return Join-Path $dir "$base.heb.srt"
}

function Read-WorkerResultFile {
    param([string]$ResultFilePath)

    if ([string]::IsNullOrWhiteSpace($ResultFilePath)) {
        throw 'Worker result file path is empty.'
    }
    if (-not (Test-Path -LiteralPath $ResultFilePath)) {
        throw "Worker result file is missing: $ResultFilePath"
    }

    $output = (Read-TextFileShared $ResultFilePath).Trim()
    if (-not $output) {
        throw "Worker result file is empty: $ResultFilePath"
    }

    return $output
}

function Format-ErrorDetails {
    param([System.Management.Automation.ErrorRecord]$ErrorRecord)

    $lines = New-Object System.Collections.Generic.List[string]
    $message = $ErrorRecord.Exception.Message
    if (-not $message) {
        $message = 'Unknown error.'
    }

    $lines.Add("Error: $message")
    $lines.Add("Type: $($ErrorRecord.Exception.GetType().FullName)")

    if ($ErrorRecord.InvocationInfo -and $ErrorRecord.InvocationInfo.PositionMessage) {
        $lines.Add($ErrorRecord.InvocationInfo.PositionMessage.Trim())
    }
    if ($ErrorRecord.ScriptStackTrace) {
        $lines.Add('Stack:')
        $lines.Add($ErrorRecord.ScriptStackTrace.Trim())
    }

    return ($lines -join "`n")
}

function Test-SrtFilePath {
    param([string]$Path)
    return [System.IO.Path]::GetExtension($Path).Equals('.srt', [System.StringComparison]::OrdinalIgnoreCase)
}

function Test-VideoFilePath {
    param([string]$Path)
    $extension = [System.IO.Path]::GetExtension($Path).ToLowerInvariant()
    return $VideoExtensions -contains $extension
}

function Resolve-ToolPath {
    param([string]$ToolName)

    $localTool = Join-Path $PSScriptRoot "$ToolName.exe"
    if (Test-Path -LiteralPath $localTool) {
        return $localTool
    }

    $command = Get-Command "$ToolName.exe" -ErrorAction SilentlyContinue
    if (-not $command) {
        $command = Get-Command $ToolName -ErrorAction SilentlyContinue
    }
    if ($command) {
        return $command.Source
    }

    throw "$ToolName was not found. Install ffmpeg, or place $ToolName.exe next to this script."
}

function Get-ExtractedSubtitlePath {
    param([string]$VideoPath)

    $dir = Split-Path -Parent $VideoPath
    $name = [System.IO.Path]::GetFileNameWithoutExtension($VideoPath)
    return Join-Path $dir "$name.eng.srt"
}

function Get-EnglishTextSubtitleStream {
    param([object[]]$Streams)

    $textStreams = @($Streams | Where-Object {
        $_.codec_type -eq 'subtitle' -and ($TextSubtitleCodecs -contains ([string]$_.codec_name).ToLowerInvariant())
    })
    if ($textStreams.Count -eq 0) {
        return $null
    }

    $englishStreams = @($textStreams | Where-Object {
        $language = ''
        $title = ''
        if ($_.tags) {
            $language = [string]$_.tags.language
            $title = [string]$_.tags.title
        }
        $language -match '^(?i:eng|en|en[-_].*)$' -or $title -match '(?i)english'
    })

    if ($englishStreams.Count -gt 0) {
        return $englishStreams[0]
    }

    return $textStreams[0]
}

function Invoke-NativeTool {
    param(
        [string]$FilePath,
        [string[]]$Arguments
    )

    $output = New-Object System.Collections.Generic.List[string]
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $FilePath @Arguments 2>&1 | ForEach-Object {
            $output.Add([string]$_)
        }
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        Output = @($output)
    }
}

function Convert-SecondsToSrtTimestamp {
    param($Seconds)

    $secondsValue = [double]::Parse([string]$Seconds, [System.Globalization.CultureInfo]::InvariantCulture)
    $milliseconds = [double][Math]::Round([Math]::Max([double]0, $secondsValue) * [double]1000)
    $timeSpan = [System.TimeSpan]::FromMilliseconds($milliseconds)
    return '{0:00}:{1:00}:{2:00},{3:000}' -f [Math]::Floor($timeSpan.TotalHours), $timeSpan.Minutes, $timeSpan.Seconds, $timeSpan.Milliseconds
}

function Convert-FfprobePacketDataToText {
    param([string]$Data)

    $bytes = New-Object System.Collections.Generic.List[byte]
    foreach ($line in ($Data -split "`n")) {
        if ($line -match '^[0-9a-fA-F]{8}:\s+(.+?)(?:\s{2,}.*)?$') {
            $hex = ($matches[1] -replace '[^0-9a-fA-F]', '')
            for ($i = 0; $i + 1 -lt $hex.Length; $i += 2) {
                $bytes.Add([Convert]::ToByte($hex.Substring($i, 2), 16))
            }
        }
    }

    if ($bytes.Count -eq 0) {
        return ''
    }

    return [System.Text.Encoding]::UTF8.GetString($bytes.ToArray()).Trim()
}

function Extract-SubripSubtitleWithFfprobe {
    param(
        [string]$VideoPath,
        [int]$SubtitleOrdinal,
        [string]$OutputPath,
        [scriptblock]$Log
    )

    $ffprobe = Resolve-ToolPath 'ffprobe'
    & $Log 'Extracting embedded SubRip packets with ffprobe...'
    $packetResult = Invoke-NativeTool -FilePath $ffprobe -Arguments @(
        '-v', 'error',
        '-select_streams', "s:$SubtitleOrdinal",
        '-show_packets',
        '-show_data',
        '-show_entries', 'packet=pts_time,duration_time,data',
        '-of', 'json',
        $VideoPath
    )

    if ($packetResult.ExitCode -ne 0) {
        $packetError = (($packetResult.Output | Select-Object -Last 10) -join "`n").Trim()
        if (-not $packetError) {
            $packetError = 'ffprobe failed while extracting subtitle packets.'
        }
        throw $packetError
    }

    $packetJson = ($packetResult.Output -join "`n") | ConvertFrom-Json
    $packets = @($packetJson.packets)
    if ($packets.Count -eq 0) {
        throw 'No subtitle packets were found in the selected SubRip stream.'
    }

    $blocks = New-Object System.Collections.Generic.List[string]
    $index = 1
    foreach ($packet in $packets) {
        $text = Convert-FfprobePacketDataToText ([string]$packet.data)
        if (-not $text) {
            continue
        }

        $startSeconds = [double]::Parse([string]$packet.pts_time, [System.Globalization.CultureInfo]::InvariantCulture)
        $durationSeconds = 0
        if ($packet.duration_time) {
            $durationSeconds = [double]::Parse([string]$packet.duration_time, [System.Globalization.CultureInfo]::InvariantCulture)
        }
        $endSeconds = $startSeconds + [Math]::Max(0.1, $durationSeconds)

        $start = Convert-SecondsToSrtTimestamp $startSeconds
        $end = Convert-SecondsToSrtTimestamp $endSeconds
        $blocks.Add("$index`n$start --> $end`n$text")
        $index++
    }

    if ($blocks.Count -eq 0) {
        throw 'No text subtitle packets were found in the selected SubRip stream.'
    }

    [System.IO.File]::WriteAllText($OutputPath, (($blocks -join "`n`n") + "`n"), (New-Object System.Text.UTF8Encoding($true)))
    & $Log "Extracted $($blocks.Count) subtitle blocks."
}

function Extract-EnglishSubtitleFromVideo {
    param(
        [string]$VideoPath,
        [scriptblock]$Log
    )

    $outputPath = Get-ExtractedSubtitlePath $VideoPath
    if (Test-Path -LiteralPath $outputPath) {
        $existingFile = Get-Item -LiteralPath $outputPath
        if ($existingFile.Length -gt 0) {
            & $Log "Using existing extracted subtitle: $outputPath"
            return $outputPath
        }

        & $Log "Removing incomplete extracted subtitle: $outputPath"
        Remove-Item -LiteralPath $outputPath -Force
    }

    $ffprobe = Resolve-ToolPath 'ffprobe'
    $ffmpeg = Resolve-ToolPath 'ffmpeg'

    & $Log 'Inspecting embedded subtitle streams...'
    $probeResult = Invoke-NativeTool -FilePath $ffprobe -Arguments @(
        '-v', 'error',
        '-print_format', 'json',
        '-show_streams',
        '-select_streams', 's',
        $VideoPath
    )
    if ($probeResult.ExitCode -ne 0) {
        $probeError = (($probeResult.Output | Select-Object -Last 10) -join "`n").Trim()
        if (-not $probeError) {
            $probeError = 'ffprobe failed while inspecting the video.'
        }
        throw $probeError
    }

    $probe = ($probeResult.Output -join "`n") | ConvertFrom-Json
    $streams = @($probe.streams)
    if ($streams.Count -eq 0) {
        throw 'No embedded subtitle streams were found in this video.'
    }

    $stream = Get-EnglishTextSubtitleStream $streams
    if (-not $stream) {
        throw 'No extractable text subtitle streams were found. Bitmap/image subtitles are not supported.'
    }

    $subtitleOrdinal = 0
    for ($i = 0; $i -lt $streams.Count; $i++) {
        if ([int]$streams[$i].index -eq [int]$stream.index) {
            $subtitleOrdinal = $i
            break
        }
    }

    $codec = [string]$stream.codec_name
    $language = ''
    if ($stream.tags) {
        $language = [string]$stream.tags.language
    }
    if (-not $language) {
        $language = 'unknown language'
    }

    $tempOutputPath = "$outputPath.extracting"
    if (Test-Path -LiteralPath $tempOutputPath) {
        Remove-Item -LiteralPath $tempOutputPath -Force
    }

    & $Log "Extracting subtitle stream $($stream.index) ($codec, $language) to $outputPath..."
    if ($codec -eq 'subrip') {
        Extract-SubripSubtitleWithFfprobe -VideoPath $VideoPath -SubtitleOrdinal $subtitleOrdinal -OutputPath $tempOutputPath -Log $Log
        Move-Item -LiteralPath $tempOutputPath -Destination $outputPath -Force
        return $outputPath
    }

    $extractResult = Invoke-NativeTool -FilePath $ffmpeg -Arguments @(
        '-nostdin',
        '-y',
        '-hide_banner',
        '-i', $VideoPath,
        '-vn',
        '-an',
        '-dn',
        '-map', "0:$($stream.index)",
        '-c:s', 'srt',
        '-f', 'srt',
        $tempOutputPath
    )
    foreach ($line in $extractResult.Output) {
        $line = [string]$line
        if ($line -match 'Stream mapping|Subtitle:|->|Error|Invalid|failed') {
            & $Log $line.Trim()
        }
    }

    $tempOutputExists = Test-Path -LiteralPath $tempOutputPath
    $tempOutputHasContent = $false
    if ($tempOutputExists) {
        $tempOutputHasContent = (Get-Item -LiteralPath $tempOutputPath).Length -gt 0
    }

    if ($extractResult.ExitCode -ne 0 -or -not $tempOutputHasContent) {
        $extractError = (($extractResult.Output | Select-Object -Last 12) -join "`n").Trim()
        if (-not $extractError) {
            $extractError = 'ffmpeg failed while extracting the subtitle stream.'
        }
        if ($tempOutputExists) {
            Remove-Item -LiteralPath $tempOutputPath -Force -ErrorAction SilentlyContinue
        }
        throw $extractError
    }

    Move-Item -LiteralPath $tempOutputPath -Destination $outputPath -Force
    return $outputPath
}

function Resolve-SubtitleInputPath {
    param(
        [string]$InputPath,
        [scriptblock]$Log
    )

    if (Test-SrtFilePath $InputPath) {
        return $InputPath
    }

    if (Test-VideoFilePath $InputPath) {
        return Extract-EnglishSubtitleFromVideo -VideoPath $InputPath -Log $Log
    }

    throw 'Please select an .srt subtitle file or a supported video file.'
}

function Invoke-TranslationTextsWithFallback {
    param(
        [string[]]$Texts,
        [string]$ApiKey,
        [string]$Direction,
        [scriptblock]$Log,
        [scriptblock]$Translate = $null,
        [int]$RetryDelaySeconds = 2
    )

    if (-not $Translate) {
        $Translate = {
            param([string[]]$Texts, [string]$ApiKey, [string]$Direction)
            Invoke-GeminiTranslation -Texts $Texts -ApiKey $ApiKey -Direction $Direction
        }
    }

    $lastError = $null
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            $translatedTexts = @(& $Translate -Texts $Texts -ApiKey $ApiKey -Direction $Direction)
            if ($translatedTexts.Count -eq $Texts.Count) {
                Write-Output -NoEnumerate $translatedTexts
                return
            }

            throw "Gemini returned $($translatedTexts.Count) strings for $($Texts.Count) input subtitles."
        } catch {
            $lastError = $_
            if ($attempt -lt 3) {
                & $Log "Attempt $attempt failed. Retrying..."
                if ($RetryDelaySeconds -gt 0) {
                    Start-Sleep -Seconds $RetryDelaySeconds
                }
            }
        }
    }

    if ($Texts.Count -le 1) {
        throw $lastError
    }

    $leftCount = [Math]::Floor($Texts.Count / 2)
    $rightStart = $leftCount
    & $Log "Gemini returned the wrong number of subtitles. Splitting this chunk into $leftCount and $($Texts.Count - $rightStart)."

    $left = Invoke-TranslationTextsWithFallback `
        -Texts @($Texts[0..($leftCount - 1)]) `
        -ApiKey $ApiKey `
        -Direction $Direction `
        -Log $Log `
        -Translate $Translate `
        -RetryDelaySeconds $RetryDelaySeconds

    $right = Invoke-TranslationTextsWithFallback `
        -Texts @($Texts[$rightStart..($Texts.Count - 1)]) `
        -ApiKey $ApiKey `
        -Direction $Direction `
        -Log $Log `
        -Translate $Translate `
        -RetryDelaySeconds $RetryDelaySeconds

    Write-Output -NoEnumerate @($left + $right)
}

function Read-TextFileShared {
    param([string]$Path)

    for ($attempt = 1; $attempt -le 20; $attempt++) {
        try {
            $stream = [System.IO.File]::Open(
                $Path,
                [System.IO.FileMode]::Open,
                [System.IO.FileAccess]::Read,
                [System.IO.FileShare]::ReadWrite
            )
            try {
                $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8)
                try {
                    return $reader.ReadToEnd()
                } finally {
                    $reader.Dispose()
                }
            } finally {
                $stream.Dispose()
            }
        } catch {
            if ($attempt -eq 20) {
                throw
            }
            Start-Sleep -Milliseconds 50
        }
    }
}

function Try-ReadTextFileShared {
    param([string]$Path)

    try {
        return Read-TextFileShared $Path
    } catch {
        return $null
    }
}

function Add-TextFileLineShared {
    param(
        [string]$Path,
        [string]$Line
    )

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Line + [Environment]::NewLine)
    for ($attempt = 1; $attempt -le 20; $attempt++) {
        try {
            $stream = [System.IO.File]::Open(
                $Path,
                [System.IO.FileMode]::Append,
                [System.IO.FileAccess]::Write,
                [System.IO.FileShare]::ReadWrite
            )
            try {
                $stream.Write($bytes, 0, $bytes.Length)
                $stream.Flush()
                return
            } finally {
                $stream.Dispose()
            }
        } catch {
            if ($attempt -eq 20) {
                throw
            }
            Start-Sleep -Milliseconds 50
        }
    }
}

function Write-WorkerLog {
    param(
        [string]$Path,
        [string]$Message
    )

    Add-TextFileLineShared -Path $Path -Line "[$(Get-Date -Format HH:mm:ss)] $Message"
}

function Translate-SrtFile {
    param(
        [string]$InputPath,
        [string]$Direction,
        [string]$ApiKey,
        [scriptblock]$Log,
        [scriptblock]$SetProgress,
        [scriptblock]$ShouldCancel
    )

    $content = [System.IO.File]::ReadAllText($InputPath, [System.Text.Encoding]::UTF8)
    $items = Convert-SrtToTranslationItems $content
    if ($items.Count -eq 0) {
        throw 'No valid SRT subtitle blocks were found.'
    }

    & $Log "Parsed $($items.Count) subtitle blocks."
    $translatedBlocks = New-Object System.Collections.Generic.List[string]
    $current = 0

    while ($current -lt $items.Count) {
        if (& $ShouldCancel) {
            throw 'Canceled by user.'
        }

        $end = [Math]::Min($current + $ChunkSize - 1, $items.Count - 1)
        $chunk = @($items[$current..$end])
        & $SetProgress ([int](($current / [Math]::Max(1, $items.Count)) * 100))
        & $Log "Translating blocks $($current + 1)-$($end + 1)..."

        $translatedTexts = Invoke-TranslationTextsWithFallback `
            -Texts @($chunk | ForEach-Object { $_.Text }) `
            -ApiKey $ApiKey `
            -Direction $Direction `
            -Log $Log

        if (& $ShouldCancel) {
            throw 'Canceled by user.'
        }

        for ($i = 0; $i -lt $chunk.Count; $i++) {
            $text = [string]$translatedTexts[$i]
            $text = ($text -replace " `n ", "`n").Trim()
            $translatedBlocks.Add("$($chunk[$i].Index)`n$($chunk[$i].Timestamp)`n$text")
        }

        $current += $ChunkSize
        & $SetProgress ([int](($current / [Math]::Max(1, $items.Count)) * 100))
    }

    $result = ($translatedBlocks -join "`n`n")
    if ($Direction -eq 'English to Hebrew') {
        $result = Clean-AndFixRtl $result
    }

    if (& $ShouldCancel) {
        throw 'Canceled by user.'
    }

    $outputPath = Get-OutputPath -InputPath $InputPath -Direction $Direction
    [System.IO.File]::WriteAllText($outputPath, $result, (New-Object System.Text.UTF8Encoding($true)))
    & $SetProgress 100
    return $outputPath
}

function Invoke-WorkerMode {
    try {
        $apiKey = Get-ApiKey
        if (-not $apiKey) {
            throw 'No Gemini API key is available.'
        }

        $writeLog = {
            param([string]$Message)
            Write-WorkerLog -Path $LogFile -Message $Message
        }

        $writeProgress = {
            param([int]$Value)
            [System.IO.File]::WriteAllText($ProgressFile, [string][Math]::Max(0, [Math]::Min(100, $Value)))
        }

        $subtitleInputPath = Resolve-SubtitleInputPath -InputPath $InputPath -Log $writeLog
        if ($subtitleInputPath -ne $InputPath) {
            & $writeLog "Subtitle input: $subtitleInputPath"
        }

        $directionCheck = Test-TranslationDirectionLooksValid -InputPath $subtitleInputPath -Direction $Direction
        if (-not $directionCheck.IsValid) {
            throw $directionCheck.Message
        }

        $output = Translate-SrtFile `
            -InputPath $subtitleInputPath `
            -Direction $Direction `
            -ApiKey $apiKey `
            -Log $writeLog `
            -SetProgress $writeProgress `
            -ShouldCancel { $false }

        [System.IO.File]::WriteAllText($ResultFile, $output, [System.Text.Encoding]::UTF8)
        [System.IO.File]::WriteAllText($DoneFile, 'OK', [System.Text.Encoding]::UTF8)
        exit 0
    } catch {
        $details = Format-ErrorDetails $_
        Write-WorkerLog -Path $LogFile -Message $details
        [System.IO.File]::WriteAllText($DoneFile, "ERROR`n$details", [System.Text.Encoding]::UTF8)
        exit 1
    }
}

function Invoke-ExtractWorkerMode {
    try {
        $writeLog = {
            param([string]$Message)
            Write-WorkerLog -Path $LogFile -Message $Message
        }

        $writeProgress = {
            param([int]$Value)
            [System.IO.File]::WriteAllText($ProgressFile, [string][Math]::Max(0, [Math]::Min(100, $Value)))
        }

        if (-not (Test-VideoFilePath $InputPath)) {
            throw 'Extract requires a supported video file: .mkv, .mp4, .avi, .mov, .m4v, .webm.'
        }

        & $writeProgress 5
        $output = Extract-EnglishSubtitleFromVideo -VideoPath $InputPath -Log $writeLog
        & $writeProgress 100

        [System.IO.File]::WriteAllText($ResultFile, $output, [System.Text.Encoding]::UTF8)
        [System.IO.File]::WriteAllText($DoneFile, 'OK', [System.Text.Encoding]::UTF8)
        exit 0
    } catch {
        $details = Format-ErrorDetails $_
        Write-WorkerLog -Path $LogFile -Message $details
        [System.IO.File]::WriteAllText($DoneFile, "ERROR`n$details", [System.Text.Encoding]::UTF8)
        exit 1
    }
}

function Invoke-MockWorkerMode {
    try {
        Write-WorkerLog -Path $LogFile -Message 'Parsed 40 subtitle blocks.'
        [System.IO.File]::WriteAllText($ProgressFile, '0', [System.Text.Encoding]::UTF8)
        Start-Sleep -Milliseconds 300
        Write-WorkerLog -Path $LogFile -Message 'Translating blocks 1-20...'
        [System.IO.File]::WriteAllText($ProgressFile, '50', [System.Text.Encoding]::UTF8)
        Start-Sleep -Milliseconds 300
        Write-WorkerLog -Path $LogFile -Message 'Translating blocks 21-40...'
        [System.IO.File]::WriteAllText($ProgressFile, '100', [System.Text.Encoding]::UTF8)
        [System.IO.File]::WriteAllText($ResultFile, 'C:\Temp\translated.eng.srt', [System.Text.Encoding]::UTF8)
        [System.IO.File]::WriteAllText($DoneFile, 'OK', [System.Text.Encoding]::UTF8)
        exit 0
    } catch {
        $details = Format-ErrorDetails $_
        Write-WorkerLog -Path $LogFile -Message $details
        [System.IO.File]::WriteAllText($DoneFile, "ERROR`n$details", [System.Text.Encoding]::UTF8)
        exit 1
    }
}

function Assert-Equal {
    param([object]$Actual, [object]$Expected, [string]$Name)
    if ($Actual -ne $Expected) {
        throw "$Name failed. Expected '$Expected', got '$Actual'."
    }
}

function Assert-True {
    param([bool]$Condition, [string]$Name)
    if (-not $Condition) {
        throw "$Name failed."
    }
}

function Assert-ThrowsLike {
    param([scriptblock]$ScriptBlock, [string]$Pattern, [string]$Name)
    try {
        & $ScriptBlock
    } catch {
        if ($_.Exception.Message -match $Pattern) {
            return
        }
        throw "$Name failed. Unexpected error: $($_.Exception.Message)"
    }
    throw "$Name failed. Expected an error matching '$Pattern'."
}

function Invoke-SelfTests {
    $tmp = Join-Path $env:TEMP ('gst-selftest-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    try {
        Assert-Equal (Get-OutputPath (Join-Path $tmp 'episode.heb.srt') 'Hebrew to English') (Join-Path $tmp 'episode.eng.srt') 'Hebrew output path'
        Assert-Equal (Get-OutputPath (Join-Path $tmp 'episode.en.srt') 'English to Hebrew') (Join-Path $tmp 'episode.heb.srt') 'English output path'
        Assert-True (Test-SrtFilePath (Join-Path $tmp 'episode.srt')) 'SRT path detection'
        Assert-True (Test-VideoFilePath (Join-Path $tmp 'episode.mkv')) 'Video path detection'
        Assert-Equal (Get-ExtractedSubtitlePath (Join-Path $tmp 'episode.mkv')) (Join-Path $tmp 'episode.eng.srt') 'Extracted subtitle output path'

        $streams = @(
            [pscustomobject]@{
                index = 2
                codec_type = 'subtitle'
                codec_name = 'hdmv_pgs_subtitle'
                tags = [pscustomobject]@{ language = 'eng'; title = 'English PGS' }
            },
            [pscustomobject]@{
                index = 3
                codec_type = 'subtitle'
                codec_name = 'subrip'
                tags = [pscustomobject]@{ language = 'jpn'; title = 'Japanese' }
            },
            [pscustomobject]@{
                index = 4
                codec_type = 'subtitle'
                codec_name = 'ass'
                tags = [pscustomobject]@{ language = 'eng'; title = 'English signs' }
            }
        )
        $selectedStream = Get-EnglishTextSubtitleStream $streams
        Assert-Equal $selectedStream.index 4 'English text stream selection'
        Assert-Equal (Convert-SecondsToSrtTimestamp '3661.234') '01:01:01,234' 'SRT timestamp formatting'
        Assert-Equal (Convert-FfprobePacketDataToText "`n00000000: 4865 6c6c 6f2e                           Hello.`n") 'Hello.' 'ffprobe packet hex decoding'

        $knownAsL = -join @(
            [char]0x05D9, [char]0x05D3, [char]0x05D5, [char]0x05E2,
            ' ',
            [char]0x05D2, [char]0x05DD,
            ' ',
            [char]0x05DB, '-L.'
        )
        $shalom = -join @([char]0x05E9, [char]0x05DC, [char]0x05D5, [char]0x05DD)
        $olam = -join @([char]0x05E2, [char]0x05D5, [char]0x05DC, [char]0x05DD)
        $bdika = -join @([char]0x05D1, [char]0x05D3, [char]0x05D9, [char]0x05E7, [char]0x05D4)

        $sample = "1`n00:00:01,000 --> 00:00:02,000`n<i>$knownAsL</i>"
        $fixed = Clean-AndFixRtl $sample
        Assert-True ($fixed.Contains([string]$RLI)) 'RTL isolate marker exists'
        Assert-True ($fixed.Contains([string]$LRI)) 'LTR isolate marker exists'
        Assert-True ($fixed.Contains([string]$PDI)) 'PDI marker exists'

        $items = Convert-SrtToTranslationItems "1`n00:00:01,000 --> 00:00:02,000`n$shalom`n$olam`n`n2`n00:00:03,000 --> 00:00:04,000`n$bdika"
        Assert-Equal $items.Count 2 'SRT parsing count'
        Assert-True ($items[0].Text.Contains(" `n ")) 'SRT line placeholder'

        $oneItem = Convert-SrtToTranslationItems "1`n00:00:01,000 --> 00:00:02,000`n$shalom"
        Assert-Equal $oneItem.Count 1 'Single SRT block parsing count'
        Assert-Equal $oneItem[0].Text $shalom 'Single SRT block text'

        $hebrewSrtPath = Join-Path $tmp 'sample.heb.srt'
        [System.IO.File]::WriteAllText($hebrewSrtPath, "1`n00:00:01,000 --> 00:00:02,000`n$shalom $olam $bdika $shalom $olam $bdika $shalom $olam $bdika")
        $hebrewProfile = Get-SubtitleLanguageProfile ([System.IO.File]::ReadAllText($hebrewSrtPath))
        Assert-Equal $hebrewProfile.LikelyLanguage 'Hebrew' 'Hebrew profile detection'
        $hebrewGuard = Test-TranslationDirectionLooksValid $hebrewSrtPath 'English to Hebrew'
        Assert-True (-not $hebrewGuard.IsValid) 'Hebrew wrong-direction guard'

        $englishSrtPath = Join-Path $tmp 'sample.eng.srt'
        [System.IO.File]::WriteAllText($englishSrtPath, "1`n00:00:01,000 --> 00:00:02,000`nThis is a normal English subtitle line with enough letters to detect the language.")
        $englishProfile = Get-SubtitleLanguageProfile ([System.IO.File]::ReadAllText($englishSrtPath))
        Assert-Equal $englishProfile.LikelyLanguage 'English' 'English profile detection'
        $englishGuard = Test-TranslationDirectionLooksValid $englishSrtPath 'Hebrew to English'
        Assert-True (-not $englishGuard.IsValid) 'English wrong-direction guard'

        Assert-ThrowsLike { Convert-GeminiResponseToStringArray $null } 'empty response' 'Empty Gemini response'
        Assert-ThrowsLike { Convert-GeminiResponseToStringArray ([pscustomobject]@{}) } 'no candidates' 'Missing candidates response'
        Assert-ThrowsLike {
            Convert-GeminiResponseToStringArray ([pscustomobject]@{
                candidates = @([pscustomobject]@{ finishReason = 'MAX_TOKENS' })
            })
        } 'MAX_TOKENS' 'Non-stop Gemini response'
        Assert-ThrowsLike {
            Convert-GeminiResponseToStringArray ([pscustomobject]@{
                candidates = @([pscustomobject]@{
                    finishReason = 'STOP'
                    content = [pscustomobject]@{
                        parts = @([pscustomobject]@{ text = 'not json' })
                    }
                })
            })
        } 'invalid JSON' 'Invalid JSON Gemini response'

        $oneTranslation = Convert-GeminiResponseToStringArray ([pscustomobject]@{
            candidates = @([pscustomobject]@{
                finishReason = 'STOP'
                content = [pscustomobject]@{
                    parts = @([pscustomobject]@{ text = '["Tea"]' })
                }
            })
        })
        Assert-Equal $oneTranslation.Count 1 'Single Gemini translation count'
        Assert-Equal $oneTranslation[0] 'Tea' 'Single Gemini translation value'

        $fallbackLogs = New-Object System.Collections.Generic.List[string]
        $fallbackTranslator = {
            param([string[]]$Texts, [string]$ApiKey, [string]$Direction)
            if ($Texts.Count -gt 2) {
                Write-Output -NoEnumerate @('too few')
                return
            }
            Write-Output -NoEnumerate @($Texts | ForEach-Object { "translated $_" })
        }
        $fallbackTranslations = Invoke-TranslationTextsWithFallback `
            -Texts @('one', 'two', 'three', 'four') `
            -ApiKey 'test-key' `
            -Direction 'English to Hebrew' `
            -Log { param([string]$Message) $fallbackLogs.Add($Message) } `
            -Translate $fallbackTranslator `
            -RetryDelaySeconds 0
        Assert-Equal $fallbackTranslations.Count 4 'Fallback translation count'
        Assert-Equal $fallbackTranslations[2] 'translated three' 'Fallback translation order'
        Assert-True (($fallbackLogs -join "`n") -match 'Splitting this chunk') 'Fallback split log'

        $resultPath = Join-Path $tmp 'result.txt'
        [System.IO.File]::WriteAllText($resultPath, 'C:\Temp\translated.eng.srt', [System.Text.Encoding]::UTF8)
        Assert-Equal (Read-WorkerResultFile $resultPath) 'C:\Temp\translated.eng.srt' 'Worker result reader'
        Assert-ThrowsLike { Read-WorkerResultFile '' } 'path is empty' 'Empty worker result path'
        Assert-ThrowsLike { Read-WorkerResultFile (Join-Path $tmp 'missing.txt') } 'is missing' 'Missing worker result path'

        $sharedReadPath = Join-Path $tmp 'shared-log.txt'
        $sharedStream = [System.IO.File]::Open($sharedReadPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::ReadWrite)
        try {
            $bytes = [System.Text.Encoding]::UTF8.GetBytes('shared log line')
            $sharedStream.Write($bytes, 0, $bytes.Length)
            $sharedStream.Flush()
            Assert-Equal (Read-TextFileShared $sharedReadPath) 'shared log line' 'Shared log reader'
            Write-WorkerLog -Path $sharedReadPath -Message 'second line'
            Assert-True ((Read-TextFileShared $sharedReadPath) -match 'second line') 'Shared log writer'
        } finally {
            $sharedStream.Dispose()
        }

        'SELFTEST_OK'
    } finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Show-CompletionDialog {
    param(
        [string]$OutputPath,
        [string]$Title = 'Operation Complete',
        [System.Windows.Forms.IWin32Window]$Owner = $null
    )

    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = $Title
    $dialog.StartPosition = 'CenterParent'
    $dialog.FormBorderStyle = 'FixedDialog'
    $dialog.MaximizeBox = $false
    $dialog.MinimizeBox = $false
    $dialog.ClientSize = New-Object System.Drawing.Size(540, 170)

    $label = New-Object System.Windows.Forms.Label
    $label.Location = New-Object System.Drawing.Point(16, 16)
    $label.Size = New-Object System.Drawing.Size(500, 55)
    $label.Text = "Created:`r`n$OutputPath"
    $dialog.Controls.Add($label)

    $folderButton = New-Object System.Windows.Forms.Button
    $folderButton.Location = New-Object System.Drawing.Point(16, 110)
    $folderButton.Size = New-Object System.Drawing.Size(120, 34)
    $folderButton.Text = 'Open Folder'
    $folderButton.Add_Click({
        Start-Process explorer.exe "/select,`"$OutputPath`""
        $dialog.Close()
    })
    $dialog.Controls.Add($folderButton)

    $fileButton = New-Object System.Windows.Forms.Button
    $fileButton.Location = New-Object System.Drawing.Point(150, 110)
    $fileButton.Size = New-Object System.Drawing.Size(120, 34)
    $fileButton.Text = 'Open File'
    $fileButton.Add_Click({
        Start-Process -FilePath $OutputPath
        $dialog.Close()
    })
    $dialog.Controls.Add($fileButton)

    $okButton = New-Object System.Windows.Forms.Button
    $okButton.Location = New-Object System.Drawing.Point(400, 110)
    $okButton.Size = New-Object System.Drawing.Size(120, 34)
    $okButton.Text = 'OK'
    $okButton.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $dialog.AcceptButton = $okButton
    $dialog.CancelButton = $okButton
    $dialog.Controls.Add($okButton)

    if ($Owner) {
        [void]$dialog.ShowDialog($Owner)
    } else {
        [void]$dialog.ShowDialog()
    }
}

function Quote-ProcessArgument {
    param([string]$Value)
    return '"' + ($Value -replace '"', '\"') + '"'
}

function Show-MainForm {
    $form = New-Object System.Windows.Forms.Form
    $form.Text = $AppName
    $form.StartPosition = 'CenterScreen'
    $form.Size = New-Object System.Drawing.Size(820, 520)
    $form.MinimumSize = New-Object System.Drawing.Size(820, 520)

    $hintLabel = New-Object System.Windows.Forms.Label
    $hintLabel.Location = New-Object System.Drawing.Point(16, 12)
    $hintLabel.Size = New-Object System.Drawing.Size(770, 34)
    $hintLabel.Text = "* Select a video file to extract an SRT from it.`r`n* Select an SRT to translate."
    $form.Controls.Add($hintLabel)

    $fileLabel = New-Object System.Windows.Forms.Label
    $fileLabel.Location = New-Object System.Drawing.Point(16, 56)
    $fileLabel.Size = New-Object System.Drawing.Size(90, 24)
    $fileLabel.Text = 'Input file:'
    $form.Controls.Add($fileLabel)

    $fileText = New-Object System.Windows.Forms.TextBox
    $fileText.Location = New-Object System.Drawing.Point(110, 54)
    $fileText.Size = New-Object System.Drawing.Size(565, 24)
    $form.Controls.Add($fileText)

    $browseButton = New-Object System.Windows.Forms.Button
    $browseButton.Location = New-Object System.Drawing.Point(690, 52)
    $browseButton.Size = New-Object System.Drawing.Size(95, 28)
    $browseButton.Text = 'Browse...'
    $form.Controls.Add($browseButton)

    $directionLabel = New-Object System.Windows.Forms.Label
    $directionLabel.Location = New-Object System.Drawing.Point(16, 98)
    $directionLabel.Size = New-Object System.Drawing.Size(90, 24)
    $directionLabel.Text = 'Direction:'
    $form.Controls.Add($directionLabel)

    $directionCombo = New-Object System.Windows.Forms.ComboBox
    $directionCombo.Location = New-Object System.Drawing.Point(110, 96)
    $directionCombo.Size = New-Object System.Drawing.Size(220, 24)
    $directionCombo.DropDownStyle = 'DropDownList'
    [void]$directionCombo.Items.Add('Hebrew to English')
    [void]$directionCombo.Items.Add('English to Hebrew')
    $directionCombo.SelectedIndex = 0
    $directionCombo.Enabled = $false
    $form.Controls.Add($directionCombo)

    $extractButton = New-Object System.Windows.Forms.Button
    $extractButton.Location = New-Object System.Drawing.Point(350, 93)
    $extractButton.Size = New-Object System.Drawing.Size(95, 32)
    $extractButton.Text = 'Extract'
    $extractButton.Enabled = $false
    $form.Controls.Add($extractButton)

    $translateButton = New-Object System.Windows.Forms.Button
    $translateButton.Location = New-Object System.Drawing.Point(460, 93)
    $translateButton.Size = New-Object System.Drawing.Size(95, 32)
    $translateButton.Text = 'Translate'
    $translateButton.Enabled = $false
    $form.Controls.Add($translateButton)

    $cancelButton = New-Object System.Windows.Forms.Button
    $cancelButton.Location = New-Object System.Drawing.Point(570, 93)
    $cancelButton.Size = New-Object System.Drawing.Size(90, 32)
    $cancelButton.Text = 'Cancel'
    $cancelButton.Enabled = $false
    $form.Controls.Add($cancelButton)

    $resetKeyButton = New-Object System.Windows.Forms.Button
    $resetKeyButton.Location = New-Object System.Drawing.Point(675, 93)
    $resetKeyButton.Size = New-Object System.Drawing.Size(110, 32)
    $resetKeyButton.Text = 'Reset API Key'
    $form.Controls.Add($resetKeyButton)

    $progress = New-Object System.Windows.Forms.ProgressBar
    $progress.Location = New-Object System.Drawing.Point(16, 141)
    $progress.Size = New-Object System.Drawing.Size(770, 22)
    $form.Controls.Add($progress)

    $logBox = New-Object System.Windows.Forms.TextBox
    $logBox.Location = New-Object System.Drawing.Point(16, 181)
    $logBox.Size = New-Object System.Drawing.Size(770, 279)
    $logBox.Multiline = $true
    $logBox.ScrollBars = 'Vertical'
    $logBox.ReadOnly = $true
    $form.Controls.Add($logBox)

    $appendLog = {
        param([string]$Message)
        $line = "[$(Get-Date -Format HH:mm:ss)] $Message`r`n"
        if ($logBox) {
            $logBox.AppendText($line)
        } else {
            [Console]::Error.WriteLine($line.TrimEnd())
        }
    }

    $setProgress = {
        param([int]$Value)
        $progress.Value = [Math]::Max(0, [Math]::Min(100, $Value))
    }

    $script:currentProcess = $null
    $script:currentTimer = $null
    $script:cancelRequested = $false
    $script:logReadLength = 0
    $script:currentJobDir = $null
    $script:currentLogFile = $null
    $script:currentProgressFile = $null
    $script:currentResultFile = $null
    $script:currentDoneFile = $null

    $updateInputButtons = {
        $path = $fileText.Text.Trim()
        $hasExistingPath = $path -and (Test-Path -LiteralPath $path)
        $extractButton.Enabled = $hasExistingPath -and (Test-VideoFilePath $path)
        $translateButton.Enabled = $hasExistingPath -and (Test-SrtFilePath $path)
        $directionCombo.Enabled = $translateButton.Enabled
    }

    $fileText.Add_TextChanged({
        & $updateInputButtons
    })

    $browseButton.Add_Click({
        $dialog = New-Object System.Windows.Forms.OpenFileDialog
        $dialog.Filter = 'Subtitles and videos (*.srt;*.mkv;*.mp4;*.avi;*.mov;*.m4v;*.webm)|*.srt;*.mkv;*.mp4;*.avi;*.mov;*.m4v;*.webm|SRT subtitles (*.srt)|*.srt|Video files (*.mkv;*.mp4;*.avi;*.mov;*.m4v;*.webm)|*.mkv;*.mp4;*.avi;*.mov;*.m4v;*.webm|All files (*.*)|*.*'
        $dialog.Title = 'Select subtitle or video file'
        if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $fileText.Text = $dialog.FileName
            if (Test-VideoFilePath $dialog.FileName) {
                $directionCombo.SelectedItem = 'English to Hebrew'
            }
            & $updateInputButtons
        }
    })

    $resetKeyButton.Add_Click({
        $confirm = [System.Windows.Forms.MessageBox]::Show(
            "Reset the saved Gemini API key?`r`n`r`nYou will need to enter it again before translating.",
            $AppName,
            [System.Windows.Forms.MessageBoxButtons]::OKCancel,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )
        if ($confirm -ne [System.Windows.Forms.DialogResult]::OK) {
            return
        }

        if (Test-Path -LiteralPath $KeyFile) {
            Remove-Item -LiteralPath $KeyFile -Force
        }
        [void](Show-ApiKeyDialog)
    })

    $cancelButton.Add_Click({
        $script:cancelRequested = $true
        if ($script:currentProcess -and -not $script:currentProcess.HasExited) {
            try {
                $script:currentProcess.Kill()
            } catch {
            }
        }
        if ($script:currentTimer) {
            $script:currentTimer.Stop()
            $script:currentTimer.Dispose()
            $script:currentTimer = $null
        }
        $cancelButton.Enabled = $false
        $cancelButton.Text = 'Cancel'
        & $updateInputButtons
        $browseButton.Enabled = $true
        $resetKeyButton.Enabled = $true
        $script:currentProcess = $null
        & $appendLog 'Cancel requested.'
        & $appendLog 'Canceled.'
                [System.Windows.Forms.MessageBox]::Show(
                    $form,
                    'Operation canceled. No output file was written.',
                    $AppName,
                    [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Information
        ) | Out-Null
    })

    $startWorkerOperation = {
        param(
            [string[]]$WorkerArguments,
            [string[]]$InitialLogLines,
            [string]$CompletionTitle
        )

        $extractButton.Enabled = $false
        $translateButton.Enabled = $false
        $browseButton.Enabled = $false
        $resetKeyButton.Enabled = $false
        $cancelButton.Enabled = $true
        $cancelButton.Text = 'Cancel'
        $progress.Value = 0
        $logBox.Clear()

        foreach ($line in $InitialLogLines) {
            & $appendLog $line
        }

        Ensure-ConfigDir
        $jobsDir = Join-Path $ConfigDir 'jobs'
        if (-not (Test-Path -LiteralPath $jobsDir)) {
            New-Item -ItemType Directory -Path $jobsDir -Force | Out-Null
        }

        $script:currentJobDir = Join-Path $jobsDir ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:currentJobDir -Force | Out-Null

        $script:currentLogFile = Join-Path $script:currentJobDir 'log.txt'
        $script:currentProgressFile = Join-Path $script:currentJobDir 'progress.txt'
        $script:currentResultFile = Join-Path $script:currentJobDir 'result.txt'
        $script:currentDoneFile = Join-Path $script:currentJobDir 'done.txt'
        [System.IO.File]::WriteAllText($script:currentLogFile, '', [System.Text.Encoding]::UTF8)
        [System.IO.File]::WriteAllText($script:currentProgressFile, '0', [System.Text.Encoding]::UTF8)
        $script:logReadLength = 0
        $script:cancelRequested = $false

        $powershellExe = (Get-Command powershell.exe).Source
        $arguments = @(
            '-NoProfile',
            '-ExecutionPolicy', 'Bypass',
            '-File', (Quote-ProcessArgument $PSCommandPath)
        ) + $WorkerArguments + @(
            '-LogFile', (Quote-ProcessArgument $script:currentLogFile),
            '-ProgressFile', (Quote-ProcessArgument $script:currentProgressFile),
            '-ResultFile', (Quote-ProcessArgument $script:currentResultFile),
            '-DoneFile', (Quote-ProcessArgument $script:currentDoneFile)
        )

        $script:currentProcess = Start-Process `
            -FilePath $powershellExe `
            -ArgumentList ($arguments -join ' ') `
            -WindowStyle Hidden `
            -PassThru

        $timer = New-Object System.Windows.Forms.Timer
        $timer.Interval = 500
        $script:currentTimer = $timer
        $timer.Add_Tick({
            try {
                if (Test-Path -LiteralPath $script:currentLogFile) {
                    $logText = Try-ReadTextFileShared $script:currentLogFile
                    if ($null -ne $logText -and $logText.Length -gt $script:logReadLength) {
                        $logBox.AppendText($logText.Substring($script:logReadLength).Replace("`n", "`r`n"))
                        $script:logReadLength = $logText.Length
                    }
                }

                if (Test-Path -LiteralPath $script:currentProgressFile) {
                    $progressRawText = Try-ReadTextFileShared $script:currentProgressFile
                    if ($null -eq $progressRawText) {
                        return
                    }
                    $progressText = $progressRawText.Trim()
                    $progressValue = 0
                    if ([int]::TryParse($progressText, [ref]$progressValue)) {
                        & $setProgress $progressValue
                    }
                }

                $finished = (Test-Path -LiteralPath $script:currentDoneFile) -or ($script:currentProcess -and $script:currentProcess.HasExited)
                if (-not $finished) {
                    return
                }

                if ($script:currentTimer) {
                    $script:currentTimer.Stop()
                    $script:currentTimer.Dispose()
                }
                $script:currentTimer = $null

                if ($script:cancelRequested) {
                    & $appendLog 'Canceled.'
                    [System.Windows.Forms.MessageBox]::Show(
                        $form,
                        'Operation canceled. No output file was written.',
                        $AppName,
                        [System.Windows.Forms.MessageBoxButtons]::OK,
                        [System.Windows.Forms.MessageBoxIcon]::Information
                    ) | Out-Null
                } elseif (Test-Path -LiteralPath $script:currentDoneFile) {
                    $doneText = Try-ReadTextFileShared $script:currentDoneFile
                    if ($null -eq $doneText) {
                        return
                    }
                    if ($doneText.StartsWith('OK')) {
                        & $setProgress 100
                        $output = Read-WorkerResultFile $script:currentResultFile
                        & $appendLog "Done: $output"
                        Show-CompletionDialog -OutputPath $output -Title $CompletionTitle -Owner $form
                    } else {
                        $message = ($doneText -replace '^ERROR\s*', '').Trim()
                        if (-not $message) {
                            $message = 'Operation failed.'
                        }
                        & $appendLog "Error: $message"
                        [System.Windows.Forms.MessageBox]::Show(
                            $form,
                            $message,
                            $AppName,
                            [System.Windows.Forms.MessageBoxButtons]::OK,
                            [System.Windows.Forms.MessageBoxIcon]::Error
                        ) | Out-Null
                    }
                } else {
                    & $appendLog 'Error: worker process exited unexpectedly.'
                    [System.Windows.Forms.MessageBox]::Show(
                        $form,
                        'Worker process exited unexpectedly.',
                        $AppName,
                        [System.Windows.Forms.MessageBoxButtons]::OK,
                        [System.Windows.Forms.MessageBoxIcon]::Error
                    ) | Out-Null
                }

                & $updateInputButtons
                $browseButton.Enabled = $true
                $resetKeyButton.Enabled = $true
                $cancelButton.Enabled = $false
                $cancelButton.Text = 'Cancel'
                $script:currentProcess = $null
            } catch {
                & $appendLog (Format-ErrorDetails $_)
                if ($script:currentTimer) {
                    $script:currentTimer.Stop()
                    $script:currentTimer.Dispose()
                    $script:currentTimer = $null
                }
                & $updateInputButtons
                $browseButton.Enabled = $true
                $resetKeyButton.Enabled = $true
                $cancelButton.Enabled = $false
                $cancelButton.Text = 'Cancel'
                $script:currentProcess = $null
            }
        })
        $timer.Start()
    }

    $extractButton.Add_Click({
        try {
            $inputPath = $fileText.Text.Trim()
            if (-not $inputPath -or -not (Test-Path -LiteralPath $inputPath)) {
                [System.Windows.Forms.MessageBox]::Show(
                    $form,
                    'Please select an existing video file.',
                    $AppName,
                    [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Warning
                ) | Out-Null
                return
            }

            if (-not (Test-VideoFilePath $inputPath)) {
                [System.Windows.Forms.MessageBox]::Show(
                    $form,
                    'Extract requires one of these video formats: .mkv, .mp4, .avi, .mov, .m4v, .webm.',
                    $AppName,
                    [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Warning
                ) | Out-Null
                return
            }

            & $startWorkerOperation `
                @(
                    '-ExtractWorkerMode',
                    '-InputPath', (Quote-ProcessArgument $inputPath)
                ) `
                @(
                    "Input: $inputPath",
                    'Mode: extract embedded English subtitles only.'
                ) `
                'Extraction Complete'
        } catch {
            & $updateInputButtons
            $browseButton.Enabled = $true
            $resetKeyButton.Enabled = $true
            $cancelButton.Enabled = $false
            $cancelButton.Text = 'Cancel'
            & $appendLog "Error: $($_.Exception.Message)"
            [System.Windows.Forms.MessageBox]::Show(
                $form,
                $_.Exception.Message,
                $AppName,
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error
            ) | Out-Null
        }
    })

    $translateButton.Add_Click({
        try {
            $inputPath = $fileText.Text.Trim()
            if (-not $inputPath -or -not (Test-Path -LiteralPath $inputPath)) {
                [System.Windows.Forms.MessageBox]::Show(
                    $form,
                    'Please select an existing .srt subtitle file.',
                    $AppName,
                    [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Warning
                ) | Out-Null
                return
            }

            $apiKey = Get-ApiKey
            if (-not $apiKey) {
                return
            }

            $direction = [string]$directionCombo.SelectedItem
            if (-not (Test-SrtFilePath $inputPath)) {
                [System.Windows.Forms.MessageBox]::Show(
                    $form,
                    'Translate requires an .srt subtitle file. Select a video file and click Extract first.',
                    $AppName,
                    [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Warning
                ) | Out-Null
                return
            }

            & $startWorkerOperation `
                @(
                    '-WorkerMode',
                    '-InputPath', (Quote-ProcessArgument $inputPath),
                    '-Direction', (Quote-ProcessArgument $direction)
                ) `
                @(
                    "Input: $inputPath",
                    "Direction: $direction",
                    'Mode: translate subtitle file.'
                ) `
                'Translation Complete'
        } catch {
            & $updateInputButtons
            $browseButton.Enabled = $true
            $resetKeyButton.Enabled = $true
            $cancelButton.Enabled = $false
            $cancelButton.Text = 'Cancel'
            & $appendLog "Error: $($_.Exception.Message)"
            [System.Windows.Forms.MessageBox]::Show(
                $form,
                $_.Exception.Message,
                $AppName,
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error
            ) | Out-Null
        }
    })

    [void]$form.ShowDialog()
}

if ($RunSelfTests) {
    Invoke-SelfTests
} elseif ($MockWorkerMode) {
    Invoke-MockWorkerMode
} elseif ($ExtractWorkerMode) {
    Invoke-ExtractWorkerMode
} elseif ($WorkerMode) {
    Invoke-WorkerMode
} else {
    Show-MainForm
}

