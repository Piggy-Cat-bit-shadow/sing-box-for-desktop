param(
    [Parameter(Mandatory = $true)][string]$ServiceName,
    [Parameter(Mandatory = $true)][string]$InstallationDirectory
)

# Stops this installation's daemon service before its files are replaced.
#
# # Why this is not an inline -Command
#
# It used to be, and the guard below needs a quoted comparison and a path API, which inside
# an NSIS string literal becomes unreadable and unverifiable. A file also gets syntax
# checked, whereas a typo in a one-liner is discovered by an installer that silently did
# nothing.
#
# # Why the guard exists at all
#
# The service name is a machine-wide key, so "stop the service called <name>" is only correct
# if that service belongs to THIS installation. Before this client had its own service
# identity it shared the upstream client's name, and the unguarded form would have stopped -
# and, on the next step, replaced the binary of - a service belonging to a different product
# installed elsewhere. A service whose command line lives outside this installation tree is
# therefore left completely alone, and the install continues.
#
# This is a pre-upgrade step, so failing to stop the service must fail the install: the
# daemon binary about to be overwritten would otherwise stay running from a file the
# installer cannot replace.
$ErrorActionPreference = "Stop"

$service = Get-CimInstance -ClassName Win32_Service -Filter "Name='$ServiceName'" -ErrorAction SilentlyContinue
if ($null -eq $service) {
    Write-Output "service '$ServiceName' is not installed"
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
    Write-Output "service '$ServiceName' belongs to another installation ($imagePath); leaving it running"
    exit 0
}

if ($service.State -ne "Stopped") {
    Stop-Service -Name $ServiceName -Force -ErrorAction Stop
}
(Get-Service -Name $ServiceName).WaitForStatus(
    [System.ServiceProcess.ServiceControllerStatus]::Stopped,
    [TimeSpan]::FromSeconds(10)
)
Write-Output "service '$ServiceName' stopped"
exit 0
