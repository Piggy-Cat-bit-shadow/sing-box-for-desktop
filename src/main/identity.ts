// Machine-global identity for the Windows client.
//
// These strings name resources the operating system owns rather than resources this
// process owns: the AppData tree, the installation-layout registry key, the Application
// User Model ID the shell groups windows and notifications by, and the Taildrop shell verb.
// Each one is a key in a machine-wide namespace, so two clients that share a value cannot
// be installed, run, upgraded or removed independently - the second install reconfigures
// the first one's registration and either one's uninstall can take the other's away.
//
// They therefore all say `jiejiebox`, and the upstream client keeps the `sing-box` values
// it shipped with. This is deliberately NOT a rename of the product: `productName` is
// already JiejieBox and everything a user reads comes from there.
//
// ---------------------------------------------------------------------------
// What is deliberately NOT isolated here, and why
// ---------------------------------------------------------------------------
//
// The installed executable stays `sing-box.exe` (`win.executableName` in
// electron-builder.yml). experimental/boxdd authenticates the application by resolving
// <install>/sing-box.exe and comparing its Authenticode signer against the daemon's own,
// both when the service is registered and on every peer handshake. The file name is part
// of that security chain, and it is not a collision: the two clients install into
// different directories.
//
// The daemon file name, `sing-box-daemon.exe`, is likewise unchanged: experimental/boxdd
// requires it by name and it is only ever read from inside one installation tree.
//
// The `sing-box://` deep link scheme is not registered by this client (see
// `registeredDeepLinkScheme`), so sharing it costs nothing - but links in that form are
// still parsed, so a profile shared by any other sing-box client keeps working.
//
// The `.bpf` file association carries the same profile format for both clients, and the
// registry key is keyed by the extension, so it cannot be isolated without inventing a
// second format. Last installed wins; this is a documented boundary, not a defect.
//
// ---------------------------------------------------------------------------
// Keeping the installer in step
// ---------------------------------------------------------------------------
//
// build/installer.nsh cannot import this module, so it re-states `jiejiebox` in its own
// `!define`s. The two are checked against each other by
// scripts/ci/verify-desktop-identity-consistency.py in the parent repository, which is
// what stops one of them being changed without the other.
export const applicationIdentity = "jiejiebox";

// The AppData directory name - and it is UPSTREAM'S value, deliberately.
//
// This said `jijiebox` and it bought nothing. It is not the directory an install uses: the
// installer's own default is upstream's literal `$APPDATA\sing-box` (build/installer.nsh), it
// records that in the layout key, and the runtime prefers the key
// (installationLayout.ts -> applicationPaths.ts). Measured on a machine with both clients
// installed, the two layout keys recorded the SAME path:
//
//     HKLM\SOFTWARE\SagerNet\sing-box    ApplicationDataDirectory = C:\ProgramData\sing-box
//     HKLM\SOFTWARE\Jiejiebox\jiejiebox  ApplicationDataDirectory = C:\ProgramData\sing-box
//
// So `jijiebox` was reachable only as applicationPaths.ts's FALLBACK - the value used when the
// layout key is absent or unreadable, and by the development server. That made it a second data
// path that nothing had ever written to: a layout-read failure would have sent the client into an
// empty `%APPDATA%\jijiebox` instead of the tree holding the user's profiles. Two spellings for one
// thing, with the losing one reachable exactly when something has already gone wrong.
//
// Reverting it to upstream's value removes the second path and changes nothing else: the installer
// already used `sing-box`, so installed clients do not move, and no data is migrated.
//
// NOTE this is the ONE identity value that is not isolated, and that is correct rather than
// unfinished - see the daemon service name and daemon data directory below, which are machine-global
// in a way that genuinely collides.
export const applicationDataDirectoryName = "sing-box";

// The name under %ProgramData% that the privileged daemon keeps its state in. Also the
// daemon's `defaultServiceWorkingDirectory` in experimental/boxdd/cmd_service_windows.go.
export const daemonDataDirectoryName = `${applicationIdentity}-daemon`;

// The daemon's identity in the Windows service manager, and the name its named pipe is
// bound under (`\\.\pipe\ProtectedPrefix\Administrators\<name>`, see
// experimental/boxdd/server_windows.go). Both are machine-global: the SCM keys a service by
// exactly this string, and only one server can bind a pipe path. The upstream client owns
// `sing-box-daemon` / `sing-box`, so the fork must not share them.
//
// This is the same value as experimental/boxdd's `serviceName`.
export const daemonServiceName = `jiejiebox-daemon`;

// The daemon executable's file name. Not an identity: it is read from inside one
// installation tree, and experimental/boxdd requires this exact spelling next to the
// application executable.
export const daemonExecutableName = "sing-box-daemon.exe";

// The installed application executable's file name. See the note above: the daemon
// authenticates the application by resolving this name, so it is a security dependency.
export const applicationExecutableName = "sing-box.exe";

// The Application User Model ID. The shell uses it for taskbar grouping, jump lists and
// notification attribution, so it has to match electron-builder's `win.appId`. It is not
// decorative: two clients sharing it would group into one taskbar button and overwrite
// each other's notification registration.
//
// It is also the LOGIN ITEM's identity, which is worth recording because it is not obvious.
// Electron documents `setLoginItemSettings`'s `name` option as "value name to write into
// registry. Defaults to the app's AppUserModelId()" (`interface Settings` in electron.d.ts),
// and `loginItem.ts` passes no `name` - so the Run entry, the Task Manager startup entry and
// the `StartupApproved` entry are all keyed by this value. Changing the AUMID therefore
// isolates the login item as well, with no edit to loginItem.ts and nothing to migrate:
// `migrateLoginItem` reads and writes only this client's own entry, so it can neither see nor
// close the upstream client's startup item.
//
// (macOS and Linux take other paths - `SMAppService`/Login Items, and an XDG autostart file -
// and are out of scope for this Windows change.)
export const applicationUserModelId = `io.github.piggycatbitshadow.${applicationIdentity}`;

// The shell verb the installer registers under
// `HKLM\Software\Classes\*\shell\<key>` for "send with Taildrop". Upstream registers
// `Taildrop`; the value is the menu label the user reads and the key is what uninstall
// deletes, so an uninstall must only ever remove its own.
export const taildropVerbRegistryKey = "JiejieboxTaildrop";

// The deep link scheme THIS client registers as its default handler.
//
// Deliberately not `sing-box`: registering that would take the handler away from the
// upstream client and from every other sing-box client on the machine, and the two
// installers would fight over the last writer. This client still PARSES `sing-box://`
// (see `acceptedDeepLinkSchemes`), so links shared by other clients keep importing.
export const registeredDeepLinkScheme = applicationIdentity;

// Every scheme accepted on input, this client's own first.
export const acceptedDeepLinkSchemes = [registeredDeepLinkScheme, "sing-box"];

// Where the Windows installer parks its data-migration state between the prepare and
// commit steps. It is machine-global, and its recovery runs on every install, so a shared
// path means one client's installer can replay or clean up the other's unfinished
// migration.
export const installerStateDirectoryName = `${applicationIdentity}-installer`;

// The NTFS alternate data stream the installer stamps an application data directory with,
// to prove the directory belongs to the installation about to modify it. The stream lives
// inside the directory, so with a per-client data directory this is already isolated -
// the name is kept distinct anyway, so a directory can never be claimed by the other
// client's installer even if the two are ever pointed at the same path.
export const installationIdStreamName = `${applicationIdentity}.installation-id`;

// The registry key the installer records the installation layout under, and the runtime
// reads it back from (see installationLayout.ts). It is machine-global, and it is how the
// runtime learns which AppData tree and which daemon data directory this installation owns -
// so reading the upstream client's key would make this client adopt that client's data.
//
// build/installer.nsh re-states this as INSTALLATION_LAYOUT_REGISTRY_KEY; the two are
// checked against each other by scripts/ci/verify-desktop-identity-consistency.py in the
// parent repository. The vendor component mirrors the appId's, so every Windows identity
// this client owns sits under one vendor path rather than one per resource.
export const installationRegistryPath = String.raw`SOFTWARE\Jiejiebox\jiejiebox`;
