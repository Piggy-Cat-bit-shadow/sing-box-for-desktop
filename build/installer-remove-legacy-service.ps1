param(
    [Parameter(Mandatory = $true)][string]$LegacyLayoutRegistryKey,
    [Parameter(Mandatory = $true)][string]$LegacyApplicationDataDirectoryName
)

# Removes the daemon service a PREVIOUS version of this fork registered under the upstream
# name, when this installer is replacing that version.
#
# # Why this is needed at all
#
# Until this fork took its own daemon identity, `service install` created a service called
# `sing-box-daemon` - the same name the upstream client's daemon uses. The daemon now
# registers `jiejiebox-daemon`, so `service uninstall` removes only that one, and the old
# service is left behind pointing at `<tree>\resources\daemon\sing-box-daemon.exe`.
#
# That left-behind service is not cosmetic: it starts automatically, its binary is re-signed
# on every release so Windows cannot start it after an upgrade, and its recovery actions
# retry forever. But that is the SECOND problem. The first is that deleting a service named
# `sing-box-daemon` on a machine that also has the UPSTREAM client installed would delete
# THAT client's service.
#
# # What decides, and why the obvious guard was wrong
#
# The decision lives in installer-legacy-service-ownership.ps1, which is separate so it can be
# tested without a service, a volume or an installation - see
# scripts/test-legacy-service-ownership.ps1. Read it for the signals.
#
# The short version of the correction: the first version of this used
# `HKLM\SOFTWARE\SagerNet\sing-box` as "the key only the old fork wrote". The upstream client
# carries a `build/installer.nsh` too, and the fork's installer.nsh is derived from it, so
# upstream writes the same key. The ownership proof is the marker this client writes into its
# own user-data directory (`secureApplicationUserData`) and upstream does not.
#
# # Fail closed
#
# Every signal must hold. If any cannot be evaluated the script reports the reason and does
# nothing. A leftover service is recoverable by hand and by a later release; a service deleted
# from another product is not.
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "installer-legacy-service-ownership.ps1")

$serviceName = "sing-box-daemon"

$service = Get-CimInstance -ClassName Win32_Service -Filter "Name='$serviceName'" -ErrorAction SilentlyContinue
$imagePath = ""
if ($null -ne $service -and -not [string]::IsNullOrWhiteSpace($service.PathName)) {
    $commandLine = ([string]$service.PathName).Trim()
    if ($commandLine.StartsWith('"')) {
        $end = $commandLine.IndexOf('"', 1)
        if ($end -gt 1) { $imagePath = $commandLine.Substring(1, $end - 1) }
    } else {
        $imagePath = ($commandLine -split ' ')[0]
    }
}

$decision = Get-JiejieboxLegacyOwnershipDecision `
    -ServiceName $serviceName `
    -ServiceExists ($null -ne $service) `
    -ServiceImagePath $imagePath `
    -LegacyApplicationDataDirectoryName $LegacyApplicationDataDirectoryName

if (-not $decision.CanRemove) {
    Write-Output "skipping legacy service cleanup: $($decision.Reason)"
    exit 0
}

Write-Output "Jiejiebox ownership proven for the '$serviceName' service:"
Write-Output "  image            $($decision.ImagePath)"
Write-Output "  installation     $($decision.Root)"
Write-Output "  marker           $($decision.ProofPath)"
if (-not [string]::IsNullOrWhiteSpace($LegacyLayoutRegistryKey)) {
    $layoutKey = Get-ItemProperty -Path $LegacyLayoutRegistryKey -ErrorAction SilentlyContinue
    if ($null -ne $layoutKey) {
        Write-Output "  previous layout  $LegacyLayoutRegistryKey (LayoutVersion $($layoutKey.LayoutVersion))"
    }
}

if ($service.State -ne "Stopped") {
    Stop-Service -Name $serviceName -Force -ErrorAction Stop
}

# `sc.exe delete` rather than the service manager API: it is the same call the installer's own
# cleanup steps use, and it reports "marked for deletion" the ordinary way when the service
# still has an open handle.
$sc = Join-Path $env:SystemRoot "System32\sc.exe"
& $sc.exe delete $serviceName | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Output "sc.exe delete '$serviceName' exited $LASTEXITCODE"
} else {
    Write-Output "removed the previous version's '$serviceName' service"
}

# The event log source went with it. A source that cannot be removed is not a failure: it is
# keyed by name under HKLM\SYSTEM\CurrentControlSet\Services\EventLog\Application, removing it
# needs the elevation this installer already has, and a leftover source is inert.
try {
    $eventLogKey = "HKLM:\SYSTEM\CurrentControlSet\Services\EventLog\Application\$serviceName"
    if (Test-Path -LiteralPath $eventLogKey) {
        Remove-Item -LiteralPath $eventLogKey -Recurse -Force -ErrorAction Stop
        Write-Output "removed the previous version's '$serviceName' event log source"
    }
} catch {
    Write-Output "could not remove the '$serviceName' event log source: $($_.Exception.Message)"
}

exit 0
