; Executes the real chooseForkInstallationDirectory macro and writes what it decided.
; Also executes fixForkInstallationDirectory against a table of $INSTDIR values.
;
; WHY THIS EXISTS
;
; check-installer.nsh assembles the macros. Assembling proves they parse; it does not prove
; chooseForkInstallationDirectory picks the right directory. Installed into that harness it
; also cannot run: `customInit` performs installation preflight against real paths and aborts
; an unattended run before any section executes.
;
; This file includes the REAL macro from the REAL installer.nsh - not a copy - and drives it
; directly. That is not a formality: the first version of the macro used
; `StrCpy $var $in "" -1` to read the last path component, which silently returns nothing, so
; the macro compiled, ran, and renamed nothing. This probe is what caught it.
;
; USAGE
;
;   makensis /DINSTALLER_NSH=<abs>\build\installer.nsh \
;            /DBUILD_RESOURCES_DIR=<abs>\build \
;            /DPROBE_OUTPUT=<abs path to a file to write> \
;            rename-probe.nsi
;
; then run the produced executable with /S and read that file.
; scripts\test-install-directory.ps1 does both and asserts the contents.

Unicode true
SetCompressor /SOLID lzma
Name "install-directory-probe"
OutFile "rename-probe.exe"
RequestExecutionLevel user
InstallDir "$TEMP\install-directory-probe"
ShowInstDetails nevershow

; The symbols electron-builder passes on the command line and that installer.nsh reads.
; APP_FILENAME is the executable name - the whole reason the directory has to be chosen
; separately.
!define APP_FILENAME "sing-box"
!define APP_64
; installer.nsh's installer half declares ~25 Vars for the installation pages and includes
; StrContains.nsh for its directory handling, none of which the macro needs. Defining
; BUILD_UNINSTALLER takes the file's other, much smaller branch, so this probe compiles the
; SAME file with the SAME macro and none of the page machinery.
!define BUILD_UNINSTALLER
; The key multiUser.nsh reads for a previous installation's own record of where it went.
; Spelled as electron-builder spells it, so the probe exercises the same read.
!define INSTALL_REGISTRY_KEY "Software\install-directory-probe"

!addincludedir "${BUILD_RESOURCES_DIR}"
!include "LogicLib.nsh"
!include "x64.nsh"
!include "${INSTALLER_NSH}"

Section "-install directory probe"
  Delete "${PROBE_OUTPUT}"
  FileOpen $9 "${PROBE_OUTPUT}" w
  FileWrite $9 "APP_FILENAME=${APP_FILENAME}$\r$\n"
  FileWrite $9 "FORK_DIR_NAME=${FORK_INSTALLATION_DIRECTORY_NAME}$\r$\n"

  ; --- a fresh machine: no previous installation recorded --------------------------------
  DeleteRegValue SHELL_CONTEXT "${INSTALL_REGISTRY_KEY}" "InstallLocation"
  StrCpy $INSTDIR "$PROGRAMFILES64\${APP_FILENAME}"
  !insertmacro chooseForkInstallationDirectory
  FileWrite $9 "fresh=$INSTDIR$\r$\n"

  ; --- an upgrade from a previous version that recorded its directory --------------------
  ; Its files are there. Reusing the record is what keeps an upgrade an upgrade rather than a
  ; second installation beside the first.
  WriteRegStr SHELL_CONTEXT "${INSTALL_REGISTRY_KEY}" "InstallLocation" "C:\Program Files\sing-box"
  StrCpy $INSTDIR "$PROGRAMFILES64\${APP_FILENAME}"
  !insertmacro chooseForkInstallationDirectory
  FileWrite $9 "previous-recorded=$INSTDIR$\r$\n"

  ; --- a previous installation in a custom location --------------------------------------
  WriteRegStr SHELL_CONTEXT "${INSTALL_REGISTRY_KEY}" "InstallLocation" "D:\Apps\Elsewhere"
  StrCpy $INSTDIR "$PROGRAMFILES64\${APP_FILENAME}"
  !insertmacro chooseForkInstallationDirectory
  FileWrite $9 "previous-custom=$INSTDIR$\r$\n"

  DeleteRegValue SHELL_CONTEXT "${INSTALL_REGISTRY_KEY}" "InstallLocation"
  DeleteRegKey SHELL_CONTEXT "${INSTALL_REGISTRY_KEY}"

  ; --- fixForkInstallationDirectory: the $INSTDIR contract, case by case ------------------
  ;
  ; The paired macro is what enforces the rule chooseForkInstallationDirectory above now
  ; honours: $INSTDIR ends with \${APP_FILENAME}. It replaced a `${StrContains}` SUBSTRING test,
  ; and the four "substring-" rows are exactly what that test got wrong - each of those paths
  ; contains "sing-box" somewhere, so the old test skipped the repair and left a directory that
  ; did not end in the executable name.
  ;
  ; Written as "##name=value" so the harness can pick these rows out of the same file.
  !macro FixCase LABEL VALUE
    StrCpy $INSTDIR "${VALUE}"
    !insertmacro fixForkInstallationDirectory
    FileWrite $9 "##${LABEL}=$INSTDIR$\r$\n"
  !macroend

  !insertmacro FixCase "already-correct"    "C:\Program Files\Jiejiebox\sing-box"
  !insertmacro FixCase "upstream-layout"    "C:\Program Files\sing-box"
  !insertmacro FixCase "fork-root-only"     "C:\Program Files\Jiejiebox"
  !insertmacro FixCase "substring-tools"    "C:\Program Files\sing-box-tools"
  !insertmacro FixCase "substring-backup"   "C:\Program Files\old\sing-box-backup"
  !insertmacro FixCase "substring-parent"   "C:\sing-box\Jiejiebox"
  !insertmacro FixCase "trailing-separator" "C:\Program Files\Jiejiebox\sing-box\"
  !insertmacro FixCase "trailing-two"       "C:\Program Files\Jiejiebox\sing-box\\"
  !insertmacro FixCase "suffix-digit"       "C:\Program Files\Jiejiebox\sing-box2"
  !insertmacro FixCase "bare-name"          "sing-box"
  !insertmacro FixCase "empty"              ""

  FileClose $9
SectionEnd
