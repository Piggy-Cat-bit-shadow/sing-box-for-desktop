param(
    [Parameter(Mandatory = $true)][string]$InstallationDirectory,
    [string]$ApplicationDataDirectory,
    [string]$DaemonWorkingDirectory,
    [string]$InstallationID,
    [string]$ResultOutputPath,
    [string]$ResultCodePath,
    [string]$ProcessIDPath,
    [switch]$AllowUnsafeInstallationDirectory,
    [Alias("RepairInstallationAncestors")][switch]$RepairPathAncestors,
    [switch]$ResetWorkingDirectory,
    [switch]$PrepareApplicationDataDirectory,
    # The installer has taken this application data directory over from a PREVIOUS release line,
    # so a non-empty directory is expected rather than refused. The evidence is re-checked below
    # (Test-LegacyLayoutNamesDirectory); this switch only says which question to ask.
    [switch]$Adopted,
    [switch]$DeleteDataDirectories
)

$ErrorActionPreference = "Stop"
$reparsePoint = [System.IO.FileAttributes]::ReparsePoint

# The daemon's service name.
#
# It is a machine-wide key, and the service SID checked below is DERIVED from it (SHA-1 over
# the upper-cased UTF-16 name, see experimental/boxdd/security_windows.go). Checking the ACL
# against another client's SID would not fail loudly - it would report "the daemon working
# directory is missing a required access control entry" on a correct installation, or accept
# an ACL that this daemon cannot write to.
#
# This literal, experimental/boxdd's `serviceName` and build/installer.nsh's
# DEFINE_SERVICE_NAME are the same value; scripts/ci/verify-desktop-identity-consistency.py
# in the parent repository is what keeps the three of them together.
$daemonServiceName = "jiejiebox-daemon"

$trustedInstallationIdentities = @(
    "S-1-5-18",
    "S-1-5-32-544",
    "S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464"
)
$dangerousInstallationAccess = [uint32]0x500D0040

function Write-InstallerOutput([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($ResultOutputPath)) {
        Write-Output $Value
        return
    }
    [System.IO.File]::WriteAllText(
        $ResultOutputPath,
        $Value,
        [System.Text.Encoding]::Unicode
    )
}

function Exit-Installer([int]$Code) {
    if (-not [string]::IsNullOrWhiteSpace($ResultCodePath)) {
        [System.IO.File]::WriteAllText(
            $ResultCodePath,
            [string]$Code,
            [System.Text.Encoding]::ASCII
        )
    }
    exit $Code
}

if (-not [string]::IsNullOrWhiteSpace($ProcessIDPath)) {
    [System.IO.File]::WriteAllText(
        $ProcessIDPath,
        [string]$PID,
        [System.Text.Encoding]::ASCII
    )
}

Add-Type -TypeDefinition @'
using Microsoft.Win32.SafeHandles;
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

namespace Box.Installer
{
    public static class DirectoryAccessControl
    {
        private const uint MaximumAllowed = 0x02000000;
        private const uint ShareRead = 0x00000001;
        private const uint ShareWrite = 0x00000002;
        private const uint ShareDelete = 0x00000004;
        private const uint OpenExisting = 3;
        private const uint CreateAlways = 2;
        private const uint GenericRead = 0x80000000;
        private const uint GenericWrite = 0x40000000;
        private const uint OpenReparsePoint = 0x00200000;
        private const uint BackupSemantics = 0x02000000;
        private const int FileObject = 1;
        private const uint DiscretionaryAccessControlListSecurityInformation = 0x00000004;

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern SafeFileHandle CreateFile(
            string fileName,
            uint desiredAccess,
            uint shareMode,
            IntPtr securityAttributes,
            uint creationDisposition,
            uint flagsAndAttributes,
            IntPtr templateFile
        );

        [DllImport("advapi32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetSecurityDescriptorDacl(
            IntPtr securityDescriptor,
            [MarshalAs(UnmanagedType.Bool)] out bool discretionaryAccessControlListPresent,
            out IntPtr discretionaryAccessControlList,
            [MarshalAs(UnmanagedType.Bool)] out bool discretionaryAccessControlListDefaulted
        );

        [DllImport("advapi32.dll")]
        private static extern uint SetSecurityInfo(
            SafeFileHandle handle,
            int objectType,
            uint securityInformation,
            IntPtr owner,
            IntPtr group,
            IntPtr discretionaryAccessControlList,
            IntPtr systemAccessControlList
        );

        public static void SetCurrentDirectoryAccessControl(string path, byte[] securityDescriptor)
        {
            using (SafeFileHandle handle = CreateFile(
                path,
                MaximumAllowed,
                ShareRead | ShareWrite | ShareDelete,
                IntPtr.Zero,
                OpenExisting,
                OpenReparsePoint | BackupSemantics,
                IntPtr.Zero
            ))
            {
                if (handle.IsInvalid)
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                }
                IntPtr descriptor = Marshal.AllocHGlobal(securityDescriptor.Length);
                try
                {
                    Marshal.Copy(securityDescriptor, 0, descriptor, securityDescriptor.Length);
                    bool accessControlListPresent;
                    bool accessControlListDefaulted;
                    IntPtr accessControlList;
                    if (!GetSecurityDescriptorDacl(
                        descriptor,
                        out accessControlListPresent,
                        out accessControlList,
                        out accessControlListDefaulted
                    ))
                    {
                        throw new Win32Exception(Marshal.GetLastWin32Error());
                    }
                    if (!accessControlListPresent || accessControlList == IntPtr.Zero)
                    {
                        throw new InvalidOperationException("The directory has an empty access control list.");
                    }
                    uint result = SetSecurityInfo(
                        handle,
                        FileObject,
                        DiscretionaryAccessControlListSecurityInformation,
                        IntPtr.Zero,
                        IntPtr.Zero,
                        accessControlList,
                        IntPtr.Zero
                    );
                    if (result != 0)
                    {
                        throw new Win32Exception((int)result);
                    }
                }
                finally
                {
                    Marshal.FreeHGlobal(descriptor);
                }
            }
        }

        public static string ReadDirectoryMarker(string path)
        {
            SafeFileHandle handle = CreateFile(
                path + ":jiejiebox.installation-id",
                GenericRead,
                ShareRead | ShareWrite | ShareDelete,
                IntPtr.Zero,
                OpenExisting,
                BackupSemantics,
                IntPtr.Zero
            );
            if (handle.IsInvalid)
            {
                int error = Marshal.GetLastWin32Error();
                handle.Dispose();
                if (error == 2 || error == 3)
                {
                    return null;
                }
                throw new Win32Exception(error);
            }
            using (FileStream stream = new FileStream(handle, FileAccess.Read))
            using (StreamReader reader = new StreamReader(stream, Encoding.UTF8, false))
            {
                return reader.ReadToEnd();
            }
        }

        public static void WriteDirectoryMarker(string path, string value)
        {
            SafeFileHandle handle = CreateFile(
                path + ":jiejiebox.installation-id",
                GenericWrite,
                ShareRead,
                IntPtr.Zero,
                CreateAlways,
                BackupSemantics,
                IntPtr.Zero
            );
            if (handle.IsInvalid)
            {
                int error = Marshal.GetLastWin32Error();
                handle.Dispose();
                throw new Win32Exception(error);
            }
            using (FileStream stream = new FileStream(handle, FileAccess.Write))
            using (StreamWriter writer = new StreamWriter(stream, new UTF8Encoding(false)))
            {
                writer.Write(value);
            }
        }
    }

    public static class InstallationVolume
    {
        public const uint FixedDrive = 3;

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetVolumePathName(
            string fileName,
            StringBuilder volumePathName,
            int bufferLength
        );

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
        private static extern uint GetDriveType(string rootPathName);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern uint QueryDosDevice(
            string deviceName,
            StringBuilder targetPath,
            int maximumLength
        );

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetVolumeInformation(
            string rootPathName,
            StringBuilder volumeNameBuffer,
            int volumeNameSize,
            out uint volumeSerialNumber,
            out uint maximumComponentLength,
            out uint fileSystemFlags,
            StringBuilder fileSystemNameBuffer,
            int fileSystemNameSize
        );

        public static string ResolveVolumePath(string path)
        {
            StringBuilder volumePath = new StringBuilder(32768);
            if (!GetVolumePathName(path, volumePath, volumePath.Capacity))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            string resolvedVolumePath = volumePath.ToString();
            if (ResolveSubstitutedVolumePath(resolvedVolumePath) != null)
            {
                return Path.GetPathRoot(resolvedVolumePath);
            }
            return resolvedVolumePath;
        }

        public static uint ResolveDriveType(string volumePath)
        {
            return GetDriveType(volumePath);
        }

        public static string ResolveFileSystemName(string volumePath)
        {
            StringBuilder fileSystemName = new StringBuilder(32);
            uint volumeSerialNumber;
            uint maximumComponentLength;
            uint fileSystemFlags;
            bool resolved = GetVolumeInformation(
                volumePath,
                null,
                0,
                out volumeSerialNumber,
                out maximumComponentLength,
                out fileSystemFlags,
                fileSystemName,
                fileSystemName.Capacity
            );
            if (!resolved)
            {
                string resolvedVolumePath = ResolveSubstitutedVolumePath(volumePath);
                if (resolvedVolumePath == null)
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                }
                resolved = GetVolumeInformation(
                    resolvedVolumePath,
                    null,
                    0,
                    out volumeSerialNumber,
                    out maximumComponentLength,
                    out fileSystemFlags,
                    fileSystemName,
                    fileSystemName.Capacity
                );
                if (!resolved)
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                }
            }
            return fileSystemName.ToString();
        }

        private static string ResolveSubstitutedVolumePath(string volumePath)
        {
            string rootPath = Path.GetPathRoot(volumePath);
            if (String.IsNullOrEmpty(rootPath))
            {
                return null;
            }
            string deviceName = rootPath.TrimEnd('\\');
            if (deviceName.Length != 2 || deviceName[1] != ':')
            {
                return null;
            }
            StringBuilder targetPath = new StringBuilder(32768);
            if (QueryDosDevice(deviceName, targetPath, targetPath.Capacity) == 0)
            {
                return null;
            }
            string resolvedPath = targetPath.ToString();
            if (!resolvedPath.StartsWith("\\??\\", StringComparison.OrdinalIgnoreCase))
            {
                return null;
            }
            string resolvedRootPath = Path.GetPathRoot(resolvedPath.Substring(4));
            if (String.IsNullOrEmpty(resolvedRootPath))
            {
                return null;
            }
            return resolvedRootPath;
        }
    }
}
'@

function Get-ExistingPath([string]$TargetPath) {
    $currentPath = [System.IO.Path]::GetFullPath($TargetPath)
    while (-not (Test-Path -LiteralPath $currentPath)) {
        $parentPath = [System.IO.Directory]::GetParent($currentPath)
        if ($null -eq $parentPath) {
            throw "The directory has no existing ancestor."
        }
        $currentPath = $parentPath.FullName
    }
    return $currentPath
}

function Get-InstallationAncestorPaths([string]$TargetPath, [string]$VolumeRoot) {
    $paths = [System.Collections.Generic.List[string]]::new()
    $currentPath = [System.IO.Directory]::GetParent(
        [System.IO.Path]::GetFullPath($TargetPath)
    ).FullName
    while (-not (Test-Path -LiteralPath $currentPath)) {
        $parentPath = [System.IO.Directory]::GetParent($currentPath)
        if ($null -eq $parentPath) {
            throw "The installation directory is outside its resolved volume."
        }
        $currentPath = $parentPath.FullName
    }
    $normalizedVolumeRoot = $VolumeRoot.TrimEnd("\")
    while ($true) {
        [void]$paths.Add($currentPath)
        if ([string]::Equals(
                $currentPath.TrimEnd("\"),
                $normalizedVolumeRoot,
                [System.StringComparison]::OrdinalIgnoreCase
            )) {
            break
        }
        $parentPath = [System.IO.Directory]::GetParent($currentPath)
        if ($null -eq $parentPath -or $parentPath.FullName -eq $currentPath) {
            throw "The installation directory is outside its resolved volume."
        }
        $currentPath = $parentPath.FullName
    }
    return $paths
}

function Test-PathOverlap([string]$FirstPath, [string]$SecondPath) {
    $first = [System.IO.Path]::GetFullPath($FirstPath).TrimEnd("\")
    $second = [System.IO.Path]::GetFullPath($SecondPath).TrimEnd("\")
    return $first.Equals($second, [System.StringComparison]::OrdinalIgnoreCase) -or
        $first.StartsWith($second + "\", [System.StringComparison]::OrdinalIgnoreCase) -or
        $second.StartsWith($first + "\", [System.StringComparison]::OrdinalIgnoreCase)
}

function Resolve-FixedNTFSVolume([string]$TargetPath) {
    $existingPath = Get-ExistingPath $TargetPath
    $volume = [Box.Installer.InstallationVolume]::ResolveVolumePath($existingPath)
    $driveType = [Box.Installer.InstallationVolume]::ResolveDriveType($volume)
    if ($driveType -ne [Box.Installer.InstallationVolume]::FixedDrive) {
        throw "The directory is not on a fixed local drive: $volume"
    }
    $fileSystem = [Box.Installer.InstallationVolume]::ResolveFileSystemName($volume)
    if (-not [string]::Equals(
            $fileSystem,
            "NTFS",
            [System.StringComparison]::OrdinalIgnoreCase
        )) {
        throw "The directory is not on NTFS: $fileSystem"
    }
    return $volume
}

function Get-RawDirectorySecurity([string]$Path) {
    $security = Get-Acl -LiteralPath $Path
    $binary = $security.GetSecurityDescriptorBinaryForm()
    return [System.Security.AccessControl.RawSecurityDescriptor]::new($binary, 0)
}

function Get-ServiceSid([string]$ServiceName) {
    $serviceNameBytes = [System.Text.Encoding]::Unicode.GetBytes($ServiceName.ToUpperInvariant())
    $hashAlgorithm = [System.Security.Cryptography.SHA1]::Create()
    try {
        $serviceNameHash = $hashAlgorithm.ComputeHash($serviceNameBytes)
    } finally {
        $hashAlgorithm.Dispose()
    }
    $subAuthorities = [System.Collections.Generic.List[uint32]]::new()
    for ($offset = 0; $offset -lt $serviceNameHash.Length; $offset += 4) {
        [void]$subAuthorities.Add([System.BitConverter]::ToUInt32($serviceNameHash, $offset))
    }
    return "S-1-5-80-$($subAuthorities -join '-')"
}

function Get-UnsafeInstallationAncestor([string[]]$Paths) {
    $repairableAncestor = $null
    foreach ($path in $Paths) {
        $item = Get-Item -LiteralPath $path -Force
        if (-not $item.PSIsContainer -or ($item.Attributes -band $reparsePoint)) {
            return [PSCustomObject]@{ Path = $path; ExitCode = 11 }
        }
        $security = Get-RawDirectorySecurity $path
        if ($null -eq $security.Owner -or $security.Owner.Value -notin $trustedInstallationIdentities) {
            return [PSCustomObject]@{ Path = $path; ExitCode = 12 }
        }
        if ($null -eq $security.DiscretionaryAcl) {
            return [PSCustomObject]@{ Path = $path; ExitCode = 12 }
        }
        foreach ($entry in $security.DiscretionaryAcl) {
            if ([int]$entry.AceType -ne [int][System.Security.AccessControl.AceType]::AccessAllowed -or
                (([int]$entry.AceFlags -band [int][System.Security.AccessControl.AceFlags]::InheritOnly) -ne 0) -or
                $entry.SecurityIdentifier.Value -in $trustedInstallationIdentities) {
                continue
            }
            $accessMask = [System.BitConverter]::ToUInt32(
                [System.BitConverter]::GetBytes([int]$entry.AccessMask),
                0
            )
            if (($accessMask -band $dangerousInstallationAccess) -ne 0) {
                if ($null -eq $repairableAncestor) {
                    $repairableAncestor = [PSCustomObject]@{ Path = $path; ExitCode = 13 }
                }
            }
        }
    }
    return $repairableAncestor
}

function Repair-PathAncestor([string]$Path) {
    $accessControl = Get-Acl -LiteralPath $Path
    $binary = $accessControl.GetSecurityDescriptorBinaryForm()
    $security = [System.Security.AccessControl.RawSecurityDescriptor]::new($binary, 0)
    $changed = $false
    for ($index = $security.DiscretionaryAcl.Count - 1; $index -ge 0; $index--) {
        $entry = $security.DiscretionaryAcl[$index]
        if ([int]$entry.AceType -ne [int][System.Security.AccessControl.AceType]::AccessAllowed -or
            (([int]$entry.AceFlags -band [int][System.Security.AccessControl.AceFlags]::InheritOnly) -ne 0) -or
            (([int]$entry.AceFlags -band [int][System.Security.AccessControl.AceFlags]::Inherited) -ne 0) -or
            $entry.SecurityIdentifier.Value -in $trustedInstallationIdentities) {
            continue
        }
        $accessMask = [System.BitConverter]::ToUInt32(
            [System.BitConverter]::GetBytes([int]$entry.AccessMask),
            0
        )
        if (($accessMask -band $dangerousInstallationAccess) -eq 0) {
            continue
        }
        $safeAccessMask = $accessMask -band (-bnot $dangerousInstallationAccess)
        if ($safeAccessMask -eq 0) {
            $security.DiscretionaryAcl.RemoveAce($index)
        } else {
            $entry.AccessMask = [System.BitConverter]::ToInt32(
                [System.BitConverter]::GetBytes([uint32]$safeAccessMask),
                0
            )
        }
        $changed = $true
    }
    if (-not $changed) {
        return
    }
    $updatedBinary = [byte[]]::new($security.BinaryLength)
    $security.GetBinaryForm($updatedBinary, 0)
    $accessControl.SetSecurityDescriptorBinaryForm(
        $updatedBinary,
        [System.Security.AccessControl.AccessControlSections]::Access
    )
    [Box.Installer.DirectoryAccessControl]::SetCurrentDirectoryAccessControl(
        $Path,
        $updatedBinary
    )
}

function Repair-PathAncestorPermissions([string[]]$Paths) {
    [array]::Reverse($Paths)
    foreach ($path in $Paths) {
        Repair-PathAncestor $path
    }
    [array]::Reverse($Paths)
}

function Remove-WorkingDirectoryTree([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.Attributes -band $reparsePoint) {
        if ($item.PSIsContainer) {
            [System.IO.Directory]::Delete($item.FullName)
        } else {
            [System.IO.File]::Delete($item.FullName)
        }
        return
    }
    if (-not $item.PSIsContainer) {
        [System.IO.File]::Delete($item.FullName)
        return
    }
    foreach ($child in Get-ChildItem -LiteralPath $item.FullName -Force) {
        Remove-WorkingDirectoryTree $child.FullName
    }
    [System.IO.Directory]::Delete($item.FullName)
}

# Brings an existing daemon working directory up to the protection the daemon itself creates it
# with, instead of aborting the installation over it.
#
# # Why this exists
#
# The blocks below require the daemon working directory to be owned by SYSTEM, to have inheritance
# disabled, and to carry exactly SYSTEM, Administrators and the daemon's service SID. These are
# the properties experimental/boxdd's `ensureWindowsWorkingDirectory` creates the directory with,
# from the descriptor `D:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;FA;;;<service SID>)`.
#
# The daemon REPAIRS a directory that does not match - `validateRepairableWindowsWorkingDirectory`
# then `secureWindowsWorkingDirectoryRoot` - so an existing directory with an ordinary inherited
# ACL is a normal arrangement that resolves itself the first time the service starts.
#
# The installer could not get that far. It validated strictly, found the directory owned by
# BUILTIN\Administrators (which is what [System.IO.Directory]::CreateDirectory inherits from
# %ProgramData%, and what the previous release line left behind), and stopped with exit 21 - before
# any application file was installed and before the daemon that would have repaired it could ever
# run. The only repair the preflight had was `-ResetWorkingDirectory`, which DELETES the directory,
# and which the install path never reaches: the preflight runs before the installation exists.
#
# So the installer now applies the same protection the daemon would, and the daemon's own check
# still runs afterwards - it validates the result independently, and will stop with an error if
# this did not produce something it can use.
function Set-DaemonWorkingDirectoryAccessControl([string]$Path) {
    $system = [System.Security.Principal.SecurityIdentifier]::new("S-1-5-18")
    $administrators = [System.Security.Principal.SecurityIdentifier]::new("S-1-5-32-544")
    $service = [System.Security.Principal.SecurityIdentifier]::new((Get-ServiceSid $daemonServiceName))

    # The owner is set with icacls rather than through DirectorySecurity.SetOwner: taking ownership
    # is a privilege operation, and Set-Acl cannot express it for an identity that is not already
    # the caller. icacls is the same tool the application data directory's own protection uses.
    & "$env:SystemRoot\System32\icacls.exe" $Path /setowner "*S-1-5-18" /Q | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Could not set the daemon working directory owner: $LASTEXITCODE"
    }

    $inheritance = [System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
        [System.Security.AccessControl.InheritanceFlags]::ObjectInherit
    $accessControl = [System.Security.AccessControl.DirectorySecurity]::new()
    # A fresh DirectorySecurity carries no owner. It is read back from the directory after icacls
    # has taken it, so the block below does not undo it.
    $accessControl.SetOwner((Get-Acl -LiteralPath $Path).GetOwner([System.Security.Principal.SecurityIdentifier]))
    $accessControl.SetAccessRuleProtection($true, $false)
    foreach ($identity in @($system, $administrators, $service)) {
        $rule = [System.Security.AccessControl.FileSystemAccessRule]::new(
            $identity,
            [System.Security.AccessControl.FileSystemRights]::FullControl,
            $inheritance,
            [System.Security.AccessControl.PropagationFlags]::None,
            [System.Security.AccessControl.AccessControlType]::Allow
        )
        [void]$accessControl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $Path -AclObject $accessControl
}

function Set-ApplicationDataDirectoryAccessControl([string]$Path) {
    $system = [System.Security.Principal.SecurityIdentifier]::new("S-1-5-18")
    $administrators = [System.Security.Principal.SecurityIdentifier]::new("S-1-5-32-544")
    $authenticatedUsers = [System.Security.Principal.SecurityIdentifier]::new("S-1-5-11")
    & "$env:SystemRoot\System32\icacls.exe" $Path /setowner "*S-1-5-32-544" /Q | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Could not set the application data directory owner: $LASTEXITCODE"
    }
    $accessControl = [System.Security.AccessControl.DirectorySecurity]::new()
    $accessControl.SetOwner($administrators)
    $accessControl.SetAccessRuleProtection($true, $false)
    $inheritance = [System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
        [System.Security.AccessControl.InheritanceFlags]::ObjectInherit
    foreach ($identity in @($system, $administrators, $authenticatedUsers)) {
        $rule = [System.Security.AccessControl.FileSystemAccessRule]::new(
            $identity,
            [System.Security.AccessControl.FileSystemRights]::FullControl,
            $inheritance,
            [System.Security.AccessControl.PropagationFlags]::None,
            [System.Security.AccessControl.AccessControlType]::Allow
        )
        [void]$accessControl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $Path -AclObject $accessControl
}

# Did a PREVIOUS release line record THIS directory as its application data directory?
#
# `SOFTWARE\SagerNet\sing-box` is shared with the upstream client, so this is deliberately narrow
# and is only consulted when this installation has no layout of its own - that is, when the
# directory is pre-existing and is about to be treated as a stranger's. It answers one question:
# can the directory be re-owned instead of refused?
#
# It requires the legacy record to name this exact directory AND to carry an InstallationID,
# which is the fork's own addition to the layout and not something the upstream client writes.
function Test-LegacyLayoutNamesDirectory([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey("SOFTWARE\SagerNet\sing-box")
    if ($null -eq $key) { return $false }
    try {
        $declared = $key.GetValue("ApplicationDataDirectory", "", [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        $identifier = $key.GetValue("InstallationID", "", [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        if ([string]::IsNullOrWhiteSpace($declared) -or [string]::IsNullOrWhiteSpace($identifier)) { return $false }
        # Test-PathOverlap, not a path-equality helper: it is the one already in this file, and it
        # answers "is this the same directory" with GetFullPath + TrimEnd + OrdinalIgnoreCase, which
        # is the comparison a registry value written by an installer needs.
        if (-not (Test-PathOverlap $declared $Path)) { return $false }
        return $true
    } finally {
        $key.Dispose()
    }
}

function Initialize-ApplicationDataDirectory([string]$Path, [string]$ID, [switch]$Adopted) {
    if ([string]::IsNullOrWhiteSpace($ID)) {
        throw "The installation ID is missing."
    }
    if (Test-Path -LiteralPath $Path) {
        $item = Get-Item -LiteralPath $Path -Force
        if (-not $item.PSIsContainer -or ($item.Attributes -band $reparsePoint)) {
            throw "The application data directory is invalid."
        }
        $existingID = [Box.Installer.DirectoryAccessControl]::ReadDirectoryMarker($Path)
        if ($existingID -eq $ID) {
            return
        }
        $existingEntry = Get-ChildItem -LiteralPath $Path -Force | Select-Object -First 1
        if ($null -ne $existingEntry) {
            # A directory that holds data and does not carry OUR marker. Refusing is the default,
            # and it is what made the installer unusable on a machine whose previous client had
            # left its profiles here: the user was told their own data directory "must be empty",
            # with no way to proceed except deleting it by hand.
            #
            # It is re-owned only when the PREVIOUS RELEASE LINE's own record names this exact
            # directory. That record is the evidence that this data is this product's, and the
            # check is made HERE rather than taken from the caller, so a preflight invoked for any
            # other reason cannot be talked into claiming a directory. On an empty directory the
            # question does not arise, and on a directory belonging to another client the record
            # does not name it, so the refusal stands.
            if (-not $Adopted -or -not (Test-LegacyLayoutNamesDirectory $Path)) {
                throw "The application data directory must be empty."
            }
        }
    } else {
        [void][System.IO.Directory]::CreateDirectory($Path)
    }
    Set-ApplicationDataDirectoryAccessControl $Path
    [Box.Installer.DirectoryAccessControl]::WriteDirectoryMarker($Path, $ID)
}

if ($MyInvocation.InvocationName -eq ".") {
    return
}

try {
    if (-not $AllowUnsafeInstallationDirectory) {
        try {
            $existingInstallationPath = Get-ExistingPath $InstallationDirectory
            $installationVolume = [Box.Installer.InstallationVolume]::ResolveVolumePath(
                $existingInstallationPath
            )
            $installationDriveType = [Box.Installer.InstallationVolume]::ResolveDriveType(
                $installationVolume
            )
            if ($installationDriveType -ne [Box.Installer.InstallationVolume]::FixedDrive) {
                Write-InstallerOutput $installationVolume
                Exit-Installer 14
            }
            $installationFileSystem = [Box.Installer.InstallationVolume]::ResolveFileSystemName(
                $installationVolume
            )
            if (-not [string]::Equals(
                    $installationFileSystem,
                    "NTFS",
                    [System.StringComparison]::OrdinalIgnoreCase
                )) {
                Write-InstallerOutput $installationFileSystem
                Exit-Installer 15
            }
        } catch {
            Write-InstallerOutput "$installationVolume`: $($_.Exception.Message)"
            Exit-Installer 16
        }

        if (Test-Path -LiteralPath $InstallationDirectory) {
            $installationItem = Get-Item -LiteralPath $InstallationDirectory -Force
            if (-not $installationItem.PSIsContainer -or ($installationItem.Attributes -band $reparsePoint)) {
                Exit-Installer 10
            }
            $installationReparsePoint = Get-ChildItem -LiteralPath $InstallationDirectory -Force -Recurse |
                Where-Object { $_.Attributes -band $reparsePoint } |
                Select-Object -First 1
            if ($null -ne $installationReparsePoint) {
                Exit-Installer 10
            }
        }

        $installationAncestorPaths = @(
            Get-InstallationAncestorPaths $InstallationDirectory $installationVolume
        )
        $unsafeInstallationAncestor = Get-UnsafeInstallationAncestor $installationAncestorPaths
        if ($RepairPathAncestors) {
            Repair-PathAncestorPermissions $installationAncestorPaths
            $unsafeInstallationAncestor = Get-UnsafeInstallationAncestor $installationAncestorPaths
            if ($null -ne $unsafeInstallationAncestor) {
                Write-InstallerOutput $unsafeInstallationAncestor.Path
                Exit-Installer 32
            }
        }
        if ($null -ne $unsafeInstallationAncestor) {
            Write-InstallerOutput $unsafeInstallationAncestor.Path
            Exit-Installer ([int]$unsafeInstallationAncestor.ExitCode)
        }
    }

    if ([string]::IsNullOrWhiteSpace($DaemonWorkingDirectory)) {
        $commonApplicationData = [Environment]::GetFolderPath(
            [Environment+SpecialFolder]::CommonApplicationData
        )
        # The same directory the installer defaults to (build/installer.nsh,
        # DAEMON_DATA_DIRECTORY_NAME) and the same one the runtime falls back to
        # (src/main/installationLayout.ts). Previously this said `sing-box-daemon` while the
        # installer used its own name, so a preflight that had to supply the default
        # validated a directory the daemon would never use.
        $DaemonWorkingDirectory = Join-Path $commonApplicationData "jiejiebox-daemon"
    }
    $workingDirectory = [System.IO.Path]::GetFullPath($DaemonWorkingDirectory)
    if (Test-PathOverlap $InstallationDirectory $workingDirectory) {
        Write-InstallerOutput $workingDirectory
        Exit-Installer 23
    }
    try {
        $workingVolume = Resolve-FixedNTFSVolume $workingDirectory
        $workingAncestorPaths = @(
            Get-InstallationAncestorPaths $workingDirectory $workingVolume
        )
        $unsafeWorkingAncestor = Get-UnsafeInstallationAncestor $workingAncestorPaths
        if ($AllowUnsafeInstallationDirectory -and
            $null -ne $unsafeWorkingAncestor -and
            $unsafeWorkingAncestor.ExitCode -in @(12, 13)) {
            $unsafeWorkingAncestor = $null
        } elseif ($RepairPathAncestors -and
            $null -ne $unsafeWorkingAncestor -and
            $unsafeWorkingAncestor.ExitCode -eq 13) {
            Repair-PathAncestorPermissions $workingAncestorPaths
            $unsafeWorkingAncestor = Get-UnsafeInstallationAncestor $workingAncestorPaths
            if ($null -ne $unsafeWorkingAncestor -and
                $unsafeWorkingAncestor.ExitCode -eq 13) {
                Write-InstallerOutput $unsafeWorkingAncestor.Path
                Exit-Installer 32
            }
        }
        if ($null -ne $unsafeWorkingAncestor) {
            Write-InstallerOutput $unsafeWorkingAncestor.Path
            if ($unsafeWorkingAncestor.ExitCode -eq 13) {
                Exit-Installer 17
            }
            Exit-Installer 27
        }
    } catch {
        Write-InstallerOutput $_.Exception.Message
        Exit-Installer 27
    }

    if (-not [string]::IsNullOrWhiteSpace($ApplicationDataDirectory)) {
        $ApplicationDataDirectory = [System.IO.Path]::GetFullPath($ApplicationDataDirectory)
        if ((Test-PathOverlap $InstallationDirectory $ApplicationDataDirectory) -or
            (Test-PathOverlap $workingDirectory $ApplicationDataDirectory)) {
            Write-InstallerOutput $ApplicationDataDirectory
            Exit-Installer 24
        }
        try {
            $applicationDataVolume = Resolve-FixedNTFSVolume $ApplicationDataDirectory
            $applicationDataAncestorPaths = @(
                Get-InstallationAncestorPaths $ApplicationDataDirectory $applicationDataVolume
            )
            $unsafeApplicationDataAncestor = Get-UnsafeInstallationAncestor `
                $applicationDataAncestorPaths
            if ($AllowUnsafeInstallationDirectory -and
                $null -ne $unsafeApplicationDataAncestor -and
                $unsafeApplicationDataAncestor.ExitCode -in @(12, 13)) {
                $unsafeApplicationDataAncestor = $null
            } elseif ($RepairPathAncestors -and
                $null -ne $unsafeApplicationDataAncestor -and
                $unsafeApplicationDataAncestor.ExitCode -eq 13) {
                Repair-PathAncestorPermissions $applicationDataAncestorPaths
                $unsafeApplicationDataAncestor = Get-UnsafeInstallationAncestor `
                    $applicationDataAncestorPaths
                if ($null -ne $unsafeApplicationDataAncestor -and
                    $unsafeApplicationDataAncestor.ExitCode -eq 13) {
                    Write-InstallerOutput $unsafeApplicationDataAncestor.Path
                    Exit-Installer 32
                }
            }
            if ($null -ne $unsafeApplicationDataAncestor) {
                Write-InstallerOutput $unsafeApplicationDataAncestor.Path
                if ($unsafeApplicationDataAncestor.ExitCode -eq 13) {
                    Exit-Installer 18
                }
                Exit-Installer 28
            }
            if (Test-Path -LiteralPath $ApplicationDataDirectory) {
                $applicationDataItem = Get-Item -LiteralPath $ApplicationDataDirectory -Force
                if (-not $applicationDataItem.PSIsContainer -or
                    ($applicationDataItem.Attributes -band $reparsePoint)) {
                    throw "The application data directory is invalid."
                }
                $applicationDataReparsePoint = Get-ChildItem `
                    -LiteralPath $ApplicationDataDirectory `
                    -Force `
                    -Recurse |
                    Where-Object { $_.Attributes -band $reparsePoint } |
                    Select-Object -First 1
                if ($null -ne $applicationDataReparsePoint) {
                    throw "The application data directory contains a reparse point."
                }
            }
        } catch {
            Write-InstallerOutput $_.Exception.Message
            Exit-Installer 28
        }
    }

    if ($ResetWorkingDirectory) {
        Remove-WorkingDirectoryTree $workingDirectory
        if (Test-Path -LiteralPath $workingDirectory) {
            Exit-Installer 31
        }
        Exit-Installer 0
    }
    if ($DeleteDataDirectories) {
        Remove-WorkingDirectoryTree $workingDirectory
        if (Test-Path -LiteralPath $workingDirectory) {
            Exit-Installer 31
        }
        if (-not [string]::IsNullOrWhiteSpace($ApplicationDataDirectory)) {
            $directoryID = [Box.Installer.DirectoryAccessControl]::ReadDirectoryMarker(
                $ApplicationDataDirectory
            )
            if ($directoryID -ne $InstallationID) {
                Write-InstallerOutput "The application data directory does not belong to this installation."
                Exit-Installer 26
            }
            Remove-WorkingDirectoryTree $ApplicationDataDirectory
            if (Test-Path -LiteralPath $ApplicationDataDirectory) {
                Exit-Installer 26
            }
        }
        Exit-Installer 0
    }
    if ($PrepareApplicationDataDirectory -and
        -not [string]::IsNullOrWhiteSpace($ApplicationDataDirectory)) {
        try {
            Initialize-ApplicationDataDirectory $ApplicationDataDirectory $InstallationID -Adopted:$Adopted
        } catch {
            Write-InstallerOutput $_.Exception.Message
            Exit-Installer 25
        }
    }
    if (-not (Test-Path -LiteralPath $workingDirectory)) {
        Exit-Installer 0
    }

    $workingItem = Get-Item -LiteralPath $workingDirectory -Force
    if (-not $workingItem.PSIsContainer -or ($workingItem.Attributes -band $reparsePoint)) {
        Exit-Installer 20
    }
    $workingReparsePoint = Get-ChildItem -LiteralPath $workingDirectory -Force -Recurse |
        Where-Object { $_.Attributes -band $reparsePoint } |
        Select-Object -First 1
    if ($null -ne $workingReparsePoint) {
        Exit-Installer 20
    }

    # An existing daemon working directory that is not protected the way the daemon protects it is
    # repaired here rather than refused. See Set-DaemonWorkingDirectoryAccessControl for why the
    # strict check below cannot be the end of it: the daemon repairs such a directory itself, but
    # it cannot run until the installation succeeds, and the installation was stopping right here.
    #
    # The repair runs BEFORE the checks and its result is re-read from the directory, so a repair
    # that did not achieve the required state still fails those checks with the same codes. Only a
    # directory that is already protected is left alone; the ACL is rewritten only when it needs to
    # be, so an ordinary upgrade does not churn a correct ACL.
    $workingAccessControl = Get-Acl -LiteralPath $workingDirectory
    $workingOwner = $workingAccessControl.GetOwner([System.Security.Principal.SecurityIdentifier]).Value
    $workingServiceSid = Get-ServiceSid $daemonServiceName
    $workingRuleIdentities = @(
        $workingAccessControl.GetAccessRules($true, $false, [System.Security.Principal.SecurityIdentifier]) |
            ForEach-Object { $_.IdentityReference.Value }
    )
    $workingNeedsRepair = $workingOwner -ne "S-1-5-18" -or
        -not $workingAccessControl.AreAccessRulesProtected -or
        ($workingRuleIdentities -notcontains "S-1-5-18") -or
        ($workingRuleIdentities -notcontains "S-1-5-32-544") -or
        ($workingRuleIdentities -notcontains $workingServiceSid)
    if ($workingNeedsRepair) {
        Write-InstallerOutput ("repairing the daemon working directory: owner={0} protected={1} identities={2}" -f `
            $workingOwner, $workingAccessControl.AreAccessRulesProtected, ($workingRuleIdentities -join ','))
        try {
            Set-DaemonWorkingDirectoryAccessControl $workingDirectory
        } catch {
            # A repair that could not be performed leaves the original failure to be reported by
            # the checks below, with the codes the installer already knows how to act on.
            Write-InstallerOutput "Could not repair the daemon working directory: $($_.Exception.Message)"
        }
    }

    $expectedIdentities = @{
        "S-1-5-18" = $false
        "S-1-5-32-544" = $false
        (Get-ServiceSid $daemonServiceName) = $false
    }
    $accessControl = Get-Acl -LiteralPath $workingDirectory
    $owner = $accessControl.GetOwner([System.Security.Principal.SecurityIdentifier]).Value
    if ($owner -ne "S-1-5-18") {
        Exit-Installer 21
    }
    if (-not $accessControl.AreAccessRulesProtected) {
        Exit-Installer 22
    }

    $rules = @($accessControl.GetAccessRules(
        $true,
        $false,
        [System.Security.Principal.SecurityIdentifier]
    ))
    if ($rules.Count -lt $expectedIdentities.Count) {
        Exit-Installer 22
    }
    foreach ($rule in $rules) {
        if ($rule.AccessControlType -ne [System.Security.AccessControl.AccessControlType]::Allow) {
            Exit-Installer 22
        }
        $identity = $rule.IdentityReference.Value
        if (-not $expectedIdentities.ContainsKey($identity)) {
            continue
        }
        if ($expectedIdentities[$identity] -or
            [int]$rule.FileSystemRights -ne [int][System.Security.AccessControl.FileSystemRights]::FullControl -or
            $rule.InheritanceFlags -ne (
                [System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
                [System.Security.AccessControl.InheritanceFlags]::ObjectInherit
            ) -or
            $rule.PropagationFlags -ne [System.Security.AccessControl.PropagationFlags]::None) {
            Exit-Installer 22
        }
        $expectedIdentities[$identity] = $true
    }
    if ($expectedIdentities.Values -contains $false) {
        Exit-Installer 22
    }
    Exit-Installer 0
} catch {
    $message = "$($_.Exception.Message)$([Environment]::NewLine)$($_.ScriptStackTrace)"
    if ([string]::IsNullOrWhiteSpace($ResultOutputPath)) {
        [Console]::Error.WriteLine($message)
    } else {
        Write-InstallerOutput $message
    }
    Exit-Installer 30
}
