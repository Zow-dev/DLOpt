# DLOpt installer / uninstaller (Windows PowerShell 5.1+).
# Usage: run Install.bat or Uninstall.bat (double click). Optional: -GamePath "D:\...\ProjectZomboid"
param(
    [ValidateSet('Install', 'Uninstall')]
    [string]$Action = 'Install',
    [string]$GamePath = ''
)

$ErrorActionPreference = 'Stop'

$AgentJar   = 'dlopt-agent.jar'
$ConfigFile = 'dlopt.properties'
$LauncherJson = 'ProjectZomboid64.json'
$AgentArg   = '-javaagent:' + $AgentJar
$MinJava    = 25
$ScriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path

function Write-Step([string]$msg) { Write-Host ('[DLOpt] ' + $msg) }
function Fail([string]$msg) { Write-Host ('[DLOpt] ERROR: ' + $msg) -ForegroundColor Red; exit 1 }

function Test-GameFolder([string]$path) {
    if ([string]::IsNullOrWhiteSpace($path)) { return $false }
    return (Test-Path -LiteralPath (Join-Path $path $LauncherJson))
}

function Get-SteamLibraries {
    $libs = New-Object System.Collections.Generic.List[string]
    $steamRoots = @()
    foreach ($key in @('HKCU:\Software\Valve\Steam', 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam', 'HKLM:\SOFTWARE\Valve\Steam')) {
        try {
            $p = Get-ItemProperty -Path $key -ErrorAction Stop
            if ($p.SteamPath) { $steamRoots += ($p.SteamPath -replace '/', '\') }
            if ($p.InstallPath) { $steamRoots += $p.InstallPath }
        } catch { }
    }
    $steamRoots += 'C:\Program Files (x86)\Steam'
    $steamRoots += 'C:\Program Files\Steam'

    foreach ($root in ($steamRoots | Select-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        $libs.Add($root)
        $vdf = Join-Path $root 'steamapps\libraryfolders.vdf'
        if (Test-Path -LiteralPath $vdf) {
            foreach ($line in (Get-Content -LiteralPath $vdf)) {
                if ($line -match '"path"\s+"(.+?)"') {
                    $libs.Add(($Matches[1] -replace '\\\\', '\'))
                }
            }
        }
    }
    return ($libs | Select-Object -Unique)
}

function Find-GameFolder {
    $candidates = New-Object System.Collections.Generic.List[string]
    if ($GamePath) { $candidates.Add($GamePath) }
    $candidates.Add($ScriptDir)                          # installer unzipped inside the game folder
    $candidates.Add((Split-Path -Parent $ScriptDir))     # or one level below it
    foreach ($lib in (Get-SteamLibraries)) {
        $candidates.Add((Join-Path $lib 'steamapps\common\ProjectZomboid'))
    }
    foreach ($c in $candidates) {
        if (Test-GameFolder $c) { return (Resolve-Path -LiteralPath $c).Path }
    }
    return $null
}

function Get-BundledJavaMajor([string]$gameDir) {
    $release = Join-Path $gameDir 'jre64\release'
    if (-not (Test-Path -LiteralPath $release)) { return $null }
    foreach ($line in (Get-Content -LiteralPath $release)) {
        if ($line -match '^JAVA_VERSION="?([0-9]+)(?:\.([0-9]+))?') {
            $major = [int]$Matches[1]
            if ($major -eq 1 -and $Matches[2]) { $major = [int]$Matches[2] }   # 1.8 -> 8
            return $major
        }
    }
    return $null
}

function Find-GameJar([string]$gameDir) {
    foreach ($rel in @('projectzomboid.jar', 'java\projectzomboid.jar')) {
        $p = Join-Path $gameDir $rel
        if (Test-Path -LiteralPath $p) { return $p }
    }
    return $null
}

# $true = the names DLOpt patches are in IsoChunkMap.class, $false = they are not, $null = could not check.
function Test-GameJarSupported([string]$jarPath) {
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [System.IO.Compression.ZipFile]::OpenRead($jarPath)
        try {
            $entry = $zip.GetEntry('zombie/iso/IsoChunkMap.class')
            if ($entry -eq $null) { return $false }
            $ms = New-Object System.IO.MemoryStream
            $in = $entry.Open()
            $in.CopyTo($ms)
            $in.Dispose()
            $text = [System.Text.Encoding]::GetEncoding(28591).GetString($ms.ToArray())
            return ($text.Contains('CalcChunkWidth') -and $text.Contains('chunkGridWidth') -and $text.Contains('chunkWidthInTiles'))
        } finally {
            $zip.Dispose()
        }
    } catch {
        return $null
    }
}

function Read-Text([string]$path) { return [System.IO.File]::ReadAllText($path) }

function Write-Text([string]$path, [string]$text) {
    [System.IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding($false)))
}

function Test-JsonValid([string]$text) {
    try { $null = ConvertFrom-Json -InputObject $text; return $true } catch { return $false }
}

function Get-JvmPreset([string]$configPath) {
    # Installer-only setting in dlopt.properties: jvmPreset=g1 (default) or off.
    if (-not (Test-Path -LiteralPath $configPath)) { return 'g1' }
    foreach ($line in (Get-Content -LiteralPath $configPath)) {
        if ($line -match '^\s*jvmPreset\s*=\s*([A-Za-z0-9]+)') { return $Matches[1].ToLower() }
    }
    return 'g1'
}

$GcFlagNames = 'UseZGC|UseShenandoahGC|UseSerialGC|UseParallelGC|UseParallelOldGC|UseConcMarkSweepGC'

# Makes G1 the only collector in vmArgs. Returns the text unchanged if it cannot do that safely.
function Set-G1Preset([string]$text, [string]$nl) {
    $ownLine = '(?m)^[ \t]*"-XX:[+-](?:' + $GcFlagNames + '|ZGenerational)",?[ \t]*\r?\n'
    foreach ($m in [regex]::Matches($text, $ownLine)) {
        Write-Step ('Replacing GC flag: ' + $m.Value.Trim().TrimEnd(','))
    }
    $out = [regex]::Replace($text, $ownLine, '')
    $inline = '"-XX:[+-](?:' + $GcFlagNames + '|ZGenerational)"[ \t]*,?[ \t]*'      # flag next to other args or alone in a one-line array
    foreach ($m in [regex]::Matches($out, $inline)) {
        Write-Step ('Replacing GC flag: ' + $m.Value.Trim().TrimEnd(',').Trim())
    }
    $out = [regex]::Replace($out, $inline, '')
    $out = [regex]::Replace($out, ',(\s*\])', '$1')      # removed last element can leave a trailing comma

    if ($out -match ('-XX:\+(?:' + $GcFlagNames + ')')) {
        Write-Step 'Warning: a GC flag is in an unexpected format, JVM preset skipped (agent still installed).'
        return $text
    }
    $open = [regex]::Match($out, '"vmArgs"\s*:\s*\[')
    if (-not $open.Success) { return $text }
    $mainArgs = [regex]::Match($out, '"vmArgs"\s*:\s*\[([^\]]*)\]')      # first vmArgs array only (OS-specific blocks do not count)
    $hasMainG1 = ($mainArgs.Success -and ($mainArgs.Groups[1].Value -match '"-XX:\+UseG1GC"'))
    if (-not $hasMainG1) {
        $out = $out.Substring(0, $open.Index) + $open.Value + $nl + "`t`t" + '"-XX:+UseG1GC",' + $out.Substring($open.Index + $open.Length)
        Write-Step 'JVM preset: G1 GC enabled.'
    } else {
        Write-Step 'JVM preset: G1 GC already enabled.'
    }
    return $out
}

# ------------------------------------------------------------------ main

Write-Host ''
Write-Host '=== DLOpt ===' 
$game = Find-GameFolder
if (-not $game) {
    Write-Step 'Could not find Project Zomboid automatically.'
    $typed = Read-Host 'Paste the game folder path (the folder that contains ProjectZomboid64.json)'
    $typed = $typed.Trim().Trim('"')
    if (-not (Test-GameFolder $typed)) { Fail ('ProjectZomboid64.json not found in: ' + $typed) }
    $game = (Resolve-Path -LiteralPath $typed).Path
}
Write-Step ('Game folder: ' + $game)

if (Get-Process -Name 'ProjectZomboid64', 'ProjectZomboid32' -ErrorAction SilentlyContinue) {
    Fail 'Project Zomboid is running. Close the game and run this again.'
}

$jsonPath = Join-Path $game $LauncherJson
$backupPath = $jsonPath + '.dlopt.bak'
$raw = Read-Text $jsonPath
$nl = "`n"
if ($raw.Contains("`r`n")) { $nl = "`r`n" }
$agentLinePattern = '(?m)^[ \t]*"' + [regex]::Escape($AgentArg) + '",?[ \t]*\r?\n'
$agentTokenPattern = '"' + [regex]::Escape($AgentArg) + '"'

# Removes every DLOpt agent entry: own-line, inline (next to other args) and duplicates.
function Remove-AgentEntries([string]$text) {
    $out = [regex]::Replace($text, $agentLinePattern, '')
    $out = [regex]::Replace($out, $agentTokenPattern + '[ \t]*,?[ \t]*', '')
    $out = [regex]::Replace($out, ',(\s*\])', '$1')      # removed last element can leave a trailing comma
    return $out
}

if ($Action -eq 'Install') {
    $javaMajor = Get-BundledJavaMajor $game
    if ($javaMajor -eq $null) {
        Write-Step 'Warning: could not read the bundled Java version (jre64\release). Continuing.'
    } elseif ($javaMajor -lt $MinJava) {
        Fail ('The game uses Java ' + $javaMajor + ', DLOpt needs Java ' + $MinJava + ' or newer. Nothing was changed.')
    } else {
        Write-Step ('Bundled Java: ' + $javaMajor + ' (ok)')
    }

    $gameJar = Find-GameJar $game
    if ($gameJar -eq $null) {
        Write-Step 'Warning: projectzomboid.jar not found, could not check the game build. Continuing.'
    } else {
        $supported = Test-GameJarSupported $gameJar
        if ($supported -eq $false) {
            Fail 'This game build is not supported by this DLOpt version (IsoChunkMap.CalcChunkWidth not found). Nothing was changed.'
        } elseif ($supported -eq $null) {
            Write-Step 'Warning: could not read projectzomboid.jar, game build not checked. Continuing.'
        } else {
            Write-Step 'Game build check: ok'
        }
    }

    foreach ($f in @($AgentJar, $ConfigFile)) {
        if (-not (Test-Path -LiteralPath (Join-Path $ScriptDir $f))) { Fail ('Missing file next to the installer: ' + $f) }
    }

    if ($raw -notmatch '"vmArgs"\s*:\s*\[') { Fail 'No "vmArgs" array found in ProjectZomboid64.json. Nothing was changed.' }

    foreach ($m in [regex]::Matches($raw, '"-javaagent:(?!' + [regex]::Escape($AgentJar) + '")[^"]*"')) {
        Write-Step ('Other Java agent found, left untouched: ' + $m.Value.Trim('"'))
    }

    try {
        # Keep the backup equal to the last launcher file that had no DLOpt changes.
        $hasAgentLine = ($raw -match $agentTokenPattern)
        $backupBad = $false
        if (Test-Path -LiteralPath $backupPath) { $backupBad = ((Read-Text $backupPath) -match $agentTokenPattern) }
        if ((-not $hasAgentLine) -or (-not (Test-Path -LiteralPath $backupPath)) -or $backupBad) {
            if ($hasAgentLine) {
                $cleanBak = Remove-AgentEntries $raw
                if (-not (Test-JsonValid $cleanBak)) { Fail 'Launcher file is broken. Verify game files in Steam, then run this again. Nothing was changed.' }
                Write-Text $backupPath $cleanBak
            } else {
                Copy-Item -LiteralPath $jsonPath -Destination $backupPath -Force
            }
            Write-Step ('Backup saved: ' + $backupPath)
        }

        Copy-Item -LiteralPath (Join-Path $ScriptDir $AgentJar) -Destination (Join-Path $game $AgentJar) -Force
        $cfgDest = Join-Path $game $ConfigFile
        if (-not (Test-Path -LiteralPath $cfgDest)) {
            Copy-Item -LiteralPath (Join-Path $ScriptDir $ConfigFile) -Destination $cfgDest
            Write-Step 'Config created.'
        } else {
            Write-Step 'Existing config kept.'
        }

        # Strip every existing DLOpt agent entry (own-line, inline, duplicates), then add exactly one.
        $base = Remove-AgentEntries $raw
        if ($hasAgentLine) { Write-Step 'Existing DLOpt agent entries cleaned up.' }
        $emptyArray = [regex]::Match($base, '"vmArgs"\s*:\s*\[\s*\]')
        $openArray  = [regex]::Match($base, '"vmArgs"\s*:\s*\[')

        if ($emptyArray.Success) {
            $replacement = $openArray.Value + $nl + "`t`t" + '"' + $AgentArg + '"' + $nl + "`t"
            $new = $base.Substring(0, $emptyArray.Index) + $replacement + ']' + $base.Substring($emptyArray.Index + $emptyArray.Length)
        } else {
            $insert = $openArray.Value + $nl + "`t`t" + '"' + $AgentArg + '",'
            $new = $base.Substring(0, $openArray.Index) + $insert + $base.Substring($openArray.Index + $openArray.Length)
        }

        $preset = Get-JvmPreset (Join-Path $game $ConfigFile)
        if ($preset -eq 'g1') {
            $new = Set-G1Preset $new $nl
        } else {
            Write-Step 'JVM preset is off, GC flags untouched.'
        }

        if ($new -ne $raw) {
            if (-not (Test-JsonValid $new)) { Fail 'Edited launcher file would be invalid JSON. The launcher file was not modified.' }
            Write-Text $jsonPath $new
            Write-Step 'Launcher updated.'
        } else {
            Write-Step 'Launcher already up to date.'
        }
    } catch {
        Fail ('Could not write to the game folder (' + $_.Exception.Message + '). Try right click > Run as administrator.')
    }

    Write-Host ''
    Write-Step 'DONE. Start the game from Steam as usual.'
    Write-Step 'If Steam updates or verifies the game files, run Install.bat again.'
    Write-Step 'Check console.txt (Zomboid folder) for lines starting with [DLOpt].'
}
else {
    try {
        # Only DLOpt's own entries are removed. The launcher file is never replaced as a whole,
        # so changes made by other mods (for example their Java agents) are kept.
        if ($raw -match $agentTokenPattern) {
            $new = Remove-AgentEntries $raw
            if (-not (Test-JsonValid $new)) { Fail 'Edited launcher file would be invalid JSON. The launcher file was not modified.' }
            Write-Text $jsonPath $new
            Write-Step 'DLOpt agent entries removed from launcher.'
        } else {
            Write-Step 'Launcher has no DLOpt agent entry.'
        }
        # Safety: never delete the agent jar while the launcher still points to it.
        if ((Read-Text $jsonPath) -match $agentTokenPattern) {
            Fail 'The launcher still references the DLOpt agent. Agent jar and config were NOT removed.'
        }
        if (Test-Path -LiteralPath $backupPath) { Remove-Item -LiteralPath $backupPath -Force }
        foreach ($f in @($AgentJar, $ConfigFile)) {
            $p = Join-Path $game $f
            if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force; Write-Step ('Removed ' + $f) }
        }
    } catch {
        Fail ('Could not write to the game folder (' + $_.Exception.Message + '). Try right click > Run as administrator.')
    }
    Write-Host ''
    Write-Step 'DONE. DLOpt is removed. Other launcher settings (including the G1 GC flag) were left as they are.'
    Write-Step 'To get the vanilla launcher file back: Steam > Project Zomboid > Properties > Installed Files > Verify integrity.'
}
