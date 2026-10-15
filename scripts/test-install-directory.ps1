# Verifies the installation directory this fork chooses, by compiling the real
# chooseForkInstallationDirectory macro and running it.
#
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File scripts\test-install-directory.ps1
# Exit:  0 = every case behaved as required, 1 = a case did not.
#
# `powershell.exe` rather than `pwsh`, because that is the engine NSIS invokes for this
# installer's PowerShell steps, and the probe's own registry writes go through it.
#
# # What this is for
#
# electron-builder names the default installation directory after the EXECUTABLE name
# (`APP_FILENAME` = `productFilename`), so this fork's required `executableName: sing-box`
# put both it and the upstream client - which is per-machine too - in
# `C:\Program Files\sing-box`. Two products, one directory.
#
# The fix cannot be a config value: `APP_FILENAME` reaches makensis on the command line, and a
# second `!define` of the same name is a fatal NSIS error rather than an override. So the
# directory is chosen in `customInit`, and this script is what proves the choice.
#
# # Why it is not just a compile check
#
# `build/check-installer.nsh` compiles the file. The first version of this macro compiled
# perfectly and renamed nothing, because `StrCpy $var $in "" -1` silently returns nothing
# unless the command-line assertion is enabled. A compile check cannot see that; running the
# macro can. So this builds `build/rename-probe.nsi` - which includes the REAL macro - executes
# it, and asserts what it decided.
$ErrorActionPreference = "Stop"

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$clientDir = Resolve-Path (Join-Path $here "..")
$buildDir = Join-Path $clientDir "build"
$installerNsh = Join-Path $buildDir "installer.nsh"

$passed = 0
$failed = 0
function Report([string]$Name, [bool]$Ok, [string]$Detail) {
    if ($Ok) { $script:passed += 1; Write-Host ("PASS  {0,-56} {1}" -f $Name, $Detail) }
    else { $script:failed += 1; Write-Host ("FAIL  {0,-56} {1}" -f $Name, $Detail) }
}

# --- locate the pieces the probe needs ----------------------------------------------------
$makensis = $null
$cacheRoot = Join-Path $env:LOCALAPPDATA "electron-builder\Cache"
Get-ChildItem $cacheRoot -Directory -Filter 'nsis@*' -ErrorAction SilentlyContinue | ForEach-Object {
    Get-ChildItem $_.FullName -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $candidate = Join-Path $_.FullName "windows\makensis.exe"
        if (-not $makensis -and (Test-Path $candidate)) { $makensis = $candidate }
    }
}
if (-not $makensis) {
    Write-Host "FAIL  makensis not found under $cacheRoot - run 'pnpm run package:win' once, or install NSIS" -ForegroundColor Red
    exit 1
}
$includeDir = Join-Path $clientDir "node_modules\electron-builder\node_modules\app-builder-lib\templates\nsis\include"
if (-not (Test-Path $includeDir)) {
    $found = Get-ChildItem (Join-Path $clientDir "node_modules\.pnpm") -Recurse -Filter "StrContains.nsh" -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($found) { $includeDir = Split-Path -Parent $found.FullName }
}
if (-not (Test-Path $includeDir)) {
    Write-Host "FAIL  app-builder-lib's nsis include directory not found; is node_modules installed?" -ForegroundColor Red
    exit 1
}

# --- compile and run ----------------------------------------------------------------------
$work = Join-Path ([System.IO.Path]::GetTempPath()) ("jiejiebox-install-dir-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
New-Item -ItemType Directory -Path $work -Force | Out-Null
$produced = Join-Path $buildDir "rename-probe.exe"
$probeOutput = Join-Path $work "probe.txt"
try {
    Remove-Item $produced -Force -ErrorAction SilentlyContinue
    $compileLog = Join-Path $work "compile.log"
    & $makensis "/DINSTALLER_NSH=$installerNsh" "/DBUILD_RESOURCES_DIR=$buildDir" "/DPROBE_OUTPUT=$probeOutput" (Join-Path $buildDir "rename-probe.nsi") *> $compileLog
    Report "the probe compiles against the real installer.nsh" ($LASTEXITCODE -eq 0) "exit=$LASTEXITCODE"

    if (-not (Test-Path $produced)) {
        Write-Host "FAIL  makensis produced no executable" -ForegroundColor Red
        Get-Content $compileLog | Select-Object -Last 10 | ForEach-Object { "      $_" }
        exit 1
    }
    $runner = Join-Path $work "probe.exe"
    Move-Item $produced $runner
    & $runner /S | Out-Null
    Start-Sleep -Milliseconds 800
    if (-not (Test-Path $probeOutput)) {
        Write-Host "FAIL  the probe produced no output file" -ForegroundColor Red
        exit 1
    }
    $probe = @{}
    foreach ($line in Get-Content $probeOutput) {
        if ($line -match '^([^=]+)=(.*)$') { $probe[$matches[1]] = $matches[2] }
    }
} finally {
    Remove-Item $produced -Force -ErrorAction SilentlyContinue
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}

# --- the assertions -----------------------------------------------------------------------
# The executable name is the security contract; the directory is what moves. Both are pinned,
# because "we fixed the collision by renaming the executable" is the fix that is not allowed.
Report "APP_FILENAME is still sing-box (the executable does not move)" ($probe["APP_FILENAME"] -eq "sing-box") $probe["APP_FILENAME"]
Report "the fork's directory name is Jiejiebox" ($probe["FORK_DIR_NAME"] -eq "Jiejiebox") $probe["FORK_DIR_NAME"]

$fresh = [string]$probe["fresh"]
Report "a fresh install does NOT use the upstream directory" ($fresh -notmatch '\\sing-box$') $fresh
Report "a fresh install uses <program files>\Jiejiebox" ($fresh -match '\\Jiejiebox$') $fresh
Report "the fresh directory is not the upstream one" ($fresh -ne "C:\Program Files\sing-box") $fresh
Report "the two default directories differ" (($fresh -ne "C:\Program Files\sing-box")) "fork=$fresh upstream=C:\Program Files\sing-box"

# An upgrade stays an upgrade: the previous installation's own record of where it went wins,
# or the user ends up with a second installation beside the first and their data behind.
$recorded = [string]$probe["previous-recorded"]
Report "an upgrade reuses the previous installation's directory" ($recorded -eq "C:\Program Files\sing-box") $recorded

$custom = [string]$probe["previous-custom"]
Report "an upgrade reuses a previous custom location" ($custom -eq "D:\Apps\Elsewhere") $custom

# --- the macro is wired into the installer, before anything reads $INSTDIR -----------------
$nshText = Get-Content -LiteralPath $installerNsh -Raw
Report "customInit chooses the directory before reading the layout" `
    ($nshText -match '(?s)!insertmacro chooseForkInstallationDirectory.*Installation_LAYOUT_REGISTRY_KEY') `
    "called in customInit"
Report "the installer invokes it exactly once" `
    ((($nshText | Select-String -Pattern '!insertmacro chooseForkInstallationDirectory' -AllMatches).Matches.Count) -eq 1) `
    "one call site"

Write-Host ""
Write-Host "installation directory: $passed passed, $failed failed"
if ($failed -ne 0) { exit 1 }
exit 0
