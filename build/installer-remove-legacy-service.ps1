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

# The directory the previous version recorded as its application data directory, so the
# ownership proof is looked for where that version actually put its marker.
#
# This fork is per-machine: its application data directory is `%ProgramData%\<name>`, and the
# ownership proof is a marker inside it. The decision used to look only in the per-user roaming
# profile, found nothing on exactly the machine this cleanup exists for, and skipped - leaving
# the previous `sing-box-daemon` RUNNING, holding its log files open, so the installer's
# working-directory reset could not delete them and the installation aborted with code 30.
#
# # Two ways this read was broken, both silent
#
# 1. The path was unqualified (`SOFTWARE\SagerNet\sing-box`, no `HKLM:`). PowerShell resolves an
#    unqualified path against the session's CURRENT LOCATION, so this was a FILESYSTEM lookup:
#    the child the installer starts has `C:\Windows\System32` as its location, and the read
#    failed with "Cannot find path 'C:\Windows\System32\SOFTWARE\SagerNet\sing-box'". The
#    `catch {}` below hid it, so the recorded directory simply never existed in production.
#
#    This is invisible from a hand-run shell, because a shell whose location happens to be a
#    registry path lets the child inherit it and the read succeeds. Every earlier hand-run
#    "verified" this code and proved nothing.
#
# 2. The key lives in the 64-bit view of HKLM. The installer is a 32-bit process, so its
#    PowerShell child is 32-bit too and its default view is WOW6432Node. The view is therefore
#    requested explicitly, exactly as installer-preflight.ps1 does.
#
# An unreadable layout is not evidence of ownership; the decision keeps its own candidates.
$legacyApplicationDataDirectory = ""
try {
    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
        [Microsoft.Win32.RegistryHive]::LocalMachine,
        [Microsoft.Win32.RegistryView]::Registry64
    )
    try {
        $legacyLayout = $base.OpenSubKey($LegacyLayoutRegistryKey)
        if ($null -ne $legacyLayout) {
            $recorded = $legacyLayout.GetValue("ApplicationDataDirectory", "", [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            if (-not [string]::IsNullOrWhiteSpace($recorded)) {
                $legacyApplicationDataDirectory = [string]$recorded
            }
            $legacyLayout.Dispose()
        }
    } finally {
        $base.Dispose()
    }
} catch {
}

$decision = Get-JiejieboxLegacyOwnershipDecision `
    -ServiceName $serviceName `
    -ServiceExists ($null -ne $service) `
    -ServiceImagePath $imagePath `
    -LegacyApplicationDataDirectoryName $LegacyApplicationDataDirectoryName `
    -LegacyApplicationDataDirectory $legacyApplicationDataDirectory

if (-not $decision.CanRemove) {
    Write-Output "skipping legacy service cleanup: $($decision.Reason)"
    exit 0
}

Write-Output "Jiejiebox ownership proven for the '$serviceName' service:"
Write-Output "  image            $($decision.ImagePath)"
Write-Output "  installation     $($decision.Root)"
Write-Output "  marker           $($decision.ProofPath)"
if (-not [string]::IsNullOrWhiteSpace($LegacyLayoutRegistryKey)) {
    # Same two corrections as the read above: an explicit hive and an explicit 64-bit view. The
    # unqualified form resolved against the filesystem and always reported nothing here.
    $reportedLayout = $null
    try {
        $reportedBase = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
            [Microsoft.Win32.RegistryHive]::LocalMachine,
            [Microsoft.Win32.RegistryView]::Registry64
        )
        try {
            $reportedLayout = $reportedBase.OpenSubKey($LegacyLayoutRegistryKey)
            if ($null -ne $reportedLayout) {
                Write-Output "  previous layout  HKLM:\$LegacyLayoutRegistryKey (LayoutVersion $($reportedLayout.GetValue('LayoutVersion')))"
            }
        } finally {
            if ($null -ne $reportedLayout) { $reportedLayout.Dispose() }
            $reportedBase.Dispose()
        }
    } catch {
    }
}

if ($service.State -ne "Stopped") {
    Stop-Service -Name $serviceName -Force -ErrorAction Stop
}

# `sc.exe delete` rather than the service manager API: it is the same call the installer's own
# cleanup steps use, and it reports "marked for deletion" the ordinary way when the service
# still has an open handle.
#
# `& $sc`, not `& $sc.exe`. PowerShell reads the latter as "invoke the `exe` PROPERTY of $sc"
# rather than the string, fails with "The expression after '&' in a pipeline element produced an
# object that was not valid", and - under this script's $ErrorActionPreference = "Stop" - ends
# the script with exit 1 BEFORE the service is deleted. The cleanup therefore reported failure,
# left the service registered, and left it starting automatically on every boot.
$sc = Join-Path $env:SystemRoot "System32\sc.exe"
& $sc delete $serviceName | Out-Null
$serviceDeleted = $LASTEXITCODE -eq 0
if (-not $serviceDeleted) {
    Write-Output "sc.exe delete '$serviceName' exited $LASTEXITCODE"
} else {
    Write-Output "removed the previous version's '$serviceName' service"
}

# The event log source is removed only when the service actually went away.
#
# It used to be removed unconditionally, and that is the wrong way round: a failed `sc.exe delete`
# (a "marked for deletion" service, an open handle, a denied delete) left the service REGISTERED
# while its event log source was taken out from under it, so the service kept starting and its
# errors went nowhere. An inert leftover source is recoverable; a registered service with no source
# is a worse state than either half on its own.
#
# A source that cannot be removed is still not a failure: it is keyed by name under
# HKLM\SYSTEM\CurrentControlSet\Services\EventLog\Application, removing it needs the elevation this
# installer already has, and a leftover source is inert.
if (-not $serviceDeleted) {
    Write-Output "leaving the '$serviceName' event log source in place: its service is still registered"
} else {
    try {
        $eventLogKey = "HKLM:\SYSTEM\CurrentControlSet\Services\EventLog\Application\$serviceName"
        if (Test-Path -LiteralPath $eventLogKey) {
            Remove-Item -LiteralPath $eventLogKey -Recurse -Force -ErrorAction Stop
            Write-Output "removed the previous version's '$serviceName' event log source"
        }
    } catch {
        Write-Output "could not remove the '$serviceName' event log source: $($_.Exception.Message)"
    }
}

exit 0
