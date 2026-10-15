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
        # Injected so the decision can be tested without a machine. Both default to the real
        # filesystem, and neither is called when an earlier signal has already failed.
        [scriptblock]$TestPath = { param($p) Test-Path -LiteralPath $p -PathType Leaf },
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

    $proofPath = ""
    if (-not [string]::IsNullOrWhiteSpace($LegacyApplicationDataDirectoryName)) {
        $profilesRoot = [Environment]::GetFolderPath([Environment+SpecialFolder]::ApplicationData)
        if (-not [string]::IsNullOrWhiteSpace($profilesRoot)) {
            $proofPath = Join-Path (Join-Path $profilesRoot $LegacyApplicationDataDirectoryName) `
                $ownershipMarkerFileName
        }
    }
    if ([string]::IsNullOrWhiteSpace($proofPath) -or -not (& $TestPath $proofPath)) {
        # Built with -f in one expression: a backtick-continued `-f` reads as a literal
        # operator on the next line and formats nothing, which is how this message first
        # rendered its own placeholder to the user.
        $missing = ("no Jiejiebox ownership proof at '{0}': a previous version of this fork " +
            "writes that marker and the upstream client does not, so the '{1}' service is not " +
            "provably ours") -f $proofPath, $ServiceName
        return [PSCustomObject]@{
            CanRemove = $false
            Reason    = $missing
            ImagePath = $image
            Root      = $root
            ProofPath = $proofPath
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
