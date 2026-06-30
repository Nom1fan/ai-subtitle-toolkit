param(
    [switch]$Wet
)

$ErrorActionPreference = 'Stop'

$ScriptPath = Join-Path $PSScriptRoot 'AiSubtitleToolkit.ps1'

function Assert-True {
    param([bool]$Condition, [string]$Name)
    if (-not $Condition) {
        throw $Name
    }
}

function New-TestJobDir {
    $dir = Join-Path $env:TEMP ('gst-test-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    return $dir
}

function Invoke-ParserTest {
    $script = Get-Content -Raw -LiteralPath $ScriptPath
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseInput($script, [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors.Count -gt 0) {
        throw (($errors | ForEach-Object { "Line $($_.Extent.StartLineNumber): $($_.Message)" }) -join "`n")
    }
    'PASS parser'
}

function Invoke-SelfTest {
    $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ScriptPath -RunSelfTests
    Assert-True ($LASTEXITCODE -eq 0) 'self-tests process failed'
    Assert-True (($output -join "`n") -match 'SELFTEST_OK') 'self-tests did not report SELFTEST_OK'
    'PASS self-tests'
}

function Invoke-MockWorkerSuccessTest {
    $dir = New-TestJobDir
    try {
        $log = Join-Path $dir 'log.txt'
        $progress = Join-Path $dir 'progress.txt'
        $result = Join-Path $dir 'result.txt'
        $done = Join-Path $dir 'done.txt'

        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ScriptPath `
            -MockWorkerMode `
            -LogFile $log `
            -ProgressFile $progress `
            -ResultFile $result `
            -DoneFile $done | Out-Null

        Assert-True ($LASTEXITCODE -eq 0) 'mock worker exited non-zero'
        Assert-True (Test-Path -LiteralPath $done) 'mock worker did not create done file'
        Assert-True ((Get-Content -Raw -LiteralPath $done).StartsWith('OK')) 'mock worker did not report OK'
        Assert-True ((Get-Content -Raw -LiteralPath $progress).Trim() -eq '100') 'mock worker did not reach 100 progress'
        Assert-True ((Get-Content -Raw -LiteralPath $log) -match 'Translating blocks 21-40') 'mock worker did not write expected log'
        'PASS mock worker success'
    } finally {
        Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-MockWorkerCancelTest {
    $dir = New-TestJobDir
    try {
        $log = Join-Path $dir 'log.txt'
        $progress = Join-Path $dir 'progress.txt'
        $result = Join-Path $dir 'result.txt'
        $done = Join-Path $dir 'done.txt'

        $args = @(
            '-NoProfile',
            '-ExecutionPolicy', 'Bypass',
            '-File', "`"$ScriptPath`"",
            '-MockWorkerMode',
            '-LogFile', "`"$log`"",
            '-ProgressFile', "`"$progress`"",
            '-ResultFile', "`"$result`"",
            '-DoneFile', "`"$done`""
        ) -join ' '

        $process = Start-Process -FilePath powershell.exe -ArgumentList $args -WindowStyle Hidden -PassThru
        Start-Sleep -Milliseconds 150
        if (-not $process.HasExited) {
            $process.Kill()
        }
        $process.WaitForExit()

        Assert-True (-not (Test-Path -LiteralPath $done)) 'canceled mock worker unexpectedly created done file'
        'PASS mock worker cancel'
    } finally {
        Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-ExtractWorkerExistingSubtitleTest {
    $dir = New-TestJobDir
    try {
        $input = Join-Path $dir 'movie.mkv'
        $existingSubtitle = Join-Path $dir 'movie.eng.srt'
        $log = Join-Path $dir 'log.txt'
        $progress = Join-Path $dir 'progress.txt'
        $result = Join-Path $dir 'result.txt'
        $done = Join-Path $dir 'done.txt'

        [System.IO.File]::WriteAllText($input, '', [System.Text.Encoding]::UTF8)
        [System.IO.File]::WriteAllText(
            $existingSubtitle,
            "1`n00:00:01,000 --> 00:00:02,000`nHello.`n",
            [System.Text.Encoding]::UTF8
        )

        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ScriptPath `
            -ExtractWorkerMode `
            -InputPath $input `
            -LogFile $log `
            -ProgressFile $progress `
            -ResultFile $result `
            -DoneFile $done | Out-Null

        Assert-True ($LASTEXITCODE -eq 0) 'extract worker exited non-zero'
        Assert-True (Test-Path -LiteralPath $done) 'extract worker did not create done file'
        Assert-True ((Get-Content -Raw -LiteralPath $done).StartsWith('OK')) 'extract worker did not report OK'
        Assert-True ((Get-Content -Raw -LiteralPath $progress).Trim() -eq '100') 'extract worker did not reach 100 progress'
        Assert-True ((Get-Content -Raw -LiteralPath $log) -match 'Using existing extracted subtitle') 'extract worker did not reuse existing subtitle'
        Assert-True ((Get-Content -Raw -LiteralPath $result).Trim() -eq $existingSubtitle) 'extract worker result path mismatch'
        'PASS extract worker existing subtitle'
    } finally {
        Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-ExtractWorkerSubripSmokeTest {
    $dir = New-TestJobDir
    try {
        $ffmpeg = Join-Path $PSScriptRoot 'ffmpeg.exe'
        if (-not (Test-Path -LiteralPath $ffmpeg)) {
            'SKIP extract worker SubRip smoke; ffmpeg.exe not found'
            return
        }

        $sourceSubtitle = Join-Path $dir 'source.srt'
        $input = Join-Path $dir 'movie.mkv'
        $log = Join-Path $dir 'log.txt'
        $progress = Join-Path $dir 'progress.txt'
        $result = Join-Path $dir 'result.txt'
        $done = Join-Path $dir 'done.txt'

        [System.IO.File]::WriteAllText(
            $sourceSubtitle,
            "1`r`n00:00:00,100 --> 00:00:01,500`r`nHello from embedded subtitles.`r`n`r`n2`r`n00:00:01,600 --> 00:00:02,000`r`nSecond line.`r`n",
            [System.Text.Encoding]::UTF8
        )

        $previousErrorActionPreference = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            & $ffmpeg -y -hide_banner -loglevel error -f lavfi -i color=c=black:s=320x240:d=3 -i $sourceSubtitle -c:v libx264 -t 3 -c:s srt $input 2>&1 | Out-Null
        } finally {
            $ErrorActionPreference = $previousErrorActionPreference
        }
        Assert-True ($LASTEXITCODE -eq 0) 'failed to create SubRip smoke MKV'

        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ScriptPath `
            -ExtractWorkerMode `
            -InputPath $input `
            -LogFile $log `
            -ProgressFile $progress `
            -ResultFile $result `
            -DoneFile $done | Out-Null

        Assert-True ($LASTEXITCODE -eq 0) 'SubRip extract worker exited non-zero'
        Assert-True ((Get-Content -Raw -LiteralPath $done).StartsWith('OK')) 'SubRip extract worker did not report OK'
        Assert-True ((Get-Content -Raw -LiteralPath $progress).Trim() -eq '100') 'SubRip extract worker did not reach 100 progress'

        $output = (Get-Content -Raw -LiteralPath $result).Trim()
        Assert-True (Test-Path -LiteralPath $output) 'SubRip extract output missing'
        $outputText = Get-Content -Raw -LiteralPath $output
        Assert-True ($outputText -match 'Hello from embedded subtitles') 'SubRip extract output missing first subtitle'
        Assert-True ($outputText -match 'Second line') 'SubRip extract output missing second subtitle'
        Assert-True ((Get-Content -Raw -LiteralPath $log) -match 'Extracting embedded SubRip packets with ffprobe') 'SubRip fast path was not used'
        'PASS extract worker SubRip smoke'
    } finally {
        Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Assert-TextHasLatin {
    param([string]$Text, [string]$Name)
    Assert-True (([regex]::Matches($Text, '[A-Za-z]')).Count -ge 3) $Name
}

function Assert-TextHasHebrew {
    param([string]$Text, [string]$Name)
    Assert-True (([regex]::Matches($Text, '[\u0590-\u05FF]')).Count -ge 3) $Name
}

function Invoke-WetWorkerTranslationTest {
    param(
        [string]$Direction,
        [string]$InputFileName,
        [string]$InputText,
        [scriptblock]$AssertOutputLanguage
    )

    $dir = New-TestJobDir
    try {
        $input = Join-Path $dir $InputFileName
        $log = Join-Path $dir 'log.txt'
        $progress = Join-Path $dir 'progress.txt'
        $result = Join-Path $dir 'result.txt'
        $done = Join-Path $dir 'done.txt'

        [System.IO.File]::WriteAllText(
            $input,
            "1`n00:00:01,000 --> 00:00:02,000`n$InputText`n",
            [System.Text.Encoding]::UTF8
        )

        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ScriptPath `
            -WorkerMode `
            -InputPath $input `
            -Direction $Direction `
            -LogFile $log `
            -ProgressFile $progress `
            -ResultFile $result `
            -DoneFile $done | Out-Null

        Assert-True ($LASTEXITCODE -eq 0) "$Direction wet worker exited non-zero"
        Assert-True (Test-Path -LiteralPath $done) "$Direction wet worker did not create done file"
        Assert-True ((Get-Content -Raw -LiteralPath $done).StartsWith('OK')) "$Direction wet worker did not report OK"
        Assert-True ((Get-Content -Raw -LiteralPath $progress).Trim() -eq '100') "$Direction wet worker did not reach 100 progress"

        $logText = Get-Content -Raw -LiteralPath $log
        Assert-True ($logText -match 'Parsed 1 subtitle blocks') "$Direction wet log missing parse success"
        Assert-True ($logText -match 'Translating blocks 1-1') "$Direction wet log missing translation step"
        Assert-True (-not ($logText -match '(?i)\berror\b|exception')) "$Direction wet log contains an error"

        $outputPath = (Get-Content -Raw -LiteralPath $result).Trim()
        Assert-True (Test-Path -LiteralPath $outputPath) "$Direction wet output file is missing"

        $outputText = Get-Content -Raw -LiteralPath $outputPath
        Assert-True ($outputText -match '00:00:01,000 --> 00:00:02,000') "$Direction wet output lost timestamp"
        & $AssertOutputLanguage $outputText "$Direction wet output language check"

        "PASS wet $Direction"
    } finally {
        Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-WetTests {
    $keyFile = Join-Path (Join-Path $env:APPDATA 'AiSubtitleToolkit') 'key.bin'
    $legacyKeyFile = Join-Path (Join-Path $env:APPDATA 'GeminiSrtTranslator') 'key.bin'
    Assert-True ((Test-Path -LiteralPath $keyFile) -or (Test-Path -LiteralPath $legacyKeyFile)) 'wet tests require a saved Gemini API key; run the app once and save your key first'

    $hebrewInput = -join @(
        [char]0x05D0, [char]0x05E0, [char]0x05D9, ' ',
        [char]0x05D0, [char]0x05D5, [char]0x05D4, [char]0x05D1, ' ',
        [char]0x05EA, [char]0x05D4, '.'
    )

    Invoke-WetWorkerTranslationTest `
        -Direction 'Hebrew to English' `
        -InputFileName 'tiny.heb.srt' `
        -InputText $hebrewInput `
        -AssertOutputLanguage ${function:Assert-TextHasLatin}

    Invoke-WetWorkerTranslationTest `
        -Direction 'English to Hebrew' `
        -InputFileName 'tiny.eng.srt' `
        -InputText 'I love tea.' `
        -AssertOutputLanguage ${function:Assert-TextHasHebrew}
}

Invoke-ParserTest
Invoke-SelfTest
Invoke-MockWorkerSuccessTest
Invoke-MockWorkerCancelTest
Invoke-ExtractWorkerExistingSubtitleTest
Invoke-ExtractWorkerSubripSmokeTest
if ($Wet) {
    Invoke-WetTests
}
'ALL_TESTS_PASS'
