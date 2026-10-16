# The ownership decision behind installer-remove-legacy-service.ps1, with every signal that
# comes from the machine replaced by a parameter.
#
# # Why it is a separate file
#
# The decision is the part that must never be wrong: deleting a service named
# `sing-box-daemon` on a machine that also has the upstream client installed would delete
# THAT client's service. Testing it therefore cannot require a service, a volume or an
# installation - it requires being able to say "here is a service that looks like X, is the
# answer delete or not". The caller supplies all of the evidence; this file only judges.
#
# # The signals
#
#   ServiceExists            the SCM has a `sing-box-daemon` service at all
#   HasImagePath             its PathName is readable
#   LooksLikeSingBoxTree     <root>\resources\daemon\sing-box-daemon.exe, which is the layout
#                            experimental/boxdd requires from any installation of this daemon
#   OnFixedVolume            that root is on a fixed local volume, like the security model
#                            already requires of installations
#   HasOwnershipMarker       <legacy app data>\<.access-control> exists. This is the proof:
#                            the file is written by this client's secureApplicationUserData on
#                            every packaged Windows launch, and by no version of the upstream
#                            client.
#
# # Why the marker and not the registry key
#
# The first version of this used `HKLM\SOFTWARE\SagerNet\sing-box` as "the key only the old
# fork wrote". That was wrong: the upstream client carries a `build/installer.nsh` too, and
# the fork's installer.nsh is derived from it, so upstream writes the same key.
#
# # Fail closed
#
# Every signal must hold. The evaluator returns the reason along with the decision, and the
# caller reports it - a machine where cleanup was skipped should say why.

$ownershipMarkerFileName = ".access-control"

function Get-JiejieboxLegacyOwnershipDecision {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ServiceName,
        [Parameter(Mandatory = $true)][bool]$ServiceExists,
        [AllowEmptyString()][string]$ServiceImagePath,
        [AllowEmptyString()][string]$LegacyApplicationDataDirectoryName,
        # The directory the previous version actually recorded as its application data
        # directory, when the caller can read it. See the candidate list below for why the
        # directory NAME alone is not enough.
        [AllowEmptyString()][string]$LegacyApplicationDataDirectory = "",
        # Injected so the decision can be tested without a machine. Both default to the real
        # filesystem, and neither is called when an earlier signal has already failed.
        [scriptblock]$TestPath = { param($p) Test-Path -LiteralPath $p -PathType Leaf },
        # Reads the product identity out of an installed executable's version resources. Injected so
        # the decision can be tested without real binaries; the default reads the real file.
        [scriptblock]$GetProductName = {
            param($p)
            try {
                if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { return "" }
                return [string](Get-Item -LiteralPath $p).VersionInfo.ProductName
            } catch { return "" }
        },
        [scriptblock]$TestFixedVolume = {
            param($p)
            try {
                $root = [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($p))
                if ([string]::IsNullOrWhiteSpace($root)) { return $false }
                return [System.IO.DriveInfo]::new($root).DriveType -eq [System.IO.DriveType]::Fixed
            } catch { return $false }
        }
    )

    if (-not $ServiceExists) {
        return [PSCustomObject]@{
            CanRemove = $false
            Reason    = "no '$ServiceName' service is registered"
            ImagePath = ""
            Root      = ""
            ProofPath = ""
        }
    }
    if ([string]::IsNullOrWhiteSpace($ServiceImagePath)) {
        return [PSCustomObject]@{
            CanRemove = $false
            Reason    = "the '$ServiceName' service has no readable image path"
            ImagePath = ""
            Root      = ""
            ProofPath = ""
        }
    }

    $image = $null
    try {
        $image = [System.IO.Path]::GetFullPath($ServiceImagePath)
    } catch {
        return [PSCustomObject]@{
            CanRemove = $false
            Reason    = "the '$ServiceName' service image path is invalid ($ServiceImagePath)"
            ImagePath = ""
            Root      = ""
            ProofPath = ""
        }
    }

    $imageDirectory = [System.IO.Path]::GetDirectoryName($image)
    $resourcesDirectory = [System.IO.Path]::GetDirectoryName($imageDirectory)
    $root = [System.IO.Path]::GetDirectoryName($resourcesDirectory)
    # A shape check, and deliberately not "it must be under the tree being installed": a
    # previous version of this fork installed to the pre-namespace directory and the new one
    # installs to its own, so requiring the NEW tree would refuse exactly the case this exists
    # for.
    if ([string]::IsNullOrWhiteSpace($root) -or
        [System.IO.Path]::GetFileName($image) -ine "sing-box-daemon.exe" -or
        [System.IO.Path]::GetFileName($imageDirectory) -ine "daemon" -or
        [System.IO.Path]::GetFileName($resourcesDirectory) -ine "resources") {
        return [PSCustomObject]@{
            CanRemove = $false
            Reason    = "the '$ServiceName' service image is not in a sing-box installation layout ($image)"
            ImagePath = $image
            Root      = ""
            ProofPath = ""
        }
    }

    if (-not (& $TestFixedVolume $root)) {
        return [PSCustomObject]@{
            CanRemove = $false
            Reason    = "the '$ServiceName' service lives on a non-fixed volume ($root)"
            ImagePath = $image
            Root      = $root
            ProofPath = ""
        }
    }

    # # Why the proof is looked for in several places
    #
    # The marker has to be checked where the previous version actually PUT its application data,
    # and this fork does not use the per-user roaming directory that
    # [Environment]::GetFolderPath(ApplicationData) returns. It is a per-machine client: its
    # application data directory is `%ProgramData%\<name>`, chosen in customInit and recorded in
    # its layout key. Checking only the roaming profile therefore found nothing on exactly the
    # machine this cleanup exists for - a previous fork installation - and the service was never
    # stopped or removed.
    #
    # That is not a cosmetic miss. The leftover `sing-box-daemon` keeps running, holds its own
    # log files open under the daemon data directory, and the installer's working-directory
    # reset then fails to delete them and aborts with "Could not reset the sing-box service data
    # directory (code 30)". One wrong directory turned into a failed installation.
    #
    # The marker is still the proof and nothing else is: every candidate is only a place to LOOK
    # for it, and the upstream client writes no such file anywhere.
    $candidateProofPaths = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($LegacyApplicationDataDirectory)) {
        $candidateProofPaths.Add((Join-Path $LegacyApplicationDataDirectory $ownershipMarkerFileName))
    }
    if (-not [string]::IsNullOrWhiteSpace($LegacyApplicationDataDirectoryName)) {
        $commonApplicationData = [Environment]::GetFolderPath(
            [Environment+SpecialFolder]::CommonApplicationData
        )
        if (-not [string]::IsNullOrWhiteSpace($commonApplicationData)) {
            $candidateProofPaths.Add((Join-Path (Join-Path $commonApplicationData $LegacyApplicationDataDirectoryName) $ownershipMarkerFileName))
        }
        $profilesRoot = [Environment]::GetFolderPath([Environment+SpecialFolder]::ApplicationData)
        if (-not [string]::IsNullOrWhiteSpace($profilesRoot)) {
            $candidateProofPaths.Add((Join-Path (Join-Path $profilesRoot $LegacyApplicationDataDirectoryName) $ownershipMarkerFileName))
        }
    }

    # # The signal that actually separates the two clients
    #
    # Everything above is a SHAPE check, and the upstream client has the same shape: same service
    # name, same `resources\daemon\sing-box-daemon.exe` layout, same marker file in a shared
    # application data directory. That was measured, not assumed - the upstream client writes
    # `.access-control` too, and `HKLM\SOFTWARE\SagerNet\sing-box` carries an `InstallationID` for
    # both. So `HasOwnershipMarker` was NOT proof that the service was ours, and acting on it broke
    # the other product: this script reported the upstream client's own binary as proof and deleted
    # its service.
    #
    # The product name in the installed executable's version resources is not shared. This fork's
    # build stamps its own `sing-box.exe` with `ProductName = "Jiejiebox"`; the upstream client's is
    # `"sing-box"`. It is read from the tree the SERVICE points at, so it describes the product that
    # actually owns the service, and it depends on nothing in the registry, on any user's profile,
    # or on which client installed last.
    #
    # The check is on the application executable, not on the daemon: neither client stamps a product
    # name onto `sing-box-daemon.exe`, so that file cannot answer the question.
    $applicationIdentifier = "Jiejiebox"
    $applicationExecutable = Join-Path $root "sing-box.exe"
    $productName = [string](& $GetProductName $applicationExecutable)
    if ($productName -ine $applicationIdentifier) {
        $detail = if ([string]::IsNullOrWhiteSpace($productName)) {
            "it declares no product name"
        } else {
            "it declares '$productName'"
        }
        return [PSCustomObject]@{
            CanRemove = $false
            Reason    = "the tree the '$ServiceName' service points at is not a Jiejiebox installation: $applicationExecutable $detail"
            ImagePath = $image
            Root      = $root
            ProofPath = ""
        }
    }

    $proofPath = ""
    foreach ($candidate in $candidateProofPaths) {
        if (& $TestPath $candidate) { $proofPath = $candidate; break }
    }
    if ([string]::IsNullOrWhiteSpace($proofPath)) {
        # Built with -f in one expression: a backtick-continued `-f` reads as a literal
        # operator on the next line and formats nothing, which is how this message first
        # rendered its own placeholder to the user.
        $checked = if ($candidateProofPaths.Count -eq 0) { "nothing" } else { $candidateProofPaths -join "', '" }
        # This used to claim "the upstream client does not" write the marker. That claim was false -
        # the upstream client writes the same file - which is why it is no longer made. The product
        # name above is what separates the two; this message covers the case where the tree IS ours
        # but carries no marker.
        $missing = ("no Jiejiebox ownership proof at '{0}': a previous version of this fork " +
            "writes that marker into its own application data directory, so the '{1}' service is " +
            "not provably ours") -f $checked, $ServiceName
        return [PSCustomObject]@{
            CanRemove = $false
            Reason    = $missing
            ImagePath = $image
            Root      = $root
            ProofPath = ""
        }
    }

    return [PSCustomObject]@{
        CanRemove = $true
        Reason    = "the '$ServiceName' service is a previous Jiejiebox installation"
        ImagePath = $image
        Root      = $root
        ProofPath = $proofPath
    }
}
