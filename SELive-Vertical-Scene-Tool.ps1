<#
.SYNOPSIS
  SE.Live Vertical Canvas Scene Tool - duplicate and rename scenes on SE.Live
  multistreaming canvases. v2 "surgical": it never rewrites the whole file, it only
  splices in (or touches) the bytes of the scene involved. Every other byte stays identical.

.DESCRIPTION
  Double-click "SELive Scene Tool.bat" (same folder) and the tool:
    1. gracefully closes OBS if it is running (so SE.Live saves fresh state)
    2. auto-detects your SE.Live "composition" files
    3. lets you pick the operation (Duplicate / Rename), canvas, scene and new name
    4. runs with an automatic backup and validation (if anything looks wrong, the file is NOT touched)
    5. restarts OBS

  IMPORTANT - read the README: SE.Live keeps a hidden scene registry of its own and
  can fight external changes. Golden rules: treat the first scene as sacrificial,
  always duplicate using brand-new names, avoid renaming scenes OBS has already seen.

  Command-line usage (optional, no windows):
    powershell -ExecutionPolicy Bypass -File .\SELive-Vertical-Scene-Tool.ps1 -NoGui -Scene "FF8 - Vertical" -NewName "Apex - Vertical"
    powershell -ExecutionPolicy Bypass -File .\SELive-Vertical-Scene-Tool.ps1 -NoGui -Rename -Scene "Old Name" -NewName "New Name"

.NOTES
  Version 2.0 (surgical) - Unofficial community tool. Not affiliated with StreamElements
  or the OBS Project. File format reverse-engineered (SE.Live as of July 2026).
  A backup is always created before writing. Use at your own risk. License: MIT.
#>
param(
    [string]$File,
    [string]$Scene,
    [string]$NewName,
    [switch]$Rename,
    [switch]$NoGui,
    [switch]$NoRestart,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$script:GuiMode = -not $NoGui
$script:ObsExe  = $null
$script:Rng     = New-Object System.Random

if ($script:GuiMode) {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()
}

function Show-ErrorBox([string]$Msg) {
    if ($script:GuiMode) {
        [System.Windows.Forms.MessageBox]::Show($Msg, 'SE.Live Scene Tool',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    } else { Write-Host "ERROR: $Msg" -ForegroundColor Red }
}

function Show-InfoBox([string]$Msg) {
    if ($script:GuiMode) {
        [System.Windows.Forms.MessageBox]::Show($Msg, 'SE.Live Scene Tool',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
    } else { Write-Host $Msg -ForegroundColor Green }
}

# ------------------------------------------------------------------ #
#  1. If OBS is running: close it gracefully (or stop here)          #
# ------------------------------------------------------------------ #
$procs = @(Get-Process -Name obs64, obs32 -ErrorAction SilentlyContinue)
if ($procs.Count -gt 0) {
    $script:ObsExe = $procs[0].Path
    if (-not $script:GuiMode) {
        if (-not $Force) {
            Show-ErrorBox "OBS is running. Close it first, or use the GUI mode which closes it for you."
            exit 1
        }
    } else {
        $risposta = [System.Windows.Forms.MessageBox]::Show(
            "OBS is running and needs to be closed, because SE.Live only saves its scenes on shutdown.`n`nClose OBS gracefully now and reopen it when done?`n`n(If OBS shows a confirmation dialog on screen, answer it there.)",
            'SE.Live Scene Tool',
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question)
        if ($risposta -ne [System.Windows.Forms.DialogResult]::Yes) { exit 0 }
    }
    foreach ($p in $procs) {
        if (-not $p.CloseMainWindow()) {
            Show-ErrorBox "Could not close OBS automatically (it may be minimized to the tray). Close it manually and run the tool again."
            exit 1
        }
    }
    $limite = (Get-Date).AddSeconds(45)
    while ((Get-Process -Name obs64, obs32 -ErrorAction SilentlyContinue) -and (Get-Date) -lt $limite) {
        Start-Sleep -Milliseconds 500
    }
    if (Get-Process -Name obs64, obs32 -ErrorAction SilentlyContinue) {
        Show-ErrorBox "OBS did not close within 45 seconds (check for an open confirmation dialog). Close it manually and run the tool again."
        exit 1
    }
    Start-Sleep -Seconds 2   # give SE.Live a moment to finish writing
}

# ------------------------------------------------------------------ #
#  2. Raw read/write and composition file discovery                  #
# ------------------------------------------------------------------ #
function Read-Composition([string]$Path) {
    $bytes  = [System.IO.File]::ReadAllBytes($Path)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $offset = 0; if ($hasBom) { $offset = 3 }
    $text   = [System.Text.Encoding]::UTF8.GetString($bytes, $offset, $bytes.Length - $offset)
    return [pscustomobject]@{ Text = $text; HasBom = $hasBom }
}

function Write-Composition([string]$Path, [string]$Text, [bool]$HasBom) {
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($HasBom)))
}

if ($File) {
    if (-not (Test-Path -LiteralPath $File)) { Show-ErrorBox "File not found: $File"; exit 1 }
    $percorsi = @(Get-Item -LiteralPath $File)
} else {
    $dir = $env:APPDATA
    foreach ($seg in @('obs-studio','plugin_config','obs-streamelements-core','scoped_config_storage','streamelements_multi-streaming','compositions')) {
        $dir = Join-Path $dir $seg
    }
    $percorsi = @(Get-ChildItem -LiteralPath $dir -Filter '*.json' -File -ErrorAction SilentlyContinue)
    if ($percorsi.Count -eq 0) {
        Show-ErrorBox "No composition files found in:`n$dir`n`nIs SE.Live installed, and have you created at least one canvas?"
        exit 1
    }
}

$canvasList = @()
foreach ($f in $percorsi) {
    try {
        $comp = Read-Composition $f.FullName
        $dati = ConvertFrom-Json -InputObject $comp.Text
        if ($dati.scenes) {
            $nome = if ($dati.name) { [string]$dati.name } else { $f.BaseName }
            $canvasList += [pscustomobject]@{ Name = $nome; Path = $f.FullName; Dati = $dati; Testo = $comp.Text; HasBom = $comp.HasBom }
        }
    } catch { }
}
if ($canvasList.Count -eq 0) {
    Show-ErrorBox "Found some files, but none contain scenes in a recognizable format. If SE.Live changed its file format, this tool may need an update."
    exit 1
}

# ------------------------------------------------------------------ #
#  3. Surgical engine (textual splice, zero global rewrite)          #
# ------------------------------------------------------------------ #
function ConvertTo-JsonEscaped([string]$s) {
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $s.ToCharArray()) {
        if     ($ch -eq '"')  { [void]$sb.Append('\"') }
        elseif ($ch -eq '\')  { [void]$sb.Append('\\') }
        elseif ($ch -eq "`n") { [void]$sb.Append('\n') }
        elseif ($ch -eq "`r") { [void]$sb.Append('\r') }
        elseif ($ch -eq "`t") { [void]$sb.Append('\t') }
        elseif ([int]$ch -lt 32) { [void]$sb.Append(('\u{0:x4}' -f [int]$ch)) }
        else { [void]$sb.Append($ch) }
    }
    return $sb.ToString()
}

function Get-SceneSpans([string]$Text) {
    $n = $Text.Length
    $depth = 0; $inStr = $false; $esc = $false; $strStart = -1
    $arrStart = -1; $arrEnd = -1; $arrDepth = -1
    $curStart = -1
    $spans = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt $n; $i++) {
        $c = $Text[$i]
        if ($inStr) {
            if ($esc) { $esc = $false }
            elseif ($c -eq '\') { $esc = $true }
            elseif ($c -eq '"') {
                $inStr = $false
                if ($arrStart -lt 0 -and $depth -eq 1) {
                    $tok = $Text.Substring($strStart + 1, $i - $strStart - 1)
                    if ($tok -eq 'scenes') {
                        $j = $i + 1
                        while ($j -lt $n -and [char]::IsWhiteSpace($Text[$j])) { $j++ }
                        if ($j -lt $n -and $Text[$j] -eq ':') {
                            $j++
                            while ($j -lt $n -and [char]::IsWhiteSpace($Text[$j])) { $j++ }
                            if ($j -lt $n -and $Text[$j] -eq '[') { $arrStart = $j; $arrDepth = $depth }
                        }
                    }
                }
            }
            continue
        }
        if ($c -eq '"') { $inStr = $true; $esc = $false; $strStart = $i; continue }
        if ($c -eq '{') {
            $depth++
            if ($arrStart -ge 0 -and $arrEnd -lt 0 -and $curStart -lt 0 -and $depth -eq ($arrDepth + 2) -and $i -gt $arrStart) { $curStart = $i }
            continue
        }
        if ($c -eq '}') {
            $depth--
            if ($curStart -ge 0 -and $depth -eq ($arrDepth + 1)) {
                [void]$spans.Add([pscustomobject]@{ Start = $curStart; End = $i })
                $curStart = -1
            }
            continue
        }
        if ($c -eq '[') { $depth++; continue }
        if ($c -eq ']') {
            $depth--
            if ($arrStart -ge 0 -and $arrEnd -lt 0 -and $depth -eq $arrDepth) { $arrEnd = $i }
            continue
        }
    }
    if ($arrStart -lt 0 -or $arrEnd -lt 0) { throw "Unexpected structure: 'scenes' array not found in the file." }
    return [pscustomobject]@{ ArrayStart = $arrStart; ArrayEnd = $arrEnd; Spans = @($spans) }
}

function Get-KeyValueSpans([string]$SceneText) {
    $n = $SceneText.Length
    $result = @{}
    $i = 1
    $depth = 1
    while ($i -lt $n -and $depth -ge 1) {
        $c = $SceneText[$i]
        if ([char]::IsWhiteSpace($c) -or $c -eq ',') { $i++; continue }
        if ($c -eq '}') { $depth--; $i++; continue }
        if ($depth -eq 1 -and $c -eq '"') {
            $ks = $i; $i++
            while ($i -lt $n) {
                if ($SceneText[$i] -eq '\') { $i += 2; continue }
                if ($SceneText[$i] -eq '"') { break }
                $i++
            }
            $key = $SceneText.Substring($ks + 1, $i - $ks - 1)
            $i++
            while ($i -lt $n -and [char]::IsWhiteSpace($SceneText[$i])) { $i++ }
            if ($i -ge $n -or $SceneText[$i] -ne ':') { throw "Unexpected scene structure (missing ':' after key '$key')." }
            $i++
            while ($i -lt $n -and [char]::IsWhiteSpace($SceneText[$i])) { $i++ }
            $vs = $i
            $vc = $SceneText[$i]
            if ($vc -eq '"') {
                $i++
                while ($i -lt $n) {
                    if ($SceneText[$i] -eq '\') { $i += 2; continue }
                    if ($SceneText[$i] -eq '"') { break }
                    $i++
                }
                $ve = $i; $i++
            } elseif ($vc -eq '{' -or $vc -eq '[') {
                $d2 = 0; $s2 = $false; $e2 = $false
                while ($i -lt $n) {
                    $cc = $SceneText[$i]
                    if ($s2) {
                        if ($e2) { $e2 = $false }
                        elseif ($cc -eq '\') { $e2 = $true }
                        elseif ($cc -eq '"') { $s2 = $false }
                    } elseif ($cc -eq '"') { $s2 = $true }
                    elseif ($cc -eq '{' -or $cc -eq '[') { $d2++ }
                    elseif ($cc -eq '}' -or $cc -eq ']') { $d2--; if ($d2 -eq 0) { break } }
                    $i++
                }
                $ve = $i; $i++
            } else {
                while ($i -lt $n -and $SceneText[$i] -ne ',' -and $SceneText[$i] -ne '}') { $i++ }
                $ve = $i - 1
                while ($ve -gt $vs -and [char]::IsWhiteSpace($SceneText[$ve])) { $ve-- }
            }
            if (-not $result.ContainsKey($key)) {
                $result[$key] = [pscustomobject]@{ Start = $vs; End = $ve }
            }
            continue
        }
        $i++
    }
    foreach ($k in @('name','active','id')) {
        if (-not $result.ContainsKey($k)) { throw "Unexpected scene structure (key '$k' not found)." }
    }
    return $result
}

function Update-Span([string]$Text, $Span, [string]$New) {
    return $Text.Remove($Span.Start, $Span.End - $Span.Start + 1).Insert($Span.Start, $New)
}

function Find-SceneIndex($Parsed, [string]$SceneName) {
    $idx = -1
    for ($k = 0; $k -lt @($Parsed.scenes).Count; $k++) {
        if ($Parsed.scenes[$k].name -eq $SceneName) {
            if ($idx -ge 0) { throw "More than one scene is named '$SceneName'." }
            $idx = $k
        }
    }
    if ($idx -lt 0) { throw ("Scene '{0}' not found. Available scenes: {1}" -f $SceneName, ((@($Parsed.scenes) | ForEach-Object { $_.name }) -join ', ')) }
    return $idx
}

function New-BackupFile($Canvas) {
    $stamp  = Get-Date -Format 'yyyyMMdd_HHmmssfff'
    $backup = "$($Canvas.Path).bak_$stamp"
    Copy-Item -LiteralPath $Canvas.Path -Destination $backup
    return $backup
}

function Find-NameReferences($Canvas, [string]$Name) {
    $hits = @()
    try {
        $root = Split-Path -Path (Split-Path -Path (Split-Path -Path $Canvas.Path -Parent) -Parent) -Parent
        if (Test-Path -LiteralPath $root) {
            $altri = Get-ChildItem -LiteralPath $root -Recurse -File -Filter '*.json' -ErrorAction SilentlyContinue |
                     Where-Object { $_.FullName -ne $Canvas.Path }
            foreach ($f in $altri) {
                if (Select-String -LiteralPath $f.FullName -SimpleMatch -Pattern $Name -Quiet -ErrorAction SilentlyContinue) {
                    $hits += $f.FullName
                }
            }
        }
    } catch { }
    return ,$hits
}

function Invoke-SceneDuplicate($Canvas, [string]$SceneName, [string]$TargetName) {
    $parsed = $Canvas.Dati
    $idx = Find-SceneIndex $parsed $SceneName
    if ([string]::IsNullOrWhiteSpace($TargetName)) { throw "The name of the copy is empty." }
    if (@(@($parsed.scenes) | Where-Object { $_.name -eq $TargetName }).Count -gt 0) { throw "A scene named '$TargetName' already exists." }

    $layout = Get-SceneSpans $Canvas.Testo
    if (@($layout.Spans).Count -ne @($parsed.scenes).Count) { throw "Internal inconsistency while reading the file: operation aborted, file untouched." }
    $span = $layout.Spans[$idx]
    $sceneText = $Canvas.Testo.Substring($span.Start, $span.End - $span.Start + 1)

    $kv = Get-KeyValueSpans $sceneText
    $edits = @(
        [pscustomobject]@{ Span = $kv['name'];   New = '"' + (ConvertTo-JsonEscaped $TargetName) + '"' },
        [pscustomobject]@{ Span = $kv['active']; New = 'false' }
    ) | Sort-Object { $_.Span.Start } -Descending
    foreach ($e in $edits) { $sceneText = Update-Span $sceneText $e.Span $e.New }

    $used = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($m in [regex]::Matches($Canvas.Testo, 'ptr\([0-9A-Fa-f]{16}\)')) { [void]$used.Add($m.Value) }
    $newPtr = {
        while ($true) {
            $sfx = ''
            for ($q = 0; $q -lt 8; $q++) { $sfx += '{0:X}' -f $script:Rng.Next(0, 16) }
            $cand = "ptr(0000018E$sfx)"
            if (-not $used.Contains($cand)) { [void]$used.Add($cand); return $cand }
        }
    }
    $sceneText = $sceneText.Replace([string]$parsed.scenes[$idx].id, (& $newPtr))
    foreach ($src in @($parsed.scenes[$idx].sources)) {
        $sceneText = $sceneText.Replace([string]$src.id, (& $newPtr))
    }

    $newText = $Canvas.Testo.Insert($layout.ArrayEnd, ',' + $sceneText)

    $check = ConvertFrom-Json -InputObject $newText
    if (@($check.scenes).Count -ne (@($parsed.scenes).Count + 1)) { throw "Validation failed: operation aborted, file untouched." }

    $backup = New-BackupFile $Canvas
    Write-Composition $Canvas.Path $newText $Canvas.HasBom
    return [pscustomobject]@{ Backup = $backup; Warnings = @() }
}

function Invoke-SceneRename($Canvas, [string]$SceneName, [string]$TargetName) {
    $parsed = $Canvas.Dati
    $idx = Find-SceneIndex $parsed $SceneName
    if ([string]::IsNullOrWhiteSpace($TargetName)) { throw "The new name is empty." }
    if ($TargetName -ceq $SceneName) { throw "The new name is identical to the current one." }
    if (@(@($parsed.scenes) | Where-Object { $_.name -eq $TargetName -and $_.name -cne $SceneName }).Count -gt 0) { throw "Another scene named '$TargetName' already exists." }

    $layout = Get-SceneSpans $Canvas.Testo
    if (@($layout.Spans).Count -ne @($parsed.scenes).Count) { throw "Internal inconsistency while reading the file: operation aborted, file untouched." }
    $span = $layout.Spans[$idx]
    $sceneText = $Canvas.Testo.Substring($span.Start, $span.End - $span.Start + 1)
    $kv = Get-KeyValueSpans $sceneText
    $absStart = $span.Start + $kv['name'].Start
    $absLen   = $kv['name'].End - $kv['name'].Start + 1
    $newText  = $Canvas.Testo.Remove($absStart, $absLen).Insert($absStart, '"' + (ConvertTo-JsonEscaped $TargetName) + '"')

    $check = ConvertFrom-Json -InputObject $newText
    if (@($check.scenes).Count -ne @($parsed.scenes).Count) { throw "Validation failed: operation aborted, file untouched." }

    $backup = New-BackupFile $Canvas
    Write-Composition $Canvas.Path $newText $Canvas.HasBom
    return [pscustomobject]@{ Backup = $backup; Warnings = (Find-NameReferences $Canvas $SceneName) }
}

function Start-Obs {
    $exe = $script:ObsExe
    if (-not $exe -or -not (Test-Path -LiteralPath $exe)) {
        foreach ($cand in @("$env:ProgramFiles\obs-studio\bin\64bit\obs64.exe",
                            "${env:ProgramFiles(x86)}\obs-studio\bin\64bit\obs64.exe")) {
            if ($cand -and (Test-Path -LiteralPath $cand)) { $exe = $cand; break }
        }
    }
    if ($exe -and (Test-Path -LiteralPath $exe)) {
        Start-Process -FilePath $exe -WorkingDirectory (Split-Path -Path $exe -Parent)
        return $true
    }
    return $false
}

function Format-Warnings($Warnings) {
    if (-not $Warnings -or $Warnings.Count -eq 0) { return '' }
    $list = ($Warnings | ForEach-Object { Split-Path -Path $_ -Leaf }) -join "`n  - "
    return "`n`nNOTE: the old name also appears in other SE.Live files:`n  - $list`nIf this scene was linked (Link Scene), re-check the link in OBS."
}

# ------------------------------------------------------------------ #
#  4a. Command-line mode                                             #
# ------------------------------------------------------------------ #
if (-not $script:GuiMode) {
    if (-not $Scene -or -not $NewName) {
        Show-ErrorBox "In -NoGui mode you must pass -Scene and -NewName."
        exit 1
    }
    if ($canvasList.Count -gt 1 -and -not $File) {
        $list2 = ($canvasList | ForEach-Object { "$($_.Name) -> $($_.Path)" }) -join "`n"
        Show-ErrorBox "More than one canvas found, pick one with -File:`n$list2"
        exit 1
    }
    try {
        if ($Rename) { $res = Invoke-SceneRename    -Canvas $canvasList[0] -SceneName $Scene -TargetName $NewName }
        else         { $res = Invoke-SceneDuplicate -Canvas $canvasList[0] -SceneName $Scene -TargetName $NewName }
    } catch {
        Show-ErrorBox $_.Exception.Message
        exit 1
    }
    Write-Host ""
    if ($Rename) { Write-Host "Done! Scene '$Scene' renamed to '$NewName'." -ForegroundColor Green }
    else         { Write-Host "Done! Scene '$Scene' duplicated as '$NewName'." -ForegroundColor Green }
    Write-Host "Backup: $($res.Backup)"
    $warn = Format-Warnings $res.Warnings
    if ($warn) { Write-Host $warn -ForegroundColor Yellow }
    if (-not $NoRestart -and $script:ObsExe) { [void](Start-Obs) }
    exit 0
}

# ------------------------------------------------------------------ #
#  4b. GUI mode                                                      #
# ------------------------------------------------------------------ #
$form                 = New-Object System.Windows.Forms.Form
$form.Text            = 'SE.Live Scene Tool - Duplicate / Rename (v2 surgical)'
$form.Size            = New-Object System.Drawing.Size(460, 345)
$form.StartPosition   = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox     = $false
$form.MinimizeBox     = $false

$y = 15

$rdoDuplicate          = New-Object System.Windows.Forms.RadioButton
$rdoDuplicate.Text     = 'Duplicate'
$rdoDuplicate.Checked  = $true
$rdoDuplicate.Location = New-Object System.Drawing.Point(15, $y)
$rdoDuplicate.Size     = New-Object System.Drawing.Size(110, 22)
$form.Controls.Add($rdoDuplicate)

$rdoRename          = New-Object System.Windows.Forms.RadioButton
$rdoRename.Text     = 'Rename'
$rdoRename.Location = New-Object System.Drawing.Point(140, $y)
$rdoRename.Size     = New-Object System.Drawing.Size(120, 22)
$form.Controls.Add($rdoRename)
$y += 30

$lblCanvas          = New-Object System.Windows.Forms.Label
$lblCanvas.Text     = 'Canvas:'
$lblCanvas.Location = New-Object System.Drawing.Point(15, $y)
$lblCanvas.Size     = New-Object System.Drawing.Size(415, 18)
$form.Controls.Add($lblCanvas)
$y += 20

$cmbCanvas               = New-Object System.Windows.Forms.ComboBox
$cmbCanvas.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$cmbCanvas.Location      = New-Object System.Drawing.Point(15, $y)
$cmbCanvas.Size          = New-Object System.Drawing.Size(415, 24)
foreach ($c in $canvasList) { [void]$cmbCanvas.Items.Add($c.Name) }
$cmbCanvas.SelectedIndex = 0
$form.Controls.Add($cmbCanvas)
$y += 34

$lblScene          = New-Object System.Windows.Forms.Label
$lblScene.Text     = 'Scene:'
$lblScene.Location = New-Object System.Drawing.Point(15, $y)
$lblScene.Size     = New-Object System.Drawing.Size(415, 18)
$form.Controls.Add($lblScene)
$y += 20

$cmbScene               = New-Object System.Windows.Forms.ComboBox
$cmbScene.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$cmbScene.Location      = New-Object System.Drawing.Point(15, $y)
$cmbScene.Size          = New-Object System.Drawing.Size(415, 24)
$form.Controls.Add($cmbScene)
$y += 34

$lblName          = New-Object System.Windows.Forms.Label
$lblName.Text     = 'Name of the copy:'
$lblName.Location = New-Object System.Drawing.Point(15, $y)
$lblName.Size     = New-Object System.Drawing.Size(415, 18)
$form.Controls.Add($lblName)
$y += 20

$txtName          = New-Object System.Windows.Forms.TextBox
$txtName.Location = New-Object System.Drawing.Point(15, $y)
$txtName.Size     = New-Object System.Drawing.Size(415, 24)
$form.Controls.Add($txtName)
$y += 34

$chkRestart          = New-Object System.Windows.Forms.CheckBox
$chkRestart.Text     = 'Reopen OBS when done'
$chkRestart.Checked  = $true
$chkRestart.Location = New-Object System.Drawing.Point(15, $y)
$chkRestart.Size     = New-Object System.Drawing.Size(415, 22)
$form.Controls.Add($chkRestart)
$y += 32

$btnOk          = New-Object System.Windows.Forms.Button
$btnOk.Text     = 'Duplicate'
$btnOk.Location = New-Object System.Drawing.Point(240, $y)
$btnOk.Size     = New-Object System.Drawing.Size(90, 28)
$form.Controls.Add($btnOk)

$btnCancel          = New-Object System.Windows.Forms.Button
$btnCancel.Text     = 'Cancel'
$btnCancel.Location = New-Object System.Drawing.Point(340, $y)
$btnCancel.Size     = New-Object System.Drawing.Size(90, 28)
$btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
$form.Controls.Add($btnCancel)

$form.AcceptButton = $btnOk
$form.CancelButton = $btnCancel

$script:LastDefault = ''
$UpdateName = {
    if ($cmbScene.SelectedItem) {
        if ($rdoRename.Checked) { $default = [string]$cmbScene.SelectedItem }
        else                      { $default = "$($cmbScene.SelectedItem) - Copy" }
        if ($txtName.Text -eq $script:LastDefault -or [string]::IsNullOrWhiteSpace($txtName.Text)) {
            $txtName.Text = $default
        }
        $script:LastDefault = $default
    }
}
$UpdateScenes = {
    $cmbScene.Items.Clear()
    $canvas = $canvasList[$cmbCanvas.SelectedIndex]
    foreach ($s in $canvas.Dati.scenes) { [void]$cmbScene.Items.Add([string]$s.name) }
    if ($cmbScene.Items.Count -gt 0) { $cmbScene.SelectedIndex = 0 }
}
$UpdateMode = {
    if ($rdoRename.Checked) { $lblName.Text = 'New name:';         $btnOk.Text = 'Rename'    }
    else                      { $lblName.Text = 'Name of the copy:'; $btnOk.Text = 'Duplicate' }
    & $UpdateName
}
$cmbCanvas.Add_SelectedIndexChanged($UpdateScenes)
$cmbScene.Add_SelectedIndexChanged($UpdateName)
$rdoDuplicate.Add_CheckedChanged($UpdateMode)
& $UpdateScenes
& $UpdateName

$btnOk.Add_Click({
    try {
        $canvas   = $canvasList[$cmbCanvas.SelectedIndex]
        $selected = [string]$cmbScene.SelectedItem
        $target   = $txtName.Text.Trim()
        if ($rdoRename.Checked) {
            $res = Invoke-SceneRename -Canvas $canvas -SceneName $selected -TargetName $target
            $msg = "Done! Scene '$selected' renamed to '$target'.`n`nBackup of the original:`n$($res.Backup)"
        } else {
            $res = Invoke-SceneDuplicate -Canvas $canvas -SceneName $selected -TargetName $target
            $msg = "Done! Scene duplicated as '$target'.`n`nBackup of the original:`n$($res.Backup)"
        }
        $msg += Format-Warnings $res.Warnings
        if ($chkRestart.Checked) {
            if (Start-Obs) { $msg += "`n`nReopening OBS: check the vertical canvas dock." }
            else           { $msg += "`n`nCould not find the OBS executable: please reopen it manually." }
        }
        Show-InfoBox $msg
        $form.Close()
    } catch {
        Show-ErrorBox $_.Exception.Message
    }
})

[void]$form.ShowDialog()
