param(
    [Parameter(Mandatory = $true)][string]$LegacyLayoutRegistryKey,
    [Parameter(Mandatory = $true)][string]$InstallationDirectory
)

# Removes the daemon service a PREVIOUS version of this fork registered under the upstream
# name, when this installer is replacing that version.
#
# # Why this is needed at all
#
# Until this fork took its own daemon identity, `service install` created a service called
# `sing-box-daemon` - the same name the upstream client's daemon uses. The daemon now
# registers `jiejiebox-daemon`, so `service uninstall` removes only that one and the old
# service is left behind, still pointing at
# `<install>\resources\daemon\sing-box-daemon.exe`, which the upgrade has just replaced.
#
# That left-behind service is not cosmetic. It is configured for automatic start, and the
# binary it names is re-signed on every release, so Windows cannot start it after an
# upgrade: the SCM records a service that fails at every boot, retries through its recovery
# actions, and - because the old daemon authenticated its peers by signer - could never have
# worked against the new binaries anyway. `sc.exe query` finds it, and the next install's
# guard does not expect it.
#
# # Why the guard, and why this specific one
#
# `HKLM\SOFTWARE\SagerNet\sing-box` is the installation-layout key the pre-identity fork
# wrote, and the upstream client does not write it at all. So its presence means "the
# installation being replaced is one of OURS", and this step runs only then. The service
# name alone would have been the wrong guard: it is the name the upstream client's daemon
# uses, and deleting a service by name on a machine that also has the upstream client
# installed is exactly the accident this whole change exists to prevent.
#
# The installation-directory check is a second guard rather than a redundancy: a service
# whose binary lives outside the tree being installed is not this installation's, whatever
# the registry says, and is left alone.
$ErrorActionPreference = "Stop"

$legacyServiceName = "sing-box-daemon"

$layoutKey = Get-ItemProperty -Path $LegacyLayoutRegistryKey -ErrorAction SilentlyContinue
if ($null -eq $layoutKey) {
    Write-Output "no previous installation layout at $LegacyLayoutRegistryKey; nothing to remove"
    exit 0
}

$service = Get-CimInstance -ClassName Win32_Service -Filter "Name='$legacyServiceName'" -ErrorAction SilentlyContinue
if ($null -eq $service) {
    Write-Output "no '$legacyServiceName' service to remove"
    exit 0
}

$imagePath = $null
if (-not [string]::IsNullOrWhiteSpace($service.PathName)) {
    $commandLine = $service.PathName.Trim()
    if ($commandLine.StartsWith('"')) {
        $end = $commandLine.IndexOf('"', 1)
        if ($end -gt 1) { $imagePath = $commandLine.Substring(1, $end - 1) }
    } else {
        $imagePath = ($commandLine -split ' ')[0]
    }
}

$belongsToThisInstallation = $false
if (-not [string]::IsNullOrWhiteSpace($imagePath)) {
    try {
        $expectedRoot = [System.IO.Path]::GetFullPath($InstallationDirectory).TrimEnd("\")
        $actualDirectory = [System.IO.Path]::GetDirectoryName(
            [System.IO.Path]::GetFullPath($imagePath)
        ).TrimEnd("\")
        $belongsToThisInstallation = $actualDirectory.Equals(
            $expectedRoot,
            [System.StringComparison]::OrdinalIgnoreCase
        ) -or $actualDirectory.StartsWith(
            $expectedRoot + "\",
            [System.StringComparison]::OrdinalIgnoreCase
        )
    } catch {
        $belongsToThisInstallation = $false
    }
}

if (-not $belongsToThisInstallation) {
    Write-Output "the '$legacyServiceName' service belongs to another installation ($imagePath); leaving it alone"
    exit 0
}

if ($service.State -ne "Stopped") {
    Stop-Service -Name $legacyServiceName -Force -ErrorAction Stop
}

# `sc.exe delete` rather than the service manager API: it is the same call the installer's
# own cleanup steps use, and it reports "marked for deletion" the ordinary way when the
# service still has an open handle. The binary it named is about to be replaced either way,
# so a service left in that state is no more useful than one removed.
$sc = Join-Path $env:SystemRoot "System32\sc.exe"
& $sc.exe delete $legacyServiceName | Out-Null
$deleted = $LASTEXITCODE
if ($deleted -ne 0) {
    Write-Output "sc.exe delete '$legacyServiceName' exited $deleted"
} else {
    Write-Output "removed the previous version's '$legacyServiceName' service"
}

# The event log source went with it. A source that cannot be removed is not a failure: it is
# keyed by name under HKLM\SYSTEM\CurrentControlSet\Services\EventLog\Application, removing
# it needs the same elevation this installer already has, and a leftover source is inert.
try {
    $eventLogKey = "HKLM:\SYSTEM\CurrentControlSet\Services\EventLog\Application\$legacyServiceName"
    if (Test-Path -LiteralPath $eventLogKey) {
        Remove-Item -LiteralPath $eventLogKey -Recurse -Force -ErrorAction Stop
        Write-Output "removed the previous version's '$legacyServiceName' event log source"
    }
} catch {
    Write-Output "could not remove the '$legacyServiceName' event log source: $($_.Exception.Message)"
}

exit 0
