; Static compile check for clients/desktop/build/installer.nsh.
;
; WHY THIS EXISTS
;
; installer.nsh is never built on its own. electron-builder generates an .nsi that defines
; ~20 symbols and then includes this file, so the only thing that normally compiles it is a
; full Windows packaging run: build the daemon, the native module and the renderer, pack
; Electron, generate the NSIS script - and only then does makensis see a line of it. A typo,
; a missing Var, an unbalanced ${if} or a reference to a symbol that no longer exists
; therefore costs a full packaging cycle to discover, and the runtime gates that would notice
; the CONSEQUENCES only run on a Windows runner with an administrator.
;
; This harness supplies the minimum undefined surface and INSERTS the macros, so makensis
; type-checks what the product actually calls. Inserting matters: NSIS does not parse a macro
; body until it is inserted, so a plain `!include` would check almost nothing.
;
; It found two real defects the first time it ran. `$COMMONAPPDATA`, which NSIS does not have
; - an unknown $NAME in a command is a WARNING that resolves to the empty string, so the
; daemon's state directory would have been `\jiejiebox-daemon` at the drive root and the
; install would still have reported success. And a Var that `customUnInit` wrote and nothing
; declared.
;
; It is NOT a substitute for the workflow's gates. It does not pack, sign, install or run
; anything. It answers exactly one question - "does this script still assemble?" - in seconds
; instead of in a packaging run.
;
; USAGE
;
;   makensis /DINSTALLER_NSH=<abs>\build\installer.nsh \
;            /DBUILD_RESOURCES_DIR=<abs>\build \
;            /DELECTRON_BUILDER_NSIS_TEMPLATES=<abs>\app-builder-lib\templates\nsis \
;            /DNSIS_PLUGIN_DIR=<abs>\nsis-bundle\windows\Plugins \
;            [/DBUILD_UNINSTALLER] \
;            check-installer.nsh
;
; Two runs, because NSIS will not emit normal sections in the same pass that generates an
; uninstaller: the first (no flag) assembles customInit/customInstall, the second (with
; -DBUILD_UNINSTALLER) assembles customUnInit/customUnInstall. The last two paths come from
; `node_modules/.pnpm/app-builder-lib@*/node_modules/app-builder-lib/` and
; `%LOCALAPPDATA%\electron-builder\Cache\nsis@*\nsis-bundle-*\windows` respectively.

Unicode true
SetCompressor /SOLID lzma
OutFile "installer-nsh-check.exe"
; The real installer is per-machine and elevates. This one only assembles macros and, with
; the probe define, writes a text file - so it asks for the lowest level that lets it run
; unattended. Requesting admin here would make the probe unimplementable in a session without
; elevation, for no gain: nothing in the harness installs anything.
RequestExecutionLevel user

; installer.nsh includes StrContains.nsh, which ships with electron-builder rather than
; with NSIS; StdUtils.nsh/nsProcess.nsh come from the same tree.
!addincludedir "${ELECTRON_BUILDER_NSIS_TEMPLATES}\include"
!addincludedir "${ELECTRON_BUILDER_NSIS_TEMPLATES}"
!addincludedir "${BUILD_RESOURCES_DIR}"
!addplugindir /x86-unicode "${NSIS_PLUGIN_DIR}"

!include "MUI2.nsh"
!include "LogicLib.nsh"
!include "WinVer.nsh"
!include "x64.nsh"
!include "FileFunc.nsh"
!include "nsDialogs.nsh"
!include "StdUtils.nsh"

; --- the product defines electron-builder supplies -------------------------------
;
; Values are the product's real ones where they affect parsing. common.nsh derives
; APP_EXECUTABLE_FILENAME and UNINSTALL_FILENAME from PRODUCT_FILENAME, so those are NOT
; defined here: doing so is a duplicate-define error, which is how this harness learned to
; leave them alone.
!define APP_ID "io.github.piggycatbitshadow.jiejiebox"
!define APP_GUID "00000000-0000-0000-0000-000000000000"
!define UNINSTALL_APP_KEY "installer-nsh-check"
!define PRODUCT_NAME "Jiejiebox"
!define PRODUCT_FILENAME "sing-box"
!define APP_FILENAME "sing-box"
!define APP_DESCRIPTION "Windows client for sing-box"
!define SHORTCUT_NAME "Jiejiebox"
!define VERSION "0.0.0"
!define INSTALL_REGISTRY_KEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\installer-nsh-check"
!define UNINSTALL_REGISTRY_KEY_2 "${INSTALL_REGISTRY_KEY}"
!define UNINSTALLER_OUT_FILE "$TEMP\installer-nsh-check-uninstaller.exe"
!define MUI_ICON "${NSISDIR}\Contrib\Graphics\Icons\modern-install.ico"
!define MUI_UNICON "${NSISDIR}\Contrib\Graphics\Icons\modern-uninstall.ico"

; --- electron-builder's command-line flag tests ----------------------------------
;
; installer.nsh tests `${isUpdated}` and `${isForceRun}`. No template defines those:
; electron-builder EMITS one LogicLib macro per flag into the generated script
; (NsisTarget -> nsisScriptGenerator.flags), so a harness without them fails with
; "macro _If requires 4 parameters" - a confusing way to learn that a flag is missing.
; These are the emitted bodies, for the flags installer.nsh uses.
!macro _isUpdated _a _b _t _f
  ${StdUtils.TestParameter} $R9 "updated"
  StrCmp "$R9" "true" `${_t}` `${_f}`
!macroend
!define isUpdated `"" isUpdated ""`

!macro _isForceRun _a _b _t _f
  ${StdUtils.TestParameter} $R9 "force-run"
  StrCmp "$R9" "true" `${_t}` `${_f}`
!macroend
!define isForceRun `"" isForceRun ""`

; --- symbols installer.nsh reads but does not declare ----------------------------
;
; `appExe` and the two desktop links are set by electron-builder's installSection.nsh, which
; this harness does not include (it emits the file copying and shortcut work, none of which
; is what is being checked here). Declaring them keeps the output warning-free, so a NEW
; warning is a real one.
Var appExe
Var newDesktopLink
Var oldDesktopLink
Var launchLink

; --- the hooks electron-builder's templates call ----------------------------------
;
; installer.nsh points MUI at these, so they must exist even though this harness never shows
; a page. Empty bodies are enough: what is being checked is that installer.nsh's own macros
; assemble and that every symbol they name resolves.
!ifndef BUILD_UNINSTALLER
  Function cancelInstallationValidation
  FunctionEnd
  Function applyInstallationFailureState
  FunctionEnd
!endif

!include "common.nsh"
!include "${INSTALLER_NSH}"

; --- assembling and invoking ------------------------------------------------------
;
; NSIS does not evaluate a macro body until it is inserted. Inserting each hook exactly where
; electron-builder inserts it is the whole point: elsewhere the context differs (a Var
; declared inside another macro is not visible, and commands are not valid at file scope),
; and the check would pass on a script the product cannot build.
!ifdef BUILD_UNINSTALLER

  ; customUnWelcomePage, not just a page: it is what declares `keepUninstallData`, which
  ; customUnInit writes. Declaring the page the way electron-builder does is therefore both
  ; faithful and what makes the Var exist - and a harness that declared the Var itself would
  ; hide the fact that the page and the macro are a pair.
  !insertmacro customUnWelcomePage
  !insertmacro MUI_LANGUAGE "English"

  ; uninstaller.nsh calls customUnInit from `Function un.onInit`.
  Function un.checkInit
    !insertmacro customUnInit
  FunctionEnd

  ; uninstaller.nsh calls customUnInstall from inside the uninstall section.
  Section "-Uninstall check"
    !insertmacro customUnInstall
  SectionEnd

!else

  !insertmacro MUI_PAGE_DIRECTORY
  !insertmacro MUI_PAGE_INSTFILES
  !insertmacro MUI_LANGUAGE "English"

  ; installer.nsi calls customInit from `Function .onInit`.
  Function .onInit
    !insertmacro customInit
  FunctionEnd

  Section "-Install check"
    !insertmacro customInstall
  SectionEnd

!endif
