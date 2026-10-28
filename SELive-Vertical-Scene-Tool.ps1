<#
.SYNOPSIS
  SE.Live Vertical Canvas Scene Tool - duplicate, rename, delete and restore scenes on SE.Live
  multistreaming canvases. v3 "surgical": it never rewrites the whole file, it only
  splices in (or touches) the bytes of the scene involved. Every other byte stays identical.

.DESCRIPTION
  Double-click "SELive Scene Tool.bat" (same folder) and the tool:
    1. gracefully closes OBS if it is running (so SE.Live saves fresh state)
    2. auto-detects your SE.Live "composition" files (or lets you browse to one)
    3. lets you pick the operation (Duplicate / Rename / Delete / Restore backup), canvas, scene and new name(s)
    4. runs with an automatic backup and deep validation (if anything looks wrong, the file is NOT touched)
    5. restarts OBS

  IMPORTANT - read the README: SE.Live keeps scene state of its own and can fight
  external changes. Golden rules: treat the first scene as sacrificial, always
  duplicate using brand-new names, avoid renaming scenes OBS has already seen.

  Command-line usage (optional, no windows):
    powershell -ExecutionPolicy Bypass -File .\SELive-Vertical-Scene-Tool.ps1 -List
    powershell -ExecutionPolicy Bypass -File .\SELive-Vertical-Scene-Tool.ps1 -NoGui -Scene "Valorant" -NewName "Apex"
    powershell -ExecutionPolicy Bypass -File .\SELive-Vertical-Scene-Tool.ps1 -NoGui -Scene "Valorant" -NewName "Apex|Fortnite|Variety"
    powershell -ExecutionPolicy Bypass -File .\SELive-Vertical-Scene-Tool.ps1 -NoGui -Rename -Scene "Old Name" -NewName "New Name"
    powershell -ExecutionPolicy Bypass -File .\SELive-Vertical-Scene-Tool.ps1 -NoGui -Delete -Scene "Old test"
    powershell -ExecutionPolicy Bypass -File .\SELive-Vertical-Scene-Tool.ps1 -NoGui -RestoreFrom "<file>.json.bak_20261028_111506188"

.NOTES
  Version 3.0 (surgical) - built and tested for SE.Live 26.9.4.994 (obs-streamelements-core)
  on OBS Studio 33.0.0, October 2026. Other SE.Live versions are flagged in the window, and the
  tool stops if the composition file format is not the one it knows.
  Unofficial community tool. Not affiliated with StreamElements or the OBS Project.
  A backup is always created before writing. Use at your own risk. License: MIT.
#>
param(
    [string]$File,
    [string]$Canvas,
    [string]$Scene,
    [string[]]$NewName,
    [switch]$Rename,
    [switch]$Delete,
    [switch]$AtEnd,
    [string]$RestoreFrom,
    [switch]$List,
    [switch]$NoGui,
    [switch]$NoRestart,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$script:ToolVersion  = '3.0'
$script:TestedSELive = '26.9.4.994'
$script:TestedObs    = '33.0.0'
$script:PtrPattern   = 'ptr\([0-9A-Fa-f]{16}\)'
$script:GuiMode      = -not ($NoGui -or $List)
$script:ObsExe       = $null
$script:Rng          = New-Object System.Random

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

function Confirm-Box([string]$Msg) {
    $r = [System.Windows.Forms.MessageBox]::Show($Msg, 'SE.Live Scene Tool',
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question)
    return ($r -eq [System.Windows.Forms.DialogResult]::Yes)
}

# ------------------------------------------------------------------ #
#  1. OBS process handling                                           #
# ------------------------------------------------------------------ #
function Get-ObsProcess { return @(Get-Process -Name obs64, obs32 -ErrorAction SilentlyContinue) }

function Wait-ObsExit([int]$Seconds) {
    $limite = (Get-Date).AddSeconds($Seconds)
    while ((Get-ObsProcess).Count -gt 0 -and (Get-Date) -lt $limite) {
        Start-Sleep -Milliseconds 500
    }
    return ((Get-ObsProcess).Count -eq 0)
}

function Close-Obs {
    $procs = Get-ObsProcess
    if ($procs[0].Path) { $script:ObsExe = $procs[0].Path }
    # An OBS started "as administrator" hides its path from us, and Windows blocks a normal
    # process from closing an elevated one: in that case only the user can close it.
    $elevated = @($procs | Where-Object { -not $_.Path }).Count -gt 0
    if (-not $elevated) {
        foreach ($p in $procs) {
            if (-not $p.CloseMainWindow()) {
                # Main window hidden (minimized to tray): a plain taskkill still asks it to close gracefully.
                & taskkill.exe /PID $p.Id 2>&1 | Out-Null
            }
        }
        if (Wait-ObsExit 45) { return }
    }
    if ($elevated) { $why = "OBS is running as administrator, so Windows does not let this tool close it." }
    else           { $why = "OBS did not close within 45 seconds (maybe a confirmation dialog is open)." }
    if (-not $script:GuiMode) { throw "$why Close OBS yourself (File > Exit) and run the tool again." }
    while ($true) {
        $r = [System.Windows.Forms.MessageBox]::Show(
            "$why`n`nClose OBS yourself (File > Exit), then press OK.",
            'SE.Live Scene Tool',
            [System.Windows.Forms.MessageBoxButtons]::OKCancel,
            [System.Windows.Forms.MessageBoxIcon]::Information)
        if ($r -ne [System.Windows.Forms.DialogResult]::OK) { exit 0 }
        if (Wait-ObsExit 15) { return }
    }
}

function Wait-FilesSettled([string]$Dir) {
    # SE.Live writes its compositions while OBS shuts down: wait until nothing in the folder changes anymore.
    Start-Sleep -Seconds 1
    $prev = $null
    for ($k = 0; $k -lt 20; $k++) {
        $sig = (Get-ChildItem -LiteralPath $Dir -Filter '*.json' -File -ErrorAction SilentlyContinue |
                ForEach-Object { "$($_.Name)|$($_.Length)|$($_.LastWriteTimeUtc.Ticks)" }) -join ';'
        if ($sig -eq $prev) { return }
        $prev = $sig
        Start-Sleep -Milliseconds 750
    }
}

function Get-ObsExePath {
    if ($script:ObsExe -and (Test-Path -LiteralPath $script:ObsExe)) { return $script:ObsExe }
    $cands = @()
    foreach ($key in @('HKLM:\SOFTWARE\OBS Studio', 'HKLM:\SOFTWARE\WOW6432Node\OBS Studio')) {
        $reg = Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue
        if ($reg -and $reg.'(default)') { $cands += (Join-Path $reg.'(default)' 'bin\64bit\obs64.exe') }
    }
    $cands += "$env:ProgramFiles\obs-studio\bin\64bit\obs64.exe"
    $cands += "${env:ProgramFiles(x86)}\obs-studio\bin\64bit\obs64.exe"
    foreach ($c in $cands) { if ($c -and (Test-Path -LiteralPath $c)) { return $c } }
    return $null
}

function Start-Obs {
    $exe = Get-ObsExePath
    if ($exe) {
        Start-Process -FilePath $exe -WorkingDirectory (Split-Path -Path $exe -Parent)
        return $true
    }
    return $false
}

# ------------------------------------------------------------------ #
#  2. Raw read/write and composition file discovery                  #
# ------------------------------------------------------------------ #
function Get-CompositionDir {
    $dir = $env:APPDATA
    foreach ($seg in @('obs-studio','plugin_config','obs-streamelements-core','scoped_config_storage','streamelements_multi-streaming','compositions')) {
        $dir = Join-Path $dir $seg
    }
    return $dir
}

function Get-SELiveVersion([string]$CompositionPath) {
    # compositions -> streamelements_multi-streaming -> scoped_config_storage -> obs-streamelements-core
    try {
        $root = Split-Path (Split-Path (Split-Path (Split-Path $CompositionPath -Parent) -Parent) -Parent) -Parent
        $ini  = Join-Path $root 'obs-streamelements-core.ini'
        $m = Select-String -LiteralPath $ini -Pattern '^Version=(\d{4})(\d{2})(\d{2})(\d{6})\s*$' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($m) {
            $g = $m.Matches[0].Groups
            return ('{0}.{1}.{2}.{3}' -f ([int]$g[1].Value % 100), [int]$g[2].Value, [int]$g[3].Value, [int]$g[4].Value)
        }
    } catch { }
    return $null
}

function Read-Composition([string]$Path) {
    $item   = Get-Item -LiteralPath $Path
    $bytes  = [System.IO.File]::ReadAllBytes($Path)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $offset = 0; if ($hasBom) { $offset = 3 }
    $text   = (New-Object System.Text.UTF8Encoding($false, $true)).GetString($bytes, $offset, $bytes.Length - $offset)
    return [pscustomobject]@{ Text = $text; HasBom = $hasBom; Stamp = $item.LastWriteTimeUtc; Length = $item.Length }
}

function Write-Composition([string]$Path, [string]$Text, [bool]$HasBom) {
    # Write next to the original, then swap it in: a crash mid-write can never leave a half-written composition.
    $tmp = "$Path.tmp_$PID"
    [System.IO.File]::WriteAllText($tmp, $Text, (New-Object System.Text.UTF8Encoding($HasBom)))
    [System.IO.File]::Replace($tmp, $Path, [NullString]::Value)
}

function Get-SceneList($Parsed) { return @(@($Parsed.scenes) | Where-Object { $null -ne $_ }) }

function Test-CompositionFormat($Parsed) {
    # Returns $null when the file looks like the format this tool was built for, otherwise the reason.
    if (-not $Parsed.PSObject.Properties['scenes']) { return "no 'scenes' list" }
    foreach ($s in (Get-SceneList $Parsed)) {
        if (-not ([string]$s.id -match "^$($script:PtrPattern)$")) { return "a scene id is not in the expected ptr(...) format" }
        if (-not ($s.name -is [string]))                         { return "a scene has no name" }
        if (-not $s.PSObject.Properties['active'])                { return "scene '$($s.name)' has no 'active' flag" }
        foreach ($src in @(@($s.sources) | Where-Object { $null -ne $_ })) {
            if (-not ([string]$src.id -match "^$($script:PtrPattern)$")) { return "source '$($src.name)' in scene '$($s.name)' has an unexpected id" }
        }
    }
    return $null
}

function Get-Canvases([object[]]$Files) {
    $list = @()
    foreach ($f in $Files) {
        try {
            $comp = Read-Composition $f.FullName
            $dati = ConvertFrom-Json -InputObject $comp.Text
            if ($dati.PSObject.Properties['scenes']) {
                $nome = if ($dati.name) { [string]$dati.name } else { $f.BaseName }
                $list += [pscustomobject]@{
                    Name = $nome; Path = $f.FullName; Dati = $dati; Testo = $comp.Text; HasBom = $comp.HasBom
                    Stamp = $comp.Stamp; Length = $comp.Length; FormatIssue = (Test-CompositionFormat $dati)
                }
            }
        } catch { }
    }
    return ,$list
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
    $scenes = Get-SceneList $Parsed
    $idx = -1
    for ($k = 0; $k -lt $scenes.Count; $k++) {
        if ($scenes[$k].name -ceq $SceneName) {
            if ($idx -ge 0) { throw "More than one scene is named '$SceneName'." }
            $idx = $k
        }
    }
    if ($idx -lt 0) { throw ("Scene '{0}' not found. Available scenes: {1}" -f $SceneName, (($scenes | ForEach-Object { $_.name }) -join ', ')) }
    return $idx
}

function Assert-ValidNewName($Parsed, [string]$TargetName, [string]$Except) {
    if ([string]::IsNullOrWhiteSpace($TargetName)) { throw "The new scene name is empty." }
    if ($TargetName -ne $TargetName.Trim()) { throw "The name '$TargetName' starts or ends with spaces." }
    if ($TargetName -match '[\x00-\x1F]') { throw "The name '$TargetName' contains control characters." }
    $clash = @(Get-SceneList $Parsed | Where-Object { $_.name -eq $TargetName -and $_.name -cne $Except })
    if ($clash.Count -gt 0) { throw "A scene named '$($clash[0].name)' already exists on this canvas (names are compared ignoring case)." }
}

# The identities a scene owns: the scene itself and its entries (one per source in the scene).
# Filters are deliberately left out: they belong to the underlying source, which scenes share,
# so SE.Live itself writes the same filter id in every scene that uses that source.
function Get-OwnedIds($Scene) {
    $ids = New-Object System.Collections.ArrayList
    [void]$ids.Add([string]$Scene.id)
    foreach ($src in @(@($Scene.sources) | Where-Object { $null -ne $_ })) { [void]$ids.Add([string]$src.id) }
    return ,$ids
}

# Problems are keyed by ids (not names), so a problem SE.Live itself left in the file is not
# mistaken for a new one after a rename.
function Get-IntegrityProblems($Parsed) {
    $problems = New-Object System.Collections.Generic.List[string]
    $owner = @{}
    foreach ($s in (Get-SceneList $Parsed)) {
        foreach ($id in (Get-OwnedIds $s)) {
            if ($owner.ContainsKey($id)) { $problems.Add("id $id is used twice") }
            else { $owner[$id] = $true }
        }
        foreach ($src in @(@($s.sources) | Where-Object { $null -ne $_ })) {
            if ($src.PSObject.Properties['sceneId'] -and $src.sceneId -ne $s.id) {
                $problems.Add("entry $($src.id) points to another scene")
            }
            if ($Parsed.id -and $src.PSObject.Properties['videoCompositionId'] -and $src.videoCompositionId -ne $Parsed.id) {
                $problems.Add("entry $($src.id) belongs to another canvas")
            }
        }
        if ($Parsed.id -and $s.PSObject.Properties['videoCompositionId'] -and $s.videoCompositionId -ne $Parsed.id) {
            $problems.Add("scene $($s.id) belongs to another canvas")
        }
    }
    $names = @{}
    foreach ($s in (Get-SceneList $Parsed)) {
        $k = ([string]$s.name).ToLowerInvariant()
        if ($names.ContainsKey($k)) { $problems.Add("scene name '$($s.name)' is used twice") } else { $names[$k] = $true }
    }
    return ,$problems
}

function Assert-NoNewProblems($Before, $AfterParsed) {
    $new = @(foreach ($p in (Get-IntegrityProblems $AfterParsed)) { if ($Before -notcontains $p) { $p } })
    if ($new.Count -gt 0) { throw ("Validation failed, operation aborted, file untouched:`n  - " + ($new -join "`n  - ")) }
}

function Get-PtrPrefix([string]$Id) {
    if ($Id -match '^ptr\(([0-9A-Fa-f]{8})[0-9A-Fa-f]{8}\)$') { return $Matches[1].ToUpperInvariant() }
    return '0000026E'
}

function New-UniquePtr($Used, [string]$Prefix) {
    while ($true) {
        # 16-byte aligned, like the real heap addresses SE.Live writes
        $low  = [long]$script:Rng.Next(0x100000, 0x10000000) * 16
        $cand = 'ptr({0}{1:X8})' -f $Prefix, $low
        if ($Used.Add($cand)) { return $cand }
    }
}

function ConvertTo-Canonical($Value) { return (ConvertTo-Json -InputObject $Value -Depth 64 -Compress) }

# Without -AfterScene the copy is appended at the end of the list, otherwise it goes right after that scene.
function Copy-SceneInText([string]$Text, [string]$SceneName, [string]$TargetName, [string]$AfterScene) {
    $parsed = ConvertFrom-Json -InputObject $Text
    $scenes = Get-SceneList $parsed
    $idx    = Find-SceneIndex $parsed $SceneName
    Assert-ValidNewName $parsed $TargetName $null
    $before = Get-IntegrityProblems $parsed

    $layout = Get-SceneSpans $Text
    if (@($layout.Spans).Count -ne $scenes.Count) { throw "Internal inconsistency while reading the file: operation aborted, file untouched." }
    if ($AfterScene) {
        $afterIdx = Find-SceneIndex $parsed $AfterScene
        $insertAt = $layout.Spans[$afterIdx].End + 1
        $copyIdx  = $afterIdx + 1
    } else {
        $insertAt = $layout.ArrayEnd
        $copyIdx  = $scenes.Count
    }
    $span = $layout.Spans[$idx]
    $sceneText = $Text.Substring($span.Start, $span.End - $span.Start + 1)

    $kv = Get-KeyValueSpans $sceneText
    $edits = @(
        [pscustomobject]@{ Span = $kv['name'];   New = '"' + (ConvertTo-JsonEscaped $TargetName) + '"' },
        [pscustomobject]@{ Span = $kv['active']; New = 'false' }
    ) | Sort-Object { $_.Span.Start } -Descending
    foreach ($e in $edits) { $sceneText = Update-Span $sceneText $e.Span $e.New }

    # Fresh identity for the scene and its entries; every occurrence is remapped, so the entries'
    # 'sceneId' back-references follow the new scene id automatically. Filter ids stay shared (see Get-OwnedIds).
    $used = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($m in [regex]::Matches($Text, $script:PtrPattern)) { [void]$used.Add($m.Value) }
    $owned = Get-OwnedIds $scenes[$idx]
    $prefix = Get-PtrPrefix ([string]$scenes[$idx].id)
    $map = @{}; $reverse = @{}
    foreach ($id in $owned) {
        if (-not $map.ContainsKey($id)) { $map[$id] = New-UniquePtr $used $prefix; $reverse[$map[$id]] = $id }
    }
    $sceneText = [regex]::Replace($sceneText, $script:PtrPattern, [System.Text.RegularExpressions.MatchEvaluator]{
        param($m) if ($map.ContainsKey($m.Value)) { $map[$m.Value] } else { $m.Value }
    })

    $newText = $Text.Insert($insertAt, ',' + $sceneText)

    # --- validation: nothing outside the splice moved, the copy is a faithful clone, ids are all unique ---
    if (-not ($newText.StartsWith($Text.Substring(0, $insertAt), [System.StringComparison]::Ordinal) -and
              $newText.EndsWith($Text.Substring($insertAt), [System.StringComparison]::Ordinal))) {
        throw "Validation failed (bytes outside the new scene changed): operation aborted, file untouched."
    }
    $check     = ConvertFrom-Json -InputObject $newText
    $newScenes = Get-SceneList $check
    if ($newScenes.Count -ne ($scenes.Count + 1)) { throw "Validation failed (scene count): operation aborted, file untouched." }
    $copy = $newScenes[$copyIdx]
    if ($copy.name -cne $TargetName -or $copy.active -ne $false) { throw "Validation failed (name/active of the copy): operation aborted, file untouched." }
    $copySources = [regex]::Replace((ConvertTo-Canonical @($copy.sources)), $script:PtrPattern, [System.Text.RegularExpressions.MatchEvaluator]{
        param($m) if ($reverse.ContainsKey($m.Value)) { $reverse[$m.Value] } else { $m.Value }
    })
    if ($copySources -cne (ConvertTo-Canonical @($scenes[$idx].sources))) {
        throw "Validation failed (the copy differs from the original): operation aborted, file untouched."
    }
    Assert-NoNewProblems $before $check
    return $newText
}

function Rename-SceneInText([string]$Text, [string]$SceneName, [string]$TargetName) {
    $parsed = ConvertFrom-Json -InputObject $Text
    $scenes = Get-SceneList $parsed
    $idx    = Find-SceneIndex $parsed $SceneName
    if ($TargetName -ceq $SceneName) { throw "The new name is identical to the current one." }
    Assert-ValidNewName $parsed $TargetName $SceneName
    $before = Get-IntegrityProblems $parsed

    $layout = Get-SceneSpans $Text
    if (@($layout.Spans).Count -ne $scenes.Count) { throw "Internal inconsistency while reading the file: operation aborted, file untouched." }
    $span = $layout.Spans[$idx]
    $kv = Get-KeyValueSpans ($Text.Substring($span.Start, $span.End - $span.Start + 1))
    $absStart = $span.Start + $kv['name'].Start
    $absLen   = $kv['name'].End - $kv['name'].Start + 1
    $newText  = $Text.Remove($absStart, $absLen).Insert($absStart, '"' + (ConvertTo-JsonEscaped $TargetName) + '"')

    $check     = ConvertFrom-Json -InputObject $newText
    $newScenes = Get-SceneList $check
    if ($newScenes.Count -ne $scenes.Count -or $newScenes[$idx].name -cne $TargetName -or $newScenes[$idx].id -ne $scenes[$idx].id) {
        throw "Validation failed: operation aborted, file untouched."
    }
    Assert-NoNewProblems $before $check
    return $newText
}

function Remove-SceneInText([string]$Text, [string]$SceneName) {
    $parsed = ConvertFrom-Json -InputObject $Text
    $scenes = Get-SceneList $parsed
    $idx    = Find-SceneIndex $parsed $SceneName
    if ($scenes.Count -le 1) { throw "'$SceneName' is the only scene of this canvas: it cannot be deleted." }
    if ($scenes[$idx].active) { throw "'$SceneName' is the active scene of the canvas. Switch the canvas to another scene in OBS first, then delete it." }
    $before = Get-IntegrityProblems $parsed

    $layout = Get-SceneSpans $Text
    if (@($layout.Spans).Count -ne $scenes.Count) { throw "Internal inconsistency while reading the file: operation aborted, file untouched." }
    # Cut the scene together with one separating comma: the one after it, or the one before it if it is the last.
    if ($idx -lt $scenes.Count - 1) { $from = $layout.Spans[$idx].Start;         $to = $layout.Spans[$idx + 1].Start - 1 }
    else                            { $from = $layout.Spans[$idx - 1].End + 1;   $to = $layout.Spans[$idx].End }
    $newText = $Text.Remove($from, $to - $from + 1)

    $check     = ConvertFrom-Json -InputObject $newText
    $expected  = @($scenes | Where-Object { $_.id -ne $scenes[$idx].id } | ForEach-Object { [string]$_.name })
    $remaining = @(Get-SceneList $check | ForEach-Object { [string]$_.name })
    if (($remaining -join "`n") -cne ($expected -join "`n")) { throw "Validation failed: operation aborted, file untouched." }
    Assert-NoNewProblems $before $check
    return $newText
}

# ------------------------------------------------------------------ #
#  4. Operations (backup + safe write)                               #
# ------------------------------------------------------------------ #
function New-BackupFile($Canvas) {
    $stamp  = Get-Date -Format 'yyyyMMdd_HHmmssfff'
    $backup = "$($Canvas.Path).bak_$stamp"
    Copy-Item -LiteralPath $Canvas.Path -Destination $backup
    return $backup
}

function Assert-SafeToWrite($Canvas) {
    if ((Get-ObsProcess).Count -gt 0) {
        throw "OBS is running again: SE.Live would overwrite the change when it closes. Close OBS and retry."
    }
    $now = Get-Item -LiteralPath $Canvas.Path
    if ($now.LastWriteTimeUtc -ne $Canvas.Stamp -or $now.Length -ne $Canvas.Length) {
        throw "The composition file changed after the tool read it (was OBS reopened?). Run the tool again so it works on the latest version."
    }
}

function Save-Composition($Canvas, [string]$NewText) {
    Assert-SafeToWrite $Canvas
    $backup = New-BackupFile $Canvas
    Write-Composition $Canvas.Path $NewText $Canvas.HasBom
    $back = Read-Composition $Canvas.Path
    if ($back.Text -cne $NewText) {
        Copy-Item -LiteralPath $backup -Destination $Canvas.Path -Force
        throw "Read-back check failed: the original file has been put back from the backup."
    }
    $Canvas.Testo = $back.Text; $Canvas.Dati = ConvertFrom-Json -InputObject $back.Text
    $Canvas.Stamp = $back.Stamp; $Canvas.Length = $back.Length
    return $backup
}

function Assert-CanvasUsable($Canvas) {
    if ($Canvas.FormatIssue) {
        throw "This canvas file is not in the format the tool knows ($($Canvas.FormatIssue)). SE.Live probably changed its file format: the tool needs an update. Nothing was changed."
    }
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

# SE.Live restores the FIRST scene of a canvas by renaming its placeholder scene, and its rename (unlike
# adding a scene) wants a name that no OBS scene/source and no SE.Live scene or scene entry uses yet;
# otherwise it silently appends " 1" (obs-streamelements-core: SEObsSceneManager::ObsSetUniqueSourceName).
# The same rule applies to every rename made from the SE.Live dock.
function Get-ObsRoot([string]$CompositionPath) {
    # compositions -> streamelements_multi-streaming -> scoped_config_storage -> obs-streamelements-core -> plugin_config -> obs-studio
    $p = $CompositionPath
    for ($k = 0; $k -lt 6; $k++) { $p = Split-Path -Path $p -Parent }
    return $p
}

function Get-TakenNames($Canvas) {
    if ($script:TakenCache.ContainsKey($Canvas.Path)) { return $script:TakenCache[$Canvas.Path] }
    $taken = @{}   # lower-case name -> where it is used
    try {
        $root = Get-ObsRoot $Canvas.Path
        $ini  = Join-Path $root 'user.ini'
        if (-not (Test-Path -LiteralPath $ini)) { $ini = Join-Path $root 'global.ini' }
        $m = Select-String -LiteralPath $ini -Pattern '^SceneCollectionFile=(.+)$' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($m) {
            $leaf = $m.Matches[0].Groups[1].Value.Trim()
            if ($leaf -notlike '*.json') { $leaf += '.json' }
            $coll = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText((Join-Path (Join-Path $root 'basic\scenes') $leaf)))
            foreach ($s in @(@($coll.sources) + @($coll.groups) | Where-Object { $null -ne $_ })) {
                $k = ([string]$s.name).ToLowerInvariant()
                if (-not $taken.ContainsKey($k)) { $taken[$k] = "the OBS scene/source '$($s.name)'" }
            }
        }
    } catch { }
    foreach ($c in $script:AllCanvases) {
        foreach ($s in (Get-SceneList $c.Dati)) {
            $k = ([string]$s.name).ToLowerInvariant()
            if ($c.Path -ne $Canvas.Path -and -not $taken.ContainsKey($k)) { $taken[$k] = "scene '$($s.name)' on canvas '$($c.Name)'" }
            foreach ($src in @(@($s.sources) | Where-Object { $null -ne $_ })) {
                $k = ([string]$src.name).ToLowerInvariant()
                if (-not $taken.ContainsKey($k)) { $taken[$k] = "source '$($src.name)' on canvas '$($c.Name)'" }
            }
        }
    }
    $script:TakenCache[$Canvas.Path] = $taken
    return $taken
}

# $null when $Name is safe as the first scene of $Canvas, otherwise where else it is used.
function Get-FirstSceneClash($Canvas, [string]$Name) {
    $taken = Get-TakenNames $Canvas
    $k = $Name.ToLowerInvariant()
    if ($taken.ContainsKey($k)) { return $taken[$k] }
    return $null
}

function Get-SafeFirstSceneName($Canvas, [string]$Name) {
    # The first scene itself is the one being renamed, so its current name does not count as taken.
    $own = @(Get-SceneList $Canvas.Dati | Select-Object -Skip 1 | ForEach-Object { ([string]$_.name).ToLowerInvariant() })
    $base = "$Name - Vertical"
    $cand = $base; $n = 1
    while ((Get-FirstSceneClash $Canvas $cand) -or ($own -contains $cand.ToLowerInvariant())) { $n++; $cand = "$base $n" }
    return $cand
}

function Get-FirstSceneWarning($Canvas, [string]$Name) {
    $where = Get-FirstSceneClash $Canvas $Name
    if (-not $where) { return '' }
    return "The first scene '$Name' has the same name as $where, so SE.Live shows it as '$Name 1'. Give it a name used nowhere else in OBS, e.g. '$(Get-SafeFirstSceneName $Canvas $Name)'."
}

function Split-Names([string[]]$Names) {
    return ,@($Names | ForEach-Object { $_ -split "\||`r?`n" } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Invoke-SceneDuplicate($Canvas, [string]$SceneName, [string[]]$TargetNames, [bool]$AfterOriginal = $true) {
    Assert-CanvasUsable $Canvas
    if ($TargetNames.Count -eq 0) { throw "Type at least one name for the copy." }
    $seen = @{}
    foreach ($t in $TargetNames) {
        if ($seen.ContainsKey($t.ToLowerInvariant())) { throw "The name '$t' is in the list twice." }
        $seen[$t.ToLowerInvariant()] = $true
    }
    $text = $Canvas.Testo
    # Each copy goes after the previous one, so a batch keeps the order it was typed in.
    $anchor = if ($AfterOriginal) { $SceneName } else { $null }
    foreach ($t in $TargetNames) {
        $text = Copy-SceneInText $text $SceneName $t $anchor
        if ($AfterOriginal) { $anchor = $t }
    }
    return [pscustomobject]@{ Backup = (Save-Composition $Canvas $text); Warnings = @() }
}

function Invoke-SceneRename($Canvas, [string]$SceneName, [string]$TargetName) {
    Assert-CanvasUsable $Canvas
    if ((Find-SceneIndex $Canvas.Dati $SceneName) -eq 0) {
        $where = Get-FirstSceneClash $Canvas $TargetName
        if ($where) {
            throw ("'$SceneName' is the first scene of the canvas, and SE.Live gives the first scene a name used nowhere else in OBS. " +
                   "'$TargetName' is already $where, so SE.Live would show '$TargetName 1'. Use a different name, e.g. '$(Get-SafeFirstSceneName $Canvas $TargetName)'.")
        }
    }
    $text = Rename-SceneInText $Canvas.Testo $SceneName $TargetName
    $backup = Save-Composition $Canvas $text
    return [pscustomobject]@{ Backup = $backup; Warnings = (Find-NameReferences $Canvas $SceneName); Note = '' }
}

function Invoke-SceneDelete($Canvas, [string]$SceneName) {
    Assert-CanvasUsable $Canvas
    $wasFirst = (Find-SceneIndex $Canvas.Dati $SceneName) -eq 0
    $text = Remove-SceneInText $Canvas.Testo $SceneName
    $backup = Save-Composition $Canvas $text
    $note = ''
    if ($wasFirst) {
        $next = [string](Get-SceneList $Canvas.Dati)[0].name
        $warn = Get-FirstSceneWarning $Canvas $next
        if ($warn) { $note = "`n`nNOTE: '$next' is now the first scene. $warn" }
    }
    return [pscustomobject]@{ Backup = $backup; Warnings = @(); Note = $note }
}

function Get-Backups($Canvas) {
    $dir  = Split-Path -Path $Canvas.Path -Parent
    $leaf = Split-Path -Path $Canvas.Path -Leaf
    $items = @()
    foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter "$leaf.bak_*" -File -ErrorAction SilentlyContinue | Sort-Object Name -Descending)) {
        $when = $f.LastWriteTime
        if ($f.Name -match '\.bak_(\d{8}_\d{6})') {
            $when = [datetime]::ParseExact($Matches[1], 'yyyyMMdd_HHmmss', [System.Globalization.CultureInfo]::InvariantCulture)
        }
        $scenes = $null
        try { $scenes = @(Get-SceneList (ConvertFrom-Json -InputObject (Read-Composition $f.FullName).Text) | ForEach-Object { [string]$_.name }) } catch { }
        $items += [pscustomobject]@{ Path = $f.FullName; When = $when; Scenes = $scenes }
    }
    return ,$items
}

function Format-Backup($b) {
    $what = if ($null -eq $b.Scenes) { 'unreadable' } else { '{0} scenes' -f $b.Scenes.Count }
    return ('{0:yyyy-MM-dd HH:mm:ss}  ({1})' -f $b.When, $what)
}

function Invoke-BackupRestore($Canvas, [string]$BackupPath) {
    if (-not (Test-Path -LiteralPath $BackupPath)) { throw "Backup not found: $BackupPath" }
    $bk = Read-Composition $BackupPath
    $bkData = ConvertFrom-Json -InputObject $bk.Text
    if (-not $bkData.PSObject.Properties['scenes']) { throw "That file is not a valid composition backup." }
    if ($Canvas.Dati.id -and $bkData.id -and $bkData.id -ne $Canvas.Dati.id) { throw "That backup belongs to a different canvas." }
    Assert-SafeToWrite $Canvas
    $backup = New-BackupFile $Canvas   # the current state stays restorable too
    $tmp = "$($Canvas.Path).tmp_$PID"
    Copy-Item -LiteralPath $BackupPath -Destination $tmp -Force
    [System.IO.File]::Replace($tmp, $Canvas.Path, [NullString]::Value)
    return [pscustomobject]@{ Backup = $backup; Scenes = @(Get-SceneList $bkData | ForEach-Object { [string]$_.name }) }
}

function Format-Warnings($Warnings) {
    if (-not $Warnings -or $Warnings.Count -eq 0) { return '' }
    $list = ($Warnings | ForEach-Object { Split-Path -Path $_ -Leaf }) -join "`n  - "
    return "`n`nNOTE: the old name also appears in other SE.Live files:`n  - $list`nIf this scene was linked (Link Scene), re-check the link in OBS."
}

# ------------------------------------------------------------------ #
#  5. Startup: close OBS, find the canvases                          #
# ------------------------------------------------------------------ #
if ($File) {
    if (-not (Test-Path -LiteralPath $File)) { Show-ErrorBox "File not found: $File"; exit 1 }
    $File = (Resolve-Path -LiteralPath $File).ProviderPath
    $compDir = Split-Path -Path $File -Parent
} else {
    $compDir = Get-CompositionDir
}

if (-not $List -and (Get-ObsProcess).Count -gt 0) {
    if (-not $script:GuiMode -and -not $Force) {
        Show-ErrorBox "OBS is running. Close it first, or add -Force to let the tool close it gracefully."
        exit 1
    }
    if ($script:GuiMode -and -not (Confirm-Box "OBS is running and needs to be closed, because SE.Live saves its canvas scenes when OBS shuts down.`n`nClose OBS gracefully now and reopen it when done?`n`n(If OBS shows a confirmation dialog on screen, answer it there.)")) {
        exit 0
    }
    try { Close-Obs } catch { Show-ErrorBox $_.Exception.Message; exit 1 }
    Wait-FilesSettled $compDir
}

if ($File) {
    $percorsi = @(Get-Item -LiteralPath $File)
} else {
    $percorsi = @(Get-ChildItem -LiteralPath $compDir -Filter '*.json' -File -ErrorAction SilentlyContinue)
    if ($percorsi.Count -eq 0 -and $script:GuiMode -and
        (Confirm-Box "No SE.Live composition files found in:`n$compDir`n`nIs SE.Live installed and have you created at least one canvas?`n`nBrowse for a composition file manually (e.g. portable OBS)?")) {
        $dlg = New-Object System.Windows.Forms.OpenFileDialog
        $dlg.Filter = 'SE.Live composition (*.json)|*.json'
        $dlg.Title  = 'Pick an SE.Live composition file (...\streamelements_multi-streaming\compositions\*.json)'
        if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $percorsi = @(Get-Item -LiteralPath $dlg.FileName) }
    }
    if ($percorsi.Count -eq 0) {
        Show-ErrorBox "No composition files found in:`n$compDir`n`nIs SE.Live installed, and have you created at least one canvas?"
        exit 1
    }
}

$canvasList = Get-Canvases $percorsi
if ($canvasList.Count -eq 0) {
    Show-ErrorBox "Found some files, but none contain scenes in a recognizable format. If SE.Live changed its file format, this tool may need an update."
    exit 1
}
$seVersion = Get-SELiveVersion $canvasList[0].Path
$script:AllCanvases = $canvasList
$script:TakenCache  = @{}

# ------------------------------------------------------------------ #
#  6a. Command-line mode                                             #
# ------------------------------------------------------------------ #
if ($List) {
    if ((Get-ObsProcess).Count -gt 0) { Write-Host "(OBS is running: unsaved dock changes are not in the files yet)" -ForegroundColor Yellow }
    Write-Host "SE.Live Scene Tool v$($script:ToolVersion) - built for SE.Live $($script:TestedSELive) on OBS $($script:TestedObs)"
    if (-not $seVersion) {
        Write-Host "Installed SE.Live version: not detected" -ForegroundColor Yellow
    } elseif ($seVersion -eq $script:TestedSELive) {
        Write-Host "Installed SE.Live version: $seVersion (the tested one)" -ForegroundColor Green
    } else {
        Write-Host "Installed SE.Live version: $seVersion - different from the tested $($script:TestedSELive): the format checks still protect your files" -ForegroundColor Yellow
    }
    foreach ($c in $canvasList) {
        Write-Host ""
        Write-Host "Canvas '$($c.Name)'  ->  $($c.Path)" -ForegroundColor Cyan
        if ($c.FormatIssue) { Write-Host "  unsupported format: $($c.FormatIssue)" -ForegroundColor Red }
        foreach ($s in (Get-SceneList $c.Dati)) {
            $mark = if ($s.active) { '*' } else { ' ' }
            Write-Host ("  {0} {1}  ({2} sources)" -f $mark, $s.name, @(@($s.sources) | Where-Object { $null -ne $_ }).Count)
        }
        $first = @(Get-SceneList $c.Dati)
        if ($first.Count -gt 0) {
            $warn = Get-FirstSceneWarning $c ([string]$first[0].name)
            if ($warn) { Write-Host "  WARNING: $warn" -ForegroundColor Yellow }
        }
        Write-Host ("  backups: {0}" -f (Get-Backups $c).Count)
    }
    exit 0
}

if (-not $script:GuiMode) {
    $target = $canvasList[0]
    if ($Canvas) {
        $target = @($canvasList | Where-Object { $_.Name -eq $Canvas }) | Select-Object -First 1
        if (-not $target) { Show-ErrorBox ("Canvas '$Canvas' not found. Canvases: " + (($canvasList | ForEach-Object { $_.Name }) -join ', ')); exit 1 }
    } elseif ($canvasList.Count -gt 1) {
        $list2 = ($canvasList | ForEach-Object { "$($_.Name) -> $($_.Path)" }) -join "`n"
        Show-ErrorBox "More than one canvas found, pick one with -Canvas <name> or -File <path>:`n$list2"
        exit 1
    }
    $names = Split-Names $NewName
    try {
        if ($RestoreFrom) {
            $res = Invoke-BackupRestore -Canvas $target -BackupPath $RestoreFrom
            $msg = "Done! Canvas '$($target.Name)' restored ($($res.Scenes.Count) scenes: $($res.Scenes -join ', '))."
        } elseif ($Delete) {
            if (-not $Scene) { throw "-Delete needs -Scene." }
            $res = Invoke-SceneDelete -Canvas $target -SceneName $Scene
            $msg = "Done! Scene '$Scene' deleted.$($res.Note)"
        } else {
            if (-not $Scene -or $names.Count -eq 0) { throw "In -NoGui mode you must pass -Scene and -NewName (or -Delete, -RestoreFrom, -List)." }
            if ($Rename) {
                if ($names.Count -ne 1) { throw "-Rename takes exactly one new name." }
                $res = Invoke-SceneRename -Canvas $target -SceneName $Scene -TargetName $names[0]
                $msg = "Done! Scene '$Scene' renamed to '$($names[0])'.$($res.Note)"
            } else {
                $res = Invoke-SceneDuplicate -Canvas $target -SceneName $Scene -TargetNames $names -AfterOriginal (-not $AtEnd)
                $msg = "Done! Scene '$Scene' duplicated as: $($names -join ', ')."
            }
        }
    } catch {
        Show-ErrorBox $_.Exception.Message
        exit 1
    }
    Write-Host ""
    Write-Host $msg -ForegroundColor Green
    Write-Host "Backup of the previous state: $($res.Backup)"
    $warn = Format-Warnings $res.Warnings
    if ($warn) { Write-Host $warn -ForegroundColor Yellow }
    if (-not $NoRestart -and $script:ObsExe) { [void](Start-Obs) }
    exit 0
}

# ------------------------------------------------------------------ #
#  6b. GUI mode                                                      #
# ------------------------------------------------------------------ #
$form                 = New-Object System.Windows.Forms.Form
$form.Text            = "SE.Live Scene Tool v$($script:ToolVersion) - for SE.Live $($script:TestedSELive)"
$form.ClientSize      = New-Object System.Drawing.Size(460, 400)
$form.StartPosition   = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox     = $false
$form.MinimizeBox     = $false
$form.Font            = New-Object System.Drawing.Font('Segoe UI', 9)

function New-Control([string]$Type, [int]$X, [int]$Y, [int]$W, [int]$H, [string]$Text) {
    $c = New-Object "System.Windows.Forms.$Type"
    $c.Location = New-Object System.Drawing.Point($X, $Y)
    $c.Size     = New-Object System.Drawing.Size($W, $H)
    if ($Text) { $c.Text = $Text }
    $form.Controls.Add($c)
    return $c
}

$rdoDuplicate = New-Control RadioButton 15  12 90 22 'Duplicate'
$rdoRename    = New-Control RadioButton 110 12 80 22 'Rename'
$rdoDelete    = New-Control RadioButton 195 12 75 22 'Delete'
$rdoRestore   = New-Control RadioButton 275 12 140 22 'Restore backup'
$rdoDuplicate.Checked = $true

$lblCanvas = New-Control Label    15 44  430 18 'Canvas:'
$cmbCanvas = New-Control ComboBox 15 63  430 24 $null
$lblScene  = New-Control Label    15 97  430 18 'Scene to copy:'
$cmbScene  = New-Control ComboBox 15 116 430 24 $null
$lblName   = New-Control Label    15 150 430 18 'Name(s) of the copy - one per line for several copies:'
$txtName   = New-Control TextBox  15 169 430 66 $null
$lblHint   = New-Control Label    15 240 430 54 ''
$chkAfter   = New-Control CheckBox 15 300 430 22 'Place the copies right after the original (otherwise at the end)'
$chkRestart = New-Control CheckBox 15 326 430 22 'Reopen OBS when done'
$lblVersion = New-Control Label   15 356 235 36 ''
$btnOk      = New-Control Button  255 360 92 28 'Duplicate'
$btnCancel  = New-Control Button  353 360 92 28 'Cancel'

foreach ($cmb in @($cmbCanvas, $cmbScene)) { $cmb.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList }
$txtName.Multiline     = $true
$txtName.AcceptsReturn = $true
$txtName.ScrollBars    = 'Vertical'
$lblHint.ForeColor     = [System.Drawing.Color]::DimGray
$lblVersion.ForeColor  = [System.Drawing.Color]::Gray
$chkRestart.Checked    = $true
$chkAfter.Checked      = $true
$btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
$form.CancelButton = $btnCancel

$verText = "Built for SE.Live $($script:TestedSELive)`n"
if (-not $seVersion) {
    $verText += 'Installed SE.Live: not detected'
} elseif ($seVersion -eq $script:TestedSELive) {
    $verText += "Installed SE.Live: $seVersion (tested)"
    $lblVersion.ForeColor = [System.Drawing.Color]::SeaGreen
} else {
    $verText += "Installed SE.Live: $seVersion (not tested)"
    $lblVersion.ForeColor = [System.Drawing.Color]::DarkOrange
}
$lblVersion.Text = $verText
foreach ($c in $canvasList) { [void]$cmbCanvas.Items.Add($c.Name) }

$script:LastDefault = ''
$script:Backups     = @()

function Get-CurrentCanvas { return $canvasList[$cmbCanvas.SelectedIndex] }

$UpdateHint = {
    $canvas = Get-CurrentCanvas
    $lblHint.ForeColor = [System.Drawing.Color]::DimGray
    $btnOk.Enabled = $true
    if ($rdoRestore.Checked) {
        if ($script:Backups.Count -eq 0) {
            $lblHint.Text = 'No backups yet for this canvas: the tool creates one before every change.'
            $btnOk.Enabled = $false
        } elseif ($cmbScene.SelectedIndex -ge 0) {
            $b = $script:Backups[$cmbScene.SelectedIndex]
            if ($null -eq $b.Scenes) { $lblHint.Text = 'This backup cannot be read.'; $btnOk.Enabled = $false }
            else { $lblHint.Text = "Scenes in this backup: $($b.Scenes -join ', ')`nThe current state is backed up too before restoring." }
        }
    } elseif ($rdoRename.Checked) {
        $lblHint.Text = "Use a name no other scene on this canvas has."
        if ($cmbScene.SelectedIndex -eq 0) {
            $warn = Get-FirstSceneWarning $canvas ([string]$cmbScene.SelectedItem)
            if ($warn) { $lblHint.Text = $warn; $lblHint.ForeColor = [System.Drawing.Color]::DarkOrange }
            else { $lblHint.Text = "First scene of the canvas: its name must not be used anywhere else in OBS (scenes or sources, any canvas), otherwise SE.Live adds ' 1'. The tool checks it for you." }
        }
    } elseif ($rdoDelete.Checked) {
        $scene = @(Get-SceneList $canvas.Dati)[[Math]::Max(0, $cmbScene.SelectedIndex)]
        if ($scene -and $scene.active) {
            $lblHint.Text = "This is the active scene of the canvas: switch the canvas to another scene in OBS first, then delete it."
            $btnOk.Enabled = $false
        } else {
            $lblHint.Text = "The scene is removed from the canvas (its sources stay in OBS). A backup is made first, so you can bring it back with Restore backup."
        }
        $lblHint.ForeColor = [System.Drawing.Color]::DarkOrange
    } else {
        $lblHint.Text = "Use brand-new names never used before on this canvas. The copy gets the same sources, positions, crops and filters."
    }
    if ($canvas.FormatIssue) {
        $lblHint.Text = "Unsupported file format ($($canvas.FormatIssue)). SE.Live probably changed something: the tool needs an update."
        $lblHint.ForeColor = [System.Drawing.Color]::Firebrick
        $btnOk.Enabled = $false
    }
}
$UpdateName = {
    if ($rdoRestore.Checked -or $rdoDelete.Checked -or -not $cmbScene.SelectedItem) { return }
    if ($rdoRename.Checked) {
        $default = [string]$cmbScene.SelectedItem
        # A first scene that SE.Live shows as "<name> 1": offer a name that will stick.
        if ($cmbScene.SelectedIndex -eq 0 -and (Get-FirstSceneClash (Get-CurrentCanvas) $default)) {
            $default = Get-SafeFirstSceneName (Get-CurrentCanvas) $default
        }
    }
    else { $default = "$($cmbScene.SelectedItem) - Copy" }
    if ($txtName.Text -eq $script:LastDefault -or [string]::IsNullOrWhiteSpace($txtName.Text)) {
        $txtName.Text = $default
    }
    $script:LastDefault = $default
}
$UpdateList = {
    $cmbScene.Items.Clear()
    $canvas = Get-CurrentCanvas
    if ($rdoRestore.Checked) {
        $script:Backups = Get-Backups $canvas
        foreach ($b in $script:Backups) { [void]$cmbScene.Items.Add((Format-Backup $b)) }
    } else {
        foreach ($s in (Get-SceneList $canvas.Dati)) { [void]$cmbScene.Items.Add([string]$s.name) }
    }
    if ($cmbScene.Items.Count -gt 0) { $cmbScene.SelectedIndex = 0 }
    & $UpdateName
    & $UpdateHint
}
$UpdateMode = {
    if ($rdoRestore.Checked) {
        $lblScene.Text = 'Backup to restore (newest first):'; $btnOk.Text = 'Restore'
    } elseif ($rdoRename.Checked) {
        $lblScene.Text = 'Scene to rename:'; $lblName.Text = 'New name:'; $btnOk.Text = 'Rename'
    } elseif ($rdoDelete.Checked) {
        $lblScene.Text = 'Scene to delete:'; $btnOk.Text = 'Delete'
    } else {
        $lblScene.Text = 'Scene to copy:'; $lblName.Text = 'Name(s) of the copy - one per line for several copies:'; $btnOk.Text = 'Duplicate'
    }
    $noName = $rdoRestore.Checked -or $rdoDelete.Checked
    $lblName.Visible  = -not $noName
    $txtName.Visible  = -not $noName
    $chkAfter.Visible = $rdoDuplicate.Checked
    $lblHint.Top      = if ($noName) { 150 } else { 240 }
    & $UpdateList
}
$cmbCanvas.Add_SelectedIndexChanged($UpdateList)
$cmbScene.Add_SelectedIndexChanged({ & $UpdateName; & $UpdateHint })
$rdoDuplicate.Add_CheckedChanged({ if ($this.Checked) { & $UpdateMode } })
$rdoRename.Add_CheckedChanged({ if ($this.Checked) { & $UpdateMode } })
$rdoDelete.Add_CheckedChanged({ if ($this.Checked) { & $UpdateMode } })
$rdoRestore.Add_CheckedChanged({ if ($this.Checked) { & $UpdateMode } })
$cmbCanvas.SelectedIndex = 0
& $UpdateMode

$btnOk.Add_Click({
    try {
        $canvas = Get-CurrentCanvas
        if ($rdoRestore.Checked) {
            $b = $script:Backups[$cmbScene.SelectedIndex]
            if (-not (Confirm-Box "Restore canvas '$($canvas.Name)' to the backup of $('{0:yyyy-MM-dd HH:mm:ss}' -f $b.When)?`n`nScenes after restore: $($b.Scenes -join ', ')")) { return }
            $res = Invoke-BackupRestore -Canvas $canvas -BackupPath $b.Path
            $msg = "Done! Canvas restored ($($res.Scenes.Count) scenes).`n`nBackup of the state before restoring:`n$($res.Backup)"
        } elseif ($rdoDelete.Checked) {
            $selected = [string]$cmbScene.SelectedItem
            if (-not (Confirm-Box "Delete scene '$selected' from canvas '$($canvas.Name)'?`n`nA backup is made first.")) { return }
            $res = Invoke-SceneDelete -Canvas $canvas -SceneName $selected
            $msg = "Done! Scene '$selected' deleted.`n`nBackup of the previous state:`n$($res.Backup)$($res.Note)"
        } else {
            $selected = [string]$cmbScene.SelectedItem
            $names    = Split-Names @($txtName.Text)
            if ($rdoRename.Checked) {
                if ($names.Count -ne 1) { throw "Type exactly one new name." }
                $res = Invoke-SceneRename -Canvas $canvas -SceneName $selected -TargetName $names[0]
                $msg = "Done! Scene '$selected' renamed to '$($names[0])'.`n`nBackup of the original:`n$($res.Backup)$($res.Note)"
            } else {
                $res = Invoke-SceneDuplicate -Canvas $canvas -SceneName $selected -TargetNames $names -AfterOriginal $chkAfter.Checked
                $what = if ($names.Count -eq 1) { "as '$($names[0])'" } else { "$($names.Count) times: $($names -join ', ')" }
                $msg = "Done! Scene '$selected' duplicated $what.`n`nBackup of the original:`n$($res.Backup)"
            }
            $msg += Format-Warnings $res.Warnings
        }
        if ($chkRestart.Checked) {
            if (Start-Obs) { $msg += "`n`nReopening OBS: check the canvas dock." }
            else           { $msg += "`n`nCould not find the OBS executable: please reopen it manually." }
        }
        Show-InfoBox $msg
        $form.Close()
    } catch {
        Show-ErrorBox $_.Exception.Message
    }
})

[void]$form.ShowDialog()
