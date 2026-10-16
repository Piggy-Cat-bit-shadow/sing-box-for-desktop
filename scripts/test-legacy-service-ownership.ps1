# Tests for the legacy service ownership decision.
#
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File scripts\test-legacy-service-ownership.ps1
# Exit:  0 = every case behaved as required, 1 = a case did not.
#
# `powershell.exe`, not `pwsh`: this script runs alongside the installer's own PowerShell,
# which NSIS invokes as `$SYSDIR\WindowsPowerShell\v1.0\powershell.exe` - Windows PowerShell
# 5.1. Everything here is written to run on that, so the tests exercise the same engine the
# product does.
#
# # Case A is the one that matters
#
# The service this step exists to remove is called `sing-box-daemon`, which is ALSO the name
# the upstream client's daemon uses. So the failure worth preventing is not "we failed to
# clean up" - it is "we deleted another product's service", and every case below exists to
# pin one of the signals that has to be present before deletion is allowed.
#
# Case A is exactly the machine the user's coexistence requirement describes: the upstream
# client installed per-machine at its own directory, its daemon registered under
# `sing-box-daemon`, and nothing of ours present except the registry key that BOTH products
# write. It must not be deleted.
#
# # Why the signals are injected
#
# The decision is a pure function of evidence, so the harness supplies the evidence: whether
# the marker file "exists" and whether a path is on a fixed volume. That makes the cases
# runnable on any machine - and it means a case that needs the marker ABSENT does not have to
# be run on a machine where it happens to be absent, which is the difference between a test
# and a coincidence.
$ErrorActionPreference = "Stop"

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here "..\build\installer-legacy-service-ownership.ps1")

$passed = 0
$failed = 0

function Report([string]$Name, [bool]$Ok, [string]$Detail) {
    if ($Ok) {
        $script:passed += 1
        Write-Host ("PASS  {0,-64} {1}" -f $Name, $Detail)
    } else {
        $script:failed += 1
        Write-Host ("FAIL  {0,-64} {1}" -f $Name, $Detail)
    }
}

# Both injected signals succeed unless a case says otherwise.
$markerPresent = { param($p) $true }
$markerAbsent = { param($p) $false }
$fixedVolume = { param($p) $true }
$removableVolume = { param($p) $false }

$ownedTree = "C:\Program Files\sing-box"
$daemonImage = "$ownedTree\resources\daemon\sing-box-daemon.exe"

# What the installed application executable declares as its product name. The upstream client and
# this fork ship the same file name, the same service name and the same layout, so this is the only
# signal that tells them apart - it is read from the tree the service points at.
$saysJiejiebox = { param($p) "Jiejiebox" }
$saysUpstream = { param($p) "sing-box" }
$saysNothing = { param($p) "" }

function Evaluate(
    [bool]$ServiceExists,
    [string]$ImagePath,
    [scriptblock]$Marker,
    [scriptblock]$Volume,
    [string]$LegacyDirectoryName = "sing-box",
    [scriptblock]$ProductName = $null
) {
    if ($null -eq $ProductName) { $ProductName = $saysJiejiebox }
    return Get-JiejieboxLegacyOwnershipDecision `
        -ServiceName "sing-box-daemon" `
        -ServiceExists $ServiceExists `
        -ServiceImagePath $ImagePath `
        -LegacyApplicationDataDirectoryName $LegacyDirectoryName `
        -TestPath $Marker `
        -TestFixedVolume $Volume `
        -GetProductName $ProductName
}

# --- Case A: the upstream client's service, with our registry key present ----------------
#
# This is the case the previous guard got wrong. `HKLM\SOFTWARE\SagerNet\sing-box` exists (the
# upstream client writes it too), the service is named `sing-box-daemon`, and its binary sits
# in a perfectly ordinary `<root>\resources\daemon\` tree. The only thing missing is any proof
# that OUR client ever ran from that tree - so the answer must be no.
$decision = Evaluate -ServiceExists $true -ImagePath $daemonImage -Marker $markerAbsent -Volume $fixedVolume -ProductName $saysUpstream
Report "Case A: official service, no Jiejiebox proof -> MUST NOT DELETE" (-not $decision.CanRemove) $decision.Reason

# The same machine, but with the previous fork's data directory named differently: still no
# proof, because the signal is the marker and not the directory.
$decision = Evaluate -ServiceExists $true -ImagePath $daemonImage -Marker $markerAbsent -Volume $fixedVolume -LegacyDirectoryName "sing-box-for-desktop" -ProductName $saysUpstream
Report "Case A2: official service, alternate legacy dir, no proof -> MUST NOT DELETE" (-not $decision.CanRemove) $decision.Reason

# --- Case B: a previous Jiejiebox installation -------------------------------------------
#
# The evidence: the service is `sing-box-daemon`, its binary is in an installation tree, and
# the marker this client writes into its own user-data directory is present.
$decision = Evaluate -ServiceExists $true -ImagePath $daemonImage -Marker $markerPresent -Volume $fixedVolume -ProductName $saysJiejiebox
Report "Case B: legacy Jiejiebox service with proof -> MAY REMOVE" $decision.CanRemove "image=$($decision.ImagePath)"

# The tree does NOT have to be the one being installed. A previous version installed to the
# pre-namespace directory and this one installs to its own, so requiring the new tree would
# refuse exactly the case cleanup exists for.
$decision = Evaluate -ServiceExists $true -ImagePath "C:\Program Files\sing-box\resources\daemon\sing-box-daemon.exe" -Marker $markerPresent -Volume $fixedVolume -ProductName $saysJiejiebox
Report "Case B2: legacy service in the OLD namespace tree -> MAY REMOVE" $decision.CanRemove "root=$($decision.Root)"

# --- Case C: incomplete evidence -> skip, and say why -----------------------------------
$decision = Evaluate -ServiceExists $false -ImagePath "" -Marker $markerPresent -Volume $fixedVolume -ProductName $saysJiejiebox
Report "Case C1: no service -> SKIP" (-not $decision.CanRemove) $decision.Reason

$decision = Evaluate -ServiceExists $true -ImagePath "" -Marker $markerPresent -Volume $fixedVolume -ProductName $saysJiejiebox
Report "Case C2: service with unreadable image -> SKIP" (-not $decision.CanRemove) $decision.Reason

$decision = Evaluate -ServiceExists $true -ImagePath "C:\Program Files\Other\thing.exe" -Marker $markerPresent -Volume $fixedVolume -ProductName $saysJiejiebox
Report "Case C3: service image is not a sing-box tree -> SKIP" (-not $decision.CanRemove) $decision.Reason

$decision = Evaluate -ServiceExists $true -ImagePath "C:\Program Files\sing-box\sing-box-daemon.exe" -Marker $markerPresent -Volume $fixedVolume -ProductName $saysJiejiebox
Report "Case C4: service image is not under resources\daemon -> SKIP" (-not $decision.CanRemove) $decision.Reason

$decision = Evaluate -ServiceExists $true -ImagePath $daemonImage -Marker $markerPresent -Volume $removableVolume -ProductName $saysJiejiebox
Report "Case C5: service on a non-fixed volume -> SKIP" (-not $decision.CanRemove) $decision.Reason

$decision = Evaluate -ServiceExists $true -ImagePath $daemonImage -Marker $markerAbsent -Volume $removableVolume -ProductName $saysJiejiebox
Report "Case C6: two signals missing -> SKIP" (-not $decision.CanRemove) $decision.Reason

# An empty legacy directory name means the proof path cannot be constructed at all, which is
# "cannot evaluate" and therefore skip - not "assume ours".
$decision = Evaluate -ServiceExists $true -ImagePath $daemonImage -Marker $markerPresent -Volume $fixedVolume -LegacyDirectoryName "" -ProductName $saysJiejiebox
Report "Case C7: no legacy directory to check -> SKIP" (-not $decision.CanRemove) $decision.Reason

# --- Case D: the proof is where the previous version ACTUALLY put it ---------------------
#
# The regression this covers: the decision used to look only in the per-user roaming profile
# ([Environment]::GetFolderPath(ApplicationData)). This client is per-machine, so a previous
# fork installation puts its marker in `%ProgramData%\<name>`, and the check found nothing on
# exactly the machine the cleanup exists for. The service was then never stopped, kept its log
# files open, and the installer's working-directory reset aborted the installation with code 30.
#
# These use the REAL filesystem rather than an injected signal, so the candidate paths are the
# ones production will build.
$realRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("legacy-ownership-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
try {
    # D1: the caller names the previous version's recorded application data directory.
    New-Item -ItemType Directory -Path $realRoot -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $realRoot ".access-control") -Value "" -NoNewline
    $realTree = "C:\Program Files\sing-box"
    $decision = Get-JiejieboxLegacyOwnershipDecision `
        -ServiceName "sing-box-daemon" `
        -ServiceExists $true `
        -ServiceImagePath "$realTree\resources\daemon\sing-box-daemon.exe" `
        -LegacyApplicationDataDirectoryName "sing-box" `
        -LegacyApplicationDataDirectory $realRoot `
        -GetProductName $saysJiejiebox `
        -TestFixedVolume { param($p) $true }
    Report "Case D1: proof at the recorded app data directory -> MAY REMOVE" $decision.CanRemove "proof=$($decision.ProofPath)"
    Report "Case D1: the proof path is the one that was searched" ($decision.ProofPath -eq (Join-Path $realRoot ".access-control")) $decision.ProofPath

    # D2: the machine-wide default is searched even when the caller names no directory, which is
    # the path a previous fork installation actually used.
    $commonApplicationData = [Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)
    $expectedCandidate = Join-Path (Join-Path $commonApplicationData "sing-box") ".access-control"
    $decision = Get-JiejieboxLegacyOwnershipDecision `
        -ServiceName "sing-box-daemon" `
        -ServiceExists $true `
        -ServiceImagePath "$realTree\resources\daemon\sing-box-daemon.exe" `
        -LegacyApplicationDataDirectoryName "sing-box" `
        -GetProductName $saysJiejiebox `
        -TestFixedVolume { param($p) $true }
    $searchedCommon = ($decision.Reason -like "*$expectedCandidate*") -or ($decision.ProofPath -eq $expectedCandidate)
    Report "Case D2: %ProgramData% is searched without a recorded directory" $searchedCommon "proof=$($decision.ProofPath)"
} finally {
    Remove-Item -LiteralPath $realRoot -Recurse -Force -ErrorAction SilentlyContinue
}

# --- Case E: the product name is the signal that separates the two clients -----------------
#
# The upstream client has the same service name, the same installation layout and the same marker
# file, so none of those could tell the two apart. It does NOT ship an executable that declares
# itself "Jiejiebox", and that is read from the tree the service points at.
#
# E1: the tree is ours but carries no marker -> still refuse. The product name is necessary, not a
# replacement for the proof.
$decision = Evaluate -ServiceExists $true -ImagePath $daemonImage -Marker $markerAbsent -Volume $fixedVolume -ProductName $saysJiejiebox
Report "Case E1: our tree, no marker -> MUST NOT DELETE" (-not $decision.CanRemove) $decision.Reason

# E2: a marker is present but the tree belongs to the other client -> refuse. This is the case that
# shipped and deleted the upstream client's service, because the marker alone was treated as proof.
$decision = Evaluate -ServiceExists $true -ImagePath $daemonImage -Marker $markerPresent -Volume $fixedVolume -ProductName $saysUpstream
Report "Case E2: upstream tree WITH our marker -> MUST NOT DELETE" (-not $decision.CanRemove) $decision.Reason

# E3: the executable declares nothing at all -> refuse. An unreadable identity is not ownership.
$decision = Evaluate -ServiceExists $true -ImagePath $daemonImage -Marker $markerPresent -Volume $fixedVolume -ProductName $saysNothing
Report "Case E3: tree declares no product name -> MUST NOT DELETE" (-not $decision.CanRemove) $decision.Reason

# --- The marker constant ----------------------------------------------------------------
#
# The proof is one specific file name, and it has to be the name this client actually writes.
# Pinning it here means a rename in userDataSecurity.ts fails a test rather than quietly
# disabling the cleanup (if the two ever diverged, cleanup would skip forever and look like
# "there was nothing to clean").
Report "ownership marker is .access-control" ($ownershipMarkerFileName -eq ".access-control") $ownershipMarkerFileName

# And the name has to match the one the runtime writes.
$securitySource = Join-Path $here "..\src\main\userDataSecurity.ts"
$securityText = Get-Content -LiteralPath $securitySource -Raw
Report "userDataSecurity.ts writes that exact marker" ($securityText -match 'join\(userDataPath, "\.access-control"\)') "source claims the same name"

Write-Host ""
Write-Host "legacy service ownership: $passed passed, $failed failed"
if ($failed -ne 0) { exit 1 }
exit 0
