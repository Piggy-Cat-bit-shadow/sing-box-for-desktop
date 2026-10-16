ManifestDPIAware true
SetDateSave off
SetFont "Segoe UI" 9

!include WinMessages.nsh

# ---------------------------------------------------------------------------
# Machine-global identity.
#
# These strings name resources the operating system owns, not resources this installation
# owns, so two clients that share one cannot be installed, upgraded or removed
# independently. They are the installer's half of the pair whose other half is
# src/main/identity.ts; the two are checked against each other by
# scripts/ci/verify-desktop-identity-consistency.py in the parent repository.
#
# INSTALLATION_LAYOUT_REGISTRY_KEY and DAEMON_DATA_DIRECTORY_NAME must agree with
# `installationRegistryPath` and `daemonDataDirectoryName` there. DEFINE_SERVICE_NAME must
# agree with experimental/boxdd's `serviceName`, which is also the name the daemon's named
# pipe is bound under - a disagreement leaves the client unable to reach its own daemon.
#
# Deliberately NOT isolated here: the installed executable stays `sing-box.exe` and the
# daemon file stays `sing-box-daemon.exe`. experimental/boxdd authenticates the application
# by resolving <install>/sing-box.exe and comparing its signer against the daemon's, so the
# application file name is part of the security chain. Neither is a collision: the two
# clients install into different directories.
# ---------------------------------------------------------------------------
# The registry path is case-insensitive to Windows, but it is spelled exactly as
# identity.ts spells it so the two can be compared as text - which is the only check
# available between NSIS and TypeScript.
!define INSTALLATION_LAYOUT_REGISTRY_KEY "SOFTWARE\Jiejiebox\jiejiebox"
# The layout key a version of this fork that predates its own daemon identity wrote. It is
# reported when the legacy service is removed, as context for what was found - NOT as
# ownership proof. The upstream client carries its own `build/installer.nsh`, and this file is
# derived from it, so upstream writes this key too; see installer-remove-legacy-service.ps1
# for the evidence that actually decides.
!define LEGACY_INSTALLATION_LAYOUT_REGISTRY_KEY "SOFTWARE\SagerNet\sing-box"
# The application data directory a version of this fork that predates its own identity used,
# and the one place its ownership marker still lives after an upgrade has replaced the
# installation tree. Passed to installer-remove-legacy-service.ps1, which is where the
# ownership argument is written down: the marker inside this directory is what proves a
# `sing-box-daemon` service is ours, and the layout key above - which the upstream client
# writes too - proves nothing.
!define LEGACY_APPLICATION_DATA_DIRECTORY_NAME "sing-box"
!define DAEMON_DATA_DIRECTORY_NAME "jiejiebox-daemon"
!define INSTALLER_STATE_DIRECTORY_NAME "jiejiebox-installer"
!define DEFINE_SERVICE_NAME "jiejiebox-daemon"
# The all-users profile, i.e. %ProgramData%.
#
# NOT `$APPDATA` under `SetShellVarContext all`: that call does not redirect the profile
# variables, so `$APPDATA` stays the INVOKING user's roaming profile - a private directory
# the SYSTEM daemon cannot rely on, and a different one for every user who happens to run
# the installer.
#
# NOT `$COMMONAPPDATA` either, which does not exist. NSIS has no such variable, an unknown
# `$NAME` in a command is only a WARNING, and it resolves to the empty string - so the
# daemon's state would have gone to the root of the current drive with nothing failing.
# (`makensis` warns 6000 about it; build/check-installer.nsh is what runs makensis over
# this file outside a full packaging run.)
#
# %ProgramData% is `%USERPROFILE%\AppData\Roaming` with its last two components removed,
# which is what this expresses. The runtime's own fallback in
# src/main/installationLayout.ts asks .NET for CommonApplicationData instead, and this
# installer hands the same directory to installer-service.ps1 and installer-preflight.ps1,
# which also use .NET - so all four agree on the DIRECTORY rather than on a spelling of it.
!define COMMON_APPLICATION_DATA "$PROFILE\..\..\ProgramData"
# The installation directory's name, as distinct from the installed executable's.
#
# This fork's executable must stay `sing-box.exe` (experimental/boxdd authenticates the
# application by that path), but the DIRECTORY must not stay `sing-box`, because the upstream
# client is per-machine too and would otherwise default to the same one. The two are separate
# names on purpose - see renameForkInstallationDirectory, which is where the directory is
# actually changed and where the reason it cannot be changed from electron-builder.yml is
# written down.
#
# It matches `productName` and NSIS's own `${PRODUCT_NAME}`, so the directory a user sees is
# the product name and the file inside it is the authenticated one.
!define FORK_INSTALLATION_DIRECTORY_NAME "Jiejiebox"

# The path BELOW Program Files that this fork installs into, as one value.
#
# `$INSTDIR` must END WITH `${APP_FILENAME}`, and that is electron-builder's contract rather than
# this fork's preference: `multiUser.nsh` derives every default as `<root>\${APP_FILENAME}`, and
# `customInstallBeforeInstallationChanges` (an insertion point this fork added to
# installSection.nsh) runs before `uninstallOldVersion`, the uninstaller write and
# `registryAddInstallInfo` - so whatever it leaves in `$INSTDIR` becomes the SCM's ImagePath, the
# registered uninstaller, InstallLocation, and the tree a later uninstall deletes.
#
# So the fork's own directory is `${FORK_INSTALLATION_DIRECTORY_NAME}` and the directory under it
# is the executable name: `...\Jiejiebox\sing-box`. Naming the pair here keeps that explicit
# rather than leaving it to be reconstructed by a string search on `$INSTDIR` further down - see
# fixForkInstallationDirectory.
#
# The Program Files root is deliberately NOT part of this define: it is an NSIS variable
# ($PROGRAMFILES64), and the choice between it and $PROGRAMFILES depends on ${RunningX64} /
# ${IsNativeARM64}, which only exist inside a macro. chooseForkInstallationDirectory makes that
# choice with the same condition multiUser.nsh uses.
!define FORK_INSTALLATION_SUBDIRECTORY "${FORK_INSTALLATION_DIRECTORY_NAME}\${APP_FILENAME}"
# The shell verb for "send with Taildrop". Upstream registers `Taildrop` under the same
# machine-wide parent key, and uninstall deletes the key wholesale - so sharing it means
# removing one client removes the other's context menu entry.
!define TAILDROP_VERB_REGISTRY_KEY "Software\Classes\*\shell\JiejieboxTaildrop"

# The CI-only diagnostic channel's path, declared OUTSIDE the installer/uninstaller
# conditional on purpose.
#
# It used to live inside the `!ifndef BUILD_UNINSTALLER` block below, so the uninstaller pass
# never declared it - and customUnInit could not touch it. That mattered because
# customUnInit is the only uninstall-side callback that can read the command line, and without
# a path to write to, every uninstall-side marker was inert: the guard stayed empty, nothing
# was written, and the record looked exactly as if the uninstall code had never run.
#
# Declaring it here makes it a global in BOTH passes. It is still completely inert unless
# /CI-DIAGNOSTIC-PATH= is passed: empty means every ciDiagnostic write is skipped.
Var ciDiagnosticPath

!ifndef BUILD_UNINSTALLER
  !include StrContains.nsh
  !define DO_NOT_CREATE_DESKTOP_SHORTCUT

  Var allowUnsafeInstallation
  Var installationValidationAllowsUnsafe
  Var installationValidationDialog
  Var installationValidationMessage
  Var installationValidationRepairable
  Var installationValidationRepairButton
  Var installationValidationUnsafeButton
  Var installationValidationStatusLabel
  Var installationValidationProgressBar
  Var installationValidationProcessHandle
  Var installationValidationProcessIDPath
  Var installationValidationOutputPath
  Var installationValidationResultPath
  Var installationValidationResult
  Var installationValidationOutput
  Var unsafeInstallationAcknowledgementCheckbox
  Var unsafeInstallationConfirmationRequested
  Var unsafeInstallationReturnButton
  Var unsafeInstallationAncestor
  Var resetWorkingDirectory
  Var workingDirectory
  Var installationActionDialog
  Var updateExistingInstallationRadio
  Var reinstallExistingInstallationRadio
  Var reinstallExistingInstallation
  Var standardInstallationRadio
  Var customInstallationRadio
  Var customInstallation
  Var applicationDataDirectory
  Var previousApplicationDataDirectory
  Var defaultApplicationDataDirectory
  Var fixedApplicationDataDirectory
  Var userApplicationDataDirectory
  Var userIndependentApplicationData
  Var userIndependentApplicationDataCheckbox
  Var applicationDataDirectoryInput
  Var applicationDataDirectoryBrowseButton
  Var daemonDataDirectory
  Var previousDaemonDataDirectory
  Var defaultDaemonDataDirectory
  Var daemonDataDirectoryInput
  Var daemonDataDirectoryBrowseButton
  Var dataDirectoriesDialog
  Var installerHeightExtension
  Var defaultInstallationDirectory
  Var installationDirectoryInput
  Var installationDirectoryBrowseButton
  Var migrateExistingData
  Var migrateExistingDataCheckbox
  Var migrateLegacyApplicationData
  Var dataTransitionStatePath
  Var hasExistingInstallation
  Var hasInstallationLayout
  Var installationID
  Var previousInstallationID
  Var installationFailureTimer
  Var finishRunCheckbox
  Var dataMigrationPrepared
  # Whether a half-finished data migration was found at customInit. Recorded because "Recover did
  # not run" and "Recover ran and did nothing" are different findings, and the second is what a
  # successful Commit is supposed to leave.
  Var dataTransitionStatePresent

  !macro customLicensePagePre
    !define MUI_PAGE_CUSTOMFUNCTION_PRE skipAcceptedLicensePage
  !macroend

  !macro showPendingInstallerOperation MESSAGE
    !insertmacro MUI_HEADER_TEXT "${MESSAGE}" ""
    System::Call 'user32::RedrawWindow(p $HWNDPARENT, p 0, p 0, i 0x185) i.r0'
  !macroend

  !macro resizeWindowHeight WINDOW HEIGHT_EXTENSION
    System::Call 'user32::GetWindowRect(p${WINDOW}, @r1)'
    System::Call '*$1(i.r2, i.r3, i.r4, i.r5)'
    IntOp $4 $4 - $2
    IntOp $5 $5 - $3
    IntOp $5 $5 + ${HEIGHT_EXTENSION}
    System::Call 'user32::SetWindowPos(p${WINDOW}, p0, i0, i0, ir4, ir5, i0x16)'
  !macroend

  !macro moveWindowDown WINDOW HEIGHT_EXTENSION
    System::Call 'user32::GetWindowRect(p${WINDOW}, @r1)'
    System::Call 'user32::MapWindowPoints(p0, p$HWNDPARENT, pr1, i2)'
    System::Call '*$1(i.r2, i.r3, i, i)'
    IntOp $3 $3 + ${HEIGHT_EXTENSION}
    System::Call 'user32::SetWindowPos(p${WINDOW}, p0, ir2, ir3, i0, i0, i0x15)'
  !macroend
!else
  Var applicationDataDirectory
  Var daemonDataDirectory
  Var installationID
!endif

!define MUI_CUSTOMFUNCTION_GUIINIT clearBrandingText
!ifdef BUILD_UNINSTALLER
  !define MUI_CUSTOMFUNCTION_UNGUIINIT un.clearBrandingText
!else
  !define MUI_CUSTOMFUNCTION_ABORT cancelInstallationValidation
!endif

!macro clearBrandingTextControl
  GetDlgItem $0 $HWNDPARENT 1256
  SendMessage $0 ${WM_SETTEXT} 0 "STR:"
!macroend

Function clearBrandingText
  !insertmacro clearBrandingTextControl
FunctionEnd

!ifdef BUILD_UNINSTALLER
  Function un.clearBrandingText
    !insertmacro clearBrandingTextControl
  FunctionEnd
!endif

!macro customHeader
  !insertmacro MUI_LANGUAGE "Farsi"

  !ifndef BUILD_UNINSTALLER
    Function .onInstFailed
      ${if} $installationFailureTimer != ""
        ${StdUtils.TimerDestroy} $0 $installationFailureTimer
        StrCpy $installationFailureTimer ""
      ${endif}
    FunctionEnd

    Function cancelInstallationValidation
      ${if} $installationValidationProcessHandle != ""
        StrCpy $0 $installationValidationProcessHandle
        System::Call 'kernel32::TerminateProcess(p r0, i 1223)'
        System::Call 'kernel32::CloseHandle(p r0)'
        StrCpy $installationValidationProcessHandle ""
      ${elseif} ${FileExists} "$installationValidationProcessIDPath"
        ClearErrors
        FileOpen $0 "$installationValidationProcessIDPath" r
        ${ifNot} ${Errors}
          FileRead $0 $1
          FileClose $0
          System::Call 'kernel32::OpenProcess(i 0x00000001, i 0, i r1) p.r0'
          ${if} $0 != 0
            System::Call 'kernel32::TerminateProcess(p r0, i 1223)'
            System::Call 'kernel32::CloseHandle(p r0)'
          ${endif}
        ${endif}
      ${endif}
      Delete "$installationValidationOutputPath"
      Delete "$installationValidationResultPath"
      Delete "$installationValidationProcessIDPath"
    FunctionEnd
  !endif

  LangString win7Required ${LANG_FARSI} "ویندوز ۷ یا بالاتر مورد نیاز است"
  LangString x64WinRequired ${LANG_FARSI} "ویندوز ۶۴ بیتی مورد نیاز است"
  LangString appRunning ${LANG_FARSI} "${PRODUCT_NAME} در حال اجرا است.$\r$\nبرای بستن آن روی «تأیید» کلیک کنید.$\r$\nاگر بسته نشد، آن را به‌صورت دستی ببندید."
  LangString appCannotBeClosed ${LANG_FARSI} "${PRODUCT_NAME} بسته نمی‌شود.$\r$\nلطفاً آن را به‌صورت دستی ببندید و برای ادامه روی «تلاش مجدد» کلیک کنید."
  LangString installing ${LANG_FARSI} "در حال نصب، لطفاً منتظر بمانید..."
  LangString areYouSureToUninstall ${LANG_FARSI} "آیا مطمئن هستید که می‌خواهید ${PRODUCT_NAME} را حذف کنید؟"
  LangString decompressionFailed ${LANG_FARSI} "استخراج فایل‌ها ناموفق بود. لطفاً نصب‌کننده را دوباره اجرا کنید."
  LangString uninstallFailed ${LANG_FARSI} "حذف فایل‌های نسخهٔ قبلی ناموفق بود. لطفاً نصب‌کننده را دوباره اجرا کنید."
  LangString appClosing ${LANG_FARSI} "در حال بستن ${PRODUCT_NAME}..."
  LangString chooseInstallationOptions ${LANG_FARSI} "انتخاب گزینه‌های نصب"
  LangString chooseUninstallationOptions ${LANG_FARSI} "انتخاب گزینه‌های حذف"
  LangString whichInstallationShouldBeRemoved ${LANG_FARSI} "کدام نصب باید حذف شود؟"
  LangString whoShouldThisApplicationBeInstalledFor ${LANG_FARSI} "این برنامه برای چه کسانی نصب شود؟"
  LangString selectUserMode ${LANG_FARSI} "انتخاب کنید این برنامه برای همهٔ کاربران یا فقط برای شما در دسترس باشد"
  LangString whichInstallationRemove ${LANG_FARSI} "این برنامه هم برای همهٔ کاربران و هم برای کاربر فعلی نصب شده است.$\r$\nکدام نصب را می‌خواهید حذف کنید؟"
  LangString freshInstallForAll ${LANG_FARSI} "نصب تازه برای همهٔ کاربران (نیازمند مجوز مدیر)"
  LangString freshInstallForCurrent ${LANG_FARSI} "نصب تازه فقط برای کاربر فعلی"
  LangString onlyForMe ${LANG_FARSI} "فقط برای &من"
  LangString forAll ${LANG_FARSI} "برای همهٔ کاربران این رایانه (&همه)"
  LangString loginWithAdminAccount ${LANG_FARSI} "برای ادامه باید با حسابی وارد شوید که عضو گروه مدیران است..."
  LangString perUserInstallExists ${LANG_FARSI} "یک نصب برای کاربر فعلی از قبل وجود دارد."
  LangString perUserInstall ${LANG_FARSI} "یک نصب برای کاربر فعلی وجود دارد."
  LangString perMachineInstallExists ${LANG_FARSI} "یک نصب برای همهٔ کاربران از قبل وجود دارد."
  LangString perMachineInstall ${LANG_FARSI} "یک نصب برای همهٔ کاربران وجود دارد."
  LangString reinstallUpgrade ${LANG_FARSI} "دوباره نصب یا ارتقا داده می‌شود."
  LangString uninstall ${LANG_FARSI} "حذف می‌شود."

  !ifdef BUILD_UNINSTALLER
    ShowUninstDetails show
  !else
    ShowInstDetails show
  !endif

  LangString keepData ${LANG_ENGLISH} "&Keep data"
  LangString keepData ${LANG_SIMPCHINESE} "保留数据"
  LangString keepData ${LANG_TRADCHINESE} "保留資料"
  LangString keepData ${LANG_FARSI} "&حفظ داده‌ها"
  LangString keepData ${LANG_RUSSIAN} "&Сохранить данные"

  LangString existingInstallationPageTitle ${LANG_ENGLISH} "Existing installation"
  LangString existingInstallationPageTitle ${LANG_SIMPCHINESE} "已有安装"
  LangString existingInstallationPageTitle ${LANG_TRADCHINESE} "現有安裝"
  LangString existingInstallationPageTitle ${LANG_FARSI} "نصب موجود"
  LangString existingInstallationPageTitle ${LANG_RUSSIAN} "Существующая установка"

  LangString existingInstallationPageSubtitle ${LANG_ENGLISH} "Choose an installation method."
  LangString existingInstallationPageSubtitle ${LANG_SIMPCHINESE} "选择安装方式。"
  LangString existingInstallationPageSubtitle ${LANG_TRADCHINESE} "選擇安裝方式。"
  LangString existingInstallationPageSubtitle ${LANG_FARSI} "روش نصب را انتخاب کنید."
  LangString existingInstallationPageSubtitle ${LANG_RUSSIAN} "Выберите способ установки."

  LangString updateExistingInstallation ${LANG_ENGLISH} "Update"
  LangString updateExistingInstallation ${LANG_SIMPCHINESE} "更新"
  LangString updateExistingInstallation ${LANG_TRADCHINESE} "更新"
  LangString updateExistingInstallation ${LANG_FARSI} "به‌روزرسانی"
  LangString updateExistingInstallation ${LANG_RUSSIAN} "Обновить"

  LangString reinstallExistingInstallation ${LANG_ENGLISH} "Reinstall"
  LangString reinstallExistingInstallation ${LANG_SIMPCHINESE} "重新安装"
  LangString reinstallExistingInstallation ${LANG_TRADCHINESE} "重新安裝"
  LangString reinstallExistingInstallation ${LANG_FARSI} "نصب دوباره"
  LangString reinstallExistingInstallation ${LANG_RUSSIAN} "Переустановить"

  LangString installationMethodPageTitle ${LANG_ENGLISH} "Installation type"
  LangString installationMethodPageTitle ${LANG_SIMPCHINESE} "安装方式"
  LangString installationMethodPageTitle ${LANG_TRADCHINESE} "安裝方式"
  LangString installationMethodPageTitle ${LANG_FARSI} "نوع نصب"
  LangString installationMethodPageTitle ${LANG_RUSSIAN} "Тип установки"

  LangString standardInstallation ${LANG_ENGLISH} "Install"
  LangString standardInstallation ${LANG_SIMPCHINESE} "安装"
  LangString standardInstallation ${LANG_TRADCHINESE} "安裝"
  LangString standardInstallation ${LANG_FARSI} "نصب"
  LangString standardInstallation ${LANG_RUSSIAN} "Установить"

  LangString customInstallation ${LANG_ENGLISH} "Custom install"
  LangString customInstallation ${LANG_SIMPCHINESE} "自定义安装"
  LangString customInstallation ${LANG_TRADCHINESE} "自訂安裝"
  LangString customInstallation ${LANG_FARSI} "نصب سفارشی"
  LangString customInstallation ${LANG_RUSSIAN} "Выборочная установка"

  LangString dataDirectoriesPageTitle ${LANG_ENGLISH} "Installation locations"
  LangString dataDirectoriesPageTitle ${LANG_SIMPCHINESE} "安装位置"
  LangString dataDirectoriesPageTitle ${LANG_TRADCHINESE} "安裝位置"
  LangString dataDirectoriesPageTitle ${LANG_FARSI} "محل‌های نصب"
  LangString dataDirectoriesPageTitle ${LANG_RUSSIAN} "Расположение установки"

  LangString dataDirectoriesPageSubtitle ${LANG_ENGLISH} "Choose the application installation and data directories."
  LangString dataDirectoriesPageSubtitle ${LANG_SIMPCHINESE} "选择应用安装目录和数据目录。"
  LangString dataDirectoriesPageSubtitle ${LANG_TRADCHINESE} "選擇應用程式安裝目錄和資料目錄。"
  LangString dataDirectoriesPageSubtitle ${LANG_FARSI} "پوشه‌های نصب برنامه و داده را انتخاب کنید."
  LangString dataDirectoriesPageSubtitle ${LANG_RUSSIAN} "Выберите каталоги установки приложения и данных."

  LangString applicationDataDirectoryLabel ${LANG_ENGLISH} "Application data directory:"
  LangString applicationDataDirectoryLabel ${LANG_SIMPCHINESE} "应用数据目录："
  LangString applicationDataDirectoryLabel ${LANG_TRADCHINESE} "應用程式資料目錄："
  LangString applicationDataDirectoryLabel ${LANG_FARSI} "پوشهٔ دادهٔ برنامه:"
  LangString applicationDataDirectoryLabel ${LANG_RUSSIAN} "Каталог данных приложения:"

  LangString userIndependentApplicationData ${LANG_ENGLISH} "Use the standard user data directory"
  LangString userIndependentApplicationData ${LANG_SIMPCHINESE} "使用标准用户数据目录"
  LangString userIndependentApplicationData ${LANG_TRADCHINESE} "使用標準使用者資料目錄"
  LangString userIndependentApplicationData ${LANG_FARSI} "استفاده از پوشهٔ استاندارد دادهٔ کاربر"
  LangString userIndependentApplicationData ${LANG_RUSSIAN} "Использовать стандартный каталог данных пользователя"

  LangString daemonDataDirectoryLabel ${LANG_ENGLISH} "Daemon data directory:"
  LangString daemonDataDirectoryLabel ${LANG_SIMPCHINESE} "守护进程数据目录："
  LangString daemonDataDirectoryLabel ${LANG_TRADCHINESE} "守護程序資料目錄："
  LangString daemonDataDirectoryLabel ${LANG_FARSI} "پوشهٔ دادهٔ سرویس:"
  LangString daemonDataDirectoryLabel ${LANG_RUSSIAN} "Каталог данных службы:"

  LangString browseDirectoryButton ${LANG_ENGLISH} "&Browse..."
  LangString browseDirectoryButton ${LANG_SIMPCHINESE} "浏览(&B)..."
  LangString browseDirectoryButton ${LANG_TRADCHINESE} "瀏覽(&B)..."
  LangString browseDirectoryButton ${LANG_FARSI} "&مرور..."
  LangString browseDirectoryButton ${LANG_RUSSIAN} "&Обзор..."

  LangString installationDirectoryLabel ${LANG_ENGLISH} "Application installation directory:"
  LangString installationDirectoryLabel ${LANG_SIMPCHINESE} "应用安装目录："
  LangString installationDirectoryLabel ${LANG_TRADCHINESE} "應用程式安裝目錄："
  LangString installationDirectoryLabel ${LANG_FARSI} "پوشهٔ نصب برنامه:"
  LangString installationDirectoryLabel ${LANG_RUSSIAN} "Каталог установки приложения:"

  LangString taildropVerb ${LANG_ENGLISH} "Send with Taildrop"
  LangString taildropVerb ${LANG_SIMPCHINESE} "使用 Taildrop 发送"
  LangString taildropVerb ${LANG_TRADCHINESE} "使用 Taildrop 傳送"
  LangString taildropVerb ${LANG_FARSI} "ارسال با Taildrop"
  LangString taildropVerb ${LANG_RUSSIAN} "Отправить через Taildrop"

  LangString createDesktopShortcut ${LANG_ENGLISH} "Create a desktop shortcut"
  LangString createDesktopShortcut ${LANG_SIMPCHINESE} "创建桌面快捷方式"
  LangString createDesktopShortcut ${LANG_TRADCHINESE} "建立桌面捷徑"
  LangString createDesktopShortcut ${LANG_FARSI} "ایجاد میان‌بر روی دسکتاپ"
  LangString createDesktopShortcut ${LANG_RUSSIAN} "Создать ярлык на рабочем столе"

  LangString migrateExistingData ${LANG_ENGLISH} "Migrate existing data when a data directory changes"
  LangString migrateExistingData ${LANG_SIMPCHINESE} "数据目录改变时迁移现有数据"
  LangString migrateExistingData ${LANG_TRADCHINESE} "資料目錄變更時遷移現有資料"
  LangString migrateExistingData ${LANG_FARSI} "انتقال داده‌های موجود هنگام تغییر پوشهٔ داده"
  LangString migrateExistingData ${LANG_RUSSIAN} "Перенести существующие данные при изменении каталога"

  LangString migratingExistingData ${LANG_ENGLISH} "Migrating existing sing-box data..."
  LangString migratingExistingData ${LANG_SIMPCHINESE} "正在迁移现有 sing-box 数据..."
  LangString migratingExistingData ${LANG_TRADCHINESE} "正在遷移現有 sing-box 資料..."
  LangString migratingExistingData ${LANG_FARSI} "در حال انتقال داده‌های موجود sing-box..."
  LangString migratingExistingData ${LANG_RUSSIAN} "Перенос существующих данных sing-box..."

  LangString dataMigrationFailed ${LANG_ENGLISH} "Could not migrate the existing data (code $1). No old data was removed."
  LangString dataMigrationFailed ${LANG_SIMPCHINESE} "无法迁移现有数据（代码 $1）；旧数据未被删除。"
  LangString dataMigrationFailed ${LANG_TRADCHINESE} "無法遷移現有資料（代碼 $1）；舊資料未被刪除。"
  LangString dataMigrationFailed ${LANG_FARSI} "انتقال داده‌های موجود ناموفق بود (کد $1). هیچ دادهٔ قدیمی حذف نشد."
  LangString dataMigrationFailed ${LANG_RUSSIAN} "Не удалось перенести существующие данные (код $1). Старые данные не удалены."

  LangString dataMigrationCleanupFailed ${LANG_ENGLISH} "The data migration completed, but the old data could not be removed (code $1). It will be retried by a later installer."
  LangString dataMigrationCleanupFailed ${LANG_SIMPCHINESE} "数据迁移已完成，但无法删除旧数据（代码 $1）；后续安装器将重试清理。"
  LangString dataMigrationCleanupFailed ${LANG_TRADCHINESE} "資料遷移已完成，但無法刪除舊資料（代碼 $1）；後續安裝程式將重試清理。"
  LangString dataMigrationCleanupFailed ${LANG_FARSI} "انتقال داده کامل شد، اما دادهٔ قدیمی حذف نشد (کد $1). نصب‌کنندهٔ بعدی دوباره تلاش می‌کند."
  LangString dataMigrationCleanupFailed ${LANG_RUSSIAN} "Перенос завершён, но старые данные удалить не удалось (код $1). Следующий установщик повторит очистку."

  LangString overlappingDaemonDataDirectory ${LANG_ENGLISH} "The daemon data directory overlaps the application installation directory:$\r$\n$0"
  LangString overlappingDaemonDataDirectory ${LANG_SIMPCHINESE} "守护进程数据目录与应用安装目录重叠：$\r$\n$0"
  LangString overlappingDaemonDataDirectory ${LANG_TRADCHINESE} "守護程序資料目錄與應用程式安裝目錄重疊：$\r$\n$0"
  LangString overlappingDaemonDataDirectory ${LANG_FARSI} "پوشهٔ دادهٔ سرویس با پوشهٔ نصب برنامه هم‌پوشانی دارد:$\r$\n$0"
  LangString overlappingDaemonDataDirectory ${LANG_RUSSIAN} "Каталог данных службы пересекается с каталогом установки приложения:$\r$\n$0"

  LangString invalidDaemonDataDirectory ${LANG_ENGLISH} "The daemon data directory is unsafe or unsupported:$\r$\n$0"
  LangString invalidDaemonDataDirectory ${LANG_SIMPCHINESE} "守护进程数据目录不安全或不受支持：$\r$\n$0"
  LangString invalidDaemonDataDirectory ${LANG_TRADCHINESE} "守護程序資料目錄不安全或不受支援：$\r$\n$0"
  LangString invalidDaemonDataDirectory ${LANG_FARSI} "پوشهٔ دادهٔ سرویس ناامن است یا پشتیبانی نمی‌شود:$\r$\n$0"
  LangString invalidDaemonDataDirectory ${LANG_RUSSIAN} "Каталог данных службы небезопасен или не поддерживается:$\r$\n$0"

  LangString overlappingApplicationDataDirectory ${LANG_ENGLISH} "The application data directory overlaps the application installation directory or daemon data directory:$\r$\n$0"
  LangString overlappingApplicationDataDirectory ${LANG_SIMPCHINESE} "应用数据目录与应用安装目录或守护进程数据目录重叠：$\r$\n$0"
  LangString overlappingApplicationDataDirectory ${LANG_TRADCHINESE} "應用程式資料目錄與應用程式安裝目錄或守護程序資料目錄重疊：$\r$\n$0"
  LangString overlappingApplicationDataDirectory ${LANG_FARSI} "پوشهٔ دادهٔ برنامه با پوشهٔ نصب برنامه یا پوشهٔ دادهٔ سرویس هم‌پوشانی دارد:$\r$\n$0"
  LangString overlappingApplicationDataDirectory ${LANG_RUSSIAN} "Каталог данных приложения пересекается с каталогом установки приложения или каталогом данных службы:$\r$\n$0"

  LangString invalidApplicationDataDirectory ${LANG_ENGLISH} "The application data directory is invalid, unsafe, or unsupported:$\r$\n$0"
  LangString invalidApplicationDataDirectory ${LANG_SIMPCHINESE} "应用数据目录无效、不安全或不受支持：$\r$\n$0"
  LangString invalidApplicationDataDirectory ${LANG_TRADCHINESE} "應用程式資料目錄無效、不安全或不受支援：$\r$\n$0"
  LangString invalidApplicationDataDirectory ${LANG_FARSI} "پوشهٔ دادهٔ برنامه نامعتبر، ناامن یا پشتیبانی‌نشده است:$\r$\n$0"
  LangString invalidApplicationDataDirectory ${LANG_RUSSIAN} "Каталог данных приложения недопустим, небезопасен или не поддерживается:$\r$\n$0"

  LangString stoppingService ${LANG_ENGLISH} "Stopping the sing-box service..."
  LangString stoppingService ${LANG_SIMPCHINESE} "正在停止 sing-box 守护进程..."
  LangString stoppingService ${LANG_TRADCHINESE} "正在停止 sing-box 守護程序..."
  LangString stoppingService ${LANG_FARSI} "در حال توقف سرویس sing-box..."
  LangString stoppingService ${LANG_RUSSIAN} "Остановка службы sing-box..."

  LangString checkingRunningApplication ${LANG_ENGLISH} "Checking for running sing-box applications..."
  LangString checkingRunningApplication ${LANG_SIMPCHINESE} "正在检查运行中的 sing-box 应用..."
  LangString checkingRunningApplication ${LANG_TRADCHINESE} "正在檢查執行中的 sing-box 應用程式..."
  LangString checkingRunningApplication ${LANG_FARSI} "در حال بررسی برنامه‌های در حال اجرای sing-box..."
  LangString checkingRunningApplication ${LANG_RUSSIAN} "Проверка запущенных приложений sing-box..."

  LangString closingApplication ${LANG_ENGLISH} "Closing sing-box..."
  LangString closingApplication ${LANG_SIMPCHINESE} "正在关闭 sing-box 应用..."
  LangString closingApplication ${LANG_TRADCHINESE} "正在關閉 sing-box 應用程式..."
  LangString closingApplication ${LANG_FARSI} "در حال بستن sing-box..."
  LangString closingApplication ${LANG_RUSSIAN} "Закрытие sing-box..."

  LangString checkingInstallationLocations ${LANG_ENGLISH} "Checking installation locations..."
  LangString checkingInstallationLocations ${LANG_SIMPCHINESE} "正在检查安装位置..."
  LangString checkingInstallationLocations ${LANG_TRADCHINESE} "正在檢查安裝位置..."
  LangString checkingInstallationLocations ${LANG_FARSI} "در حال بررسی محل‌های نصب..."
  LangString checkingInstallationLocations ${LANG_RUSSIAN} "Проверка расположения установки..."

  LangString preparingApplicationDataDirectory ${LANG_ENGLISH} "Preparing the application data directory..."
  LangString preparingApplicationDataDirectory ${LANG_SIMPCHINESE} "正在准备应用数据目录..."
  LangString preparingApplicationDataDirectory ${LANG_TRADCHINESE} "正在準備應用程式資料目錄..."
  LangString preparingApplicationDataDirectory ${LANG_FARSI} "در حال آماده‌سازی پوشهٔ دادهٔ برنامه..."
  LangString preparingApplicationDataDirectory ${LANG_RUSSIAN} "Подготовка каталога данных приложения..."

  LangString removingPreviousVersion ${LANG_ENGLISH} "Removing the previous version..."
  LangString removingPreviousVersion ${LANG_SIMPCHINESE} "正在移除先前版本..."
  LangString removingPreviousVersion ${LANG_TRADCHINESE} "正在移除先前版本..."
  LangString removingPreviousVersion ${LANG_FARSI} "در حال حذف نسخهٔ قبلی..."
  LangString removingPreviousVersion ${LANG_RUSSIAN} "Удаление предыдущей версии..."

  LangString completingDataMigration ${LANG_ENGLISH} "Completing data migration..."
  LangString completingDataMigration ${LANG_SIMPCHINESE} "正在完成数据迁移..."
  LangString completingDataMigration ${LANG_TRADCHINESE} "正在完成資料移轉..."
  LangString completingDataMigration ${LANG_FARSI} "در حال تکمیل انتقال داده‌ها..."
  LangString completingDataMigration ${LANG_RUSSIAN} "Завершение переноса данных..."

  LangString stopServiceFailed ${LANG_ENGLISH} "Failed to stop the sing-box service."
  LangString stopServiceFailed ${LANG_SIMPCHINESE} "无法停止 sing-box 守护进程。"
  LangString stopServiceFailed ${LANG_TRADCHINESE} "無法停止 sing-box 守護程序。"
  LangString stopServiceFailed ${LANG_FARSI} "توقف سرویس sing-box ناموفق بود."
  LangString stopServiceFailed ${LANG_RUSSIAN} "Не удалось остановить службу sing-box."

  LangString previousUninstallerFailed ${LANG_ENGLISH} "The previous uninstaller returned code $R0; continuing the upgrade."
  LangString previousUninstallerFailed ${LANG_SIMPCHINESE} "旧版本卸载程序返回代码 $R0；继续升级。"
  LangString previousUninstallerFailed ${LANG_TRADCHINESE} "舊版本解除安裝程式傳回代碼 $R0；繼續升級。"
  LangString previousUninstallerFailed ${LANG_FARSI} "حذف‌کنندهٔ نسخهٔ قبلی کد $R0 را برگرداند؛ ارتقا ادامه می‌یابد."
  LangString previousUninstallerFailed ${LANG_RUSSIAN} "Программа удаления предыдущей версии вернула код $R0; обновление будет продолжено."

  LangString architectureMismatchPrompt ${LANG_ENGLISH} "This installer contains the $0 build, but the native Windows architecture is $1.$\r$\n$\r$\nFor the best compatibility and performance, use the native installer. Continue anyway?"
  LangString architectureMismatchPrompt ${LANG_SIMPCHINESE} "此安装程序包含 $0 版本，但 Windows 的原生架构为 $1。$\r$\n$\r$\n为了获得最佳兼容性和性能，请改用原生安装程序。仍要继续吗？"
  LangString architectureMismatchPrompt ${LANG_TRADCHINESE} "此安裝程式包含 $0 版本，但 Windows 的原生架構為 $1。$\r$\n$\r$\n為了獲得最佳相容性與效能，請改用原生安裝程式。仍要繼續嗎？"
  LangString architectureMismatchPrompt ${LANG_FARSI} "این نصب‌کننده شامل نسخهٔ $0 است، اما معماری بومی ویندوز $1 است.$\r$\n$\r$\nبرای بهترین سازگاری و کارایی، از نصب‌کنندهٔ بومی استفاده کنید. با این حال ادامه می‌دهید؟"
  LangString architectureMismatchPrompt ${LANG_RUSSIAN} "Этот установщик содержит сборку $0, но собственная архитектура Windows — $1.$\r$\n$\r$\nДля лучшей совместимости и производительности используйте нативный установщик. Всё равно продолжить?"

  LangString unknownNativeArchitecture ${LANG_ENGLISH} "unknown"
  LangString unknownNativeArchitecture ${LANG_SIMPCHINESE} "未知"
  LangString unknownNativeArchitecture ${LANG_TRADCHINESE} "未知"
  LangString unknownNativeArchitecture ${LANG_FARSI} "ناشناخته"
  LangString unknownNativeArchitecture ${LANG_RUSSIAN} "неизвестна"

  LangString registeringService ${LANG_ENGLISH} "Registering the sing-box service..."
  LangString registeringService ${LANG_SIMPCHINESE} "正在注册 sing-box 守护进程..."
  LangString registeringService ${LANG_TRADCHINESE} "正在註冊 sing-box 守護程序..."
  LangString registeringService ${LANG_FARSI} "در حال ثبت سرویس sing-box..."
  LangString registeringService ${LANG_RUSSIAN} "Регистрация службы sing-box..."

  LangString registerServiceFailed ${LANG_ENGLISH} "Failed to register the sing-box service (code $1)."
  LangString registerServiceFailed ${LANG_SIMPCHINESE} "无法注册 sing-box 守护进程（代码 $1）。"
  LangString registerServiceFailed ${LANG_TRADCHINESE} "無法註冊 sing-box 守護程序（代碼 $1）。"
  LangString registerServiceFailed ${LANG_FARSI} "ثبت سرویس sing-box ناموفق بود (کد $1)."
  LangString registerServiceFailed ${LANG_RUSSIAN} "Не удалось зарегистрировать службу sing-box (код $1)."

  LangString serviceCommandNoDetails ${LANG_ENGLISH} "The service command produced no diagnostic output."
  LangString serviceCommandNoDetails ${LANG_SIMPCHINESE} "守护进程管理命令未产生诊断输出。"
  LangString serviceCommandNoDetails ${LANG_TRADCHINESE} "守護程序管理命令未產生診斷輸出。"
  LangString serviceCommandNoDetails ${LANG_FARSI} "فرمان سرویس هیچ خروجی عیب‌یابی ایجاد نکرد."
  LangString serviceCommandNoDetails ${LANG_RUSSIAN} "Команда службы не вывела диагностических данных."

  LangString copyingApplicationFiles ${LANG_ENGLISH} "Copying sing-box application files..."
  LangString copyingApplicationFiles ${LANG_SIMPCHINESE} "正在复制 sing-box 应用程序文件..."
  LangString copyingApplicationFiles ${LANG_TRADCHINESE} "正在複製 sing-box 應用程式檔案..."
  LangString copyingApplicationFiles ${LANG_FARSI} "در حال کپی فایل‌های برنامهٔ sing-box..."
  LangString copyingApplicationFiles ${LANG_RUSSIAN} "Копирование файлов приложения sing-box..."

  LangString rollingBackInstallation ${LANG_ENGLISH} "The service setup failed. Removing the installed application..."
  LangString rollingBackInstallation ${LANG_SIMPCHINESE} "守护进程设置失败，正在移除已安装的应用程序..."
  LangString rollingBackInstallation ${LANG_TRADCHINESE} "守護程序設定失敗，正在移除已安裝的應用程式..."
  LangString rollingBackInstallation ${LANG_FARSI} "راه‌اندازی سرویس ناموفق بود. برنامهٔ نصب‌شده در حال حذف است..."
  LangString rollingBackInstallation ${LANG_RUSSIAN} "Не удалось настроить службу. Удаление установленного приложения..."

  LangString registerServiceFailedRolledBack ${LANG_ENGLISH} "Failed to register the sing-box service (code $1). The installed application was removed.$\r$\n$\r$\n$3"
  LangString registerServiceFailedRolledBack ${LANG_SIMPCHINESE} "无法注册 sing-box 守护进程（代码 $1）。已移除安装的应用程序。$\r$\n$\r$\n$3"
  LangString registerServiceFailedRolledBack ${LANG_TRADCHINESE} "無法註冊 sing-box 守護程序（代碼 $1）。已移除安裝的應用程式。$\r$\n$\r$\n$3"
  LangString registerServiceFailedRolledBack ${LANG_FARSI} "ثبت سرویس sing-box ناموفق بود (کد $1). برنامهٔ نصب‌شده حذف شد.$\r$\n$\r$\n$3"
  LangString registerServiceFailedRolledBack ${LANG_RUSSIAN} "Не удалось зарегистрировать службу sing-box (код $1). Установленное приложение удалено.$\r$\n$\r$\n$3"

  LangString registerServiceFailedRollbackFailed ${LANG_ENGLISH} "Failed to register the sing-box service (code $1), and automatic removal failed (code $2).$\r$\n$\r$\n$3"
  LangString registerServiceFailedRollbackFailed ${LANG_SIMPCHINESE} "无法注册 sing-box 守护进程（代码 $1），且自动移除失败（代码 $2）。$\r$\n$\r$\n$3"
  LangString registerServiceFailedRollbackFailed ${LANG_TRADCHINESE} "無法註冊 sing-box 守護程序（代碼 $1），且自動移除失敗（代碼 $2）。$\r$\n$\r$\n$3"
  LangString registerServiceFailedRollbackFailed ${LANG_FARSI} "ثبت سرویس sing-box ناموفق بود (کد $1) و حذف خودکار نیز ناموفق بود (کد $2).$\r$\n$\r$\n$3"
  LangString registerServiceFailedRollbackFailed ${LANG_RUSSIAN} "Не удалось зарегистрировать службу sing-box (код $1), а автоматическое удаление завершилось ошибкой (код $2).$\r$\n$\r$\n$3"

  LangString unsafeInstallationDirectory ${LANG_ENGLISH} "The installation directory contains a reparse point or is not a normal directory:$\r$\n$INSTDIR"
  LangString unsafeInstallationDirectory ${LANG_SIMPCHINESE} "安装目录包含重解析点或不是普通目录：$\r$\n$INSTDIR"
  LangString unsafeInstallationDirectory ${LANG_TRADCHINESE} "安裝目錄包含重新解析點或不是一般目錄：$\r$\n$INSTDIR"
  LangString unsafeInstallationDirectory ${LANG_FARSI} "پوشهٔ نصب دارای نقطهٔ بازتحلیل است یا پوشهٔ عادی نیست:$\r$\n$INSTDIR"
  LangString unsafeInstallationDirectory ${LANG_RUSSIAN} "Каталог установки содержит точку повторной обработки или не является обычным каталогом:$\r$\n$INSTDIR"

  LangString invalidInstallationAncestor ${LANG_ENGLISH} "An installation path ancestor is not a normal directory or contains a reparse point:$\r$\n$0"
  LangString invalidInstallationAncestor ${LANG_SIMPCHINESE} "安装路径的上级目录不是普通目录或包含重解析点：$\r$\n$0"
  LangString invalidInstallationAncestor ${LANG_TRADCHINESE} "安裝路徑的上層目錄不是一般目錄或包含重新解析點：$\r$\n$0"
  LangString invalidInstallationAncestor ${LANG_FARSI} "یکی از پوشه‌های بالادستی مسیر نصب، پوشهٔ عادی نیست یا نقطهٔ بازتحلیل دارد:$\r$\n$0"
  LangString invalidInstallationAncestor ${LANG_RUSSIAN} "Родительский каталог пути установки не является обычным каталогом или содержит точку повторной обработки:$\r$\n$0"

  LangString unsafeInstallationPageTitle ${LANG_ENGLISH} "Unsafe installation path"
  LangString unsafeInstallationPageTitle ${LANG_SIMPCHINESE} "安装路径不安全"
  LangString unsafeInstallationPageTitle ${LANG_TRADCHINESE} "安裝路徑不安全"
  LangString unsafeInstallationPageTitle ${LANG_FARSI} "مسیر نصب ناامن"
  LangString unsafeInstallationPageTitle ${LANG_RUSSIAN} "Небезопасный путь установки"

  LangString unsafeInstallationPageSubtitle ${LANG_ENGLISH} "Repair the path when possible or continue with unsafe installation."
  LangString unsafeInstallationPageSubtitle ${LANG_SIMPCHINESE} "可修复时修复路径，或继续不安全安装。"
  LangString unsafeInstallationPageSubtitle ${LANG_TRADCHINESE} "可修復時修復路徑，或繼續不安全安裝。"
  LangString unsafeInstallationPageSubtitle ${LANG_FARSI} "در صورت امکان مسیر را اصلاح کنید یا نصب ناامن را ادامه دهید."
  LangString unsafeInstallationPageSubtitle ${LANG_RUSSIAN} "Исправьте путь, если это возможно, или продолжите небезопасную установку."

  LangString repairPathPermissionsPageTitle ${LANG_ENGLISH} "Unsafe path permissions"
  LangString repairPathPermissionsPageTitle ${LANG_SIMPCHINESE} "路径权限不安全"
  LangString repairPathPermissionsPageTitle ${LANG_TRADCHINESE} "路徑權限不安全"
  LangString repairPathPermissionsPageTitle ${LANG_FARSI} "مجوزهای مسیر ناامن"
  LangString repairPathPermissionsPageTitle ${LANG_RUSSIAN} "Небезопасные разрешения пути"

  LangString repairPathPermissionsPageSubtitle ${LANG_ENGLISH} "Repair the permissions or continue with unsafe installation."
  LangString repairPathPermissionsPageSubtitle ${LANG_SIMPCHINESE} "修复权限，或继续不安全安装。"
  LangString repairPathPermissionsPageSubtitle ${LANG_TRADCHINESE} "修復權限，或繼續不安全安裝。"
  LangString repairPathPermissionsPageSubtitle ${LANG_FARSI} "مجوزها را اصلاح کنید یا نصب ناامن را ادامه دهید."
  LangString repairPathPermissionsPageSubtitle ${LANG_RUSSIAN} "Исправьте разрешения или продолжите небезопасную установку."

  LangString unsafeInstallationPageBody ${LANG_ENGLISH} "An unprivileged account can replace this installation path ancestor:$\r$\n$unsafeInstallationAncestor$\r$\n$\r$\nRepair removes only the dangerous permissions. Unsafe installation leaves the path unchanged."
  LangString unsafeInstallationPageBody ${LANG_SIMPCHINESE} "非管理员账户可以替换此安装路径的上级目录：$\r$\n$unsafeInstallationAncestor$\r$\n$\r$\n修复只会移除危险权限。不安全安装会保持此路径不变。"
  LangString unsafeInstallationPageBody ${LANG_TRADCHINESE} "非系統管理員帳戶可以取代此安裝路徑的上層目錄：$\r$\n$unsafeInstallationAncestor$\r$\n$\r$\n修復只會移除危險權限。不安全安裝會保持此路徑不變。"
  LangString unsafeInstallationPageBody ${LANG_FARSI} "یک حساب غیرمدیر می‌تواند این پوشهٔ بالادستی مسیر نصب را جایگزین کند:$\r$\n$unsafeInstallationAncestor$\r$\n$\r$\nاصلاح فقط مجوزهای خطرناک را حذف می‌کند. نصب ناامن مسیر را بدون تغییر نگه می‌دارد."
  LangString unsafeInstallationPageBody ${LANG_RUSSIAN} "Учетная запись без прав администратора может заменить этот родительский каталог:$\r$\n$unsafeInstallationAncestor$\r$\n$\r$\nИсправление удалит только опасные разрешения. Небезопасная установка оставит путь без изменений."

  LangString unsafeDaemonDataDirectoryPageBody ${LANG_ENGLISH} "An unprivileged account can replace this daemon data path ancestor:$\r$\n$unsafeInstallationAncestor$\r$\n$\r$\nRepair removes only the dangerous permissions. Unsafe installation leaves the path unchanged."
  LangString unsafeDaemonDataDirectoryPageBody ${LANG_SIMPCHINESE} "非管理员账户可以替换此守护进程数据路径的上级目录：$\r$\n$unsafeInstallationAncestor$\r$\n$\r$\n修复只会移除危险权限。不安全安装会保持此路径不变。"
  LangString unsafeDaemonDataDirectoryPageBody ${LANG_TRADCHINESE} "非系統管理員帳戶可以取代此守護程序資料路徑的上層目錄：$\r$\n$unsafeInstallationAncestor$\r$\n$\r$\n修復只會移除危險權限。不安全安裝會保持此路徑不變。"
  LangString unsafeDaemonDataDirectoryPageBody ${LANG_FARSI} "یک حساب غیرمدیر می‌تواند این پوشهٔ بالادستی مسیر دادهٔ سرویس را جایگزین کند:$\r$\n$unsafeInstallationAncestor$\r$\n$\r$\nاصلاح فقط مجوزهای خطرناک را حذف می‌کند. نصب ناامن مسیر را بدون تغییر نگه می‌دارد."
  LangString unsafeDaemonDataDirectoryPageBody ${LANG_RUSSIAN} "Учетная запись без прав администратора может заменить этот родительский каталог пути данных службы:$\r$\n$unsafeInstallationAncestor$\r$\n$\r$\nИсправление удалит только опасные разрешения. Небезопасная установка оставит путь без изменений."

  LangString unsafeApplicationDataDirectoryPageBody ${LANG_ENGLISH} "An unprivileged account can replace this application data path ancestor:$\r$\n$unsafeInstallationAncestor$\r$\n$\r$\nRepair removes only the dangerous permissions. Unsafe installation leaves the path unchanged."
  LangString unsafeApplicationDataDirectoryPageBody ${LANG_SIMPCHINESE} "非管理员账户可以替换此应用数据路径的上级目录：$\r$\n$unsafeInstallationAncestor$\r$\n$\r$\n修复只会移除危险权限。不安全安装会保持此路径不变。"
  LangString unsafeApplicationDataDirectoryPageBody ${LANG_TRADCHINESE} "非系統管理員帳戶可以取代此應用程式資料路徑的上層目錄：$\r$\n$unsafeInstallationAncestor$\r$\n$\r$\n修復只會移除危險權限。不安全安裝會保持此路徑不變。"
  LangString unsafeApplicationDataDirectoryPageBody ${LANG_FARSI} "یک حساب غیرمدیر می‌تواند این پوشهٔ بالادستی مسیر دادهٔ برنامه را جایگزین کند:$\r$\n$unsafeInstallationAncestor$\r$\n$\r$\nاصلاح فقط مجوزهای خطرناک را حذف می‌کند. نصب ناامن مسیر را بدون تغییر نگه می‌دارد."
  LangString unsafeApplicationDataDirectoryPageBody ${LANG_RUSSIAN} "Учетная запись без прав администратора может заменить этот родительский каталог пути данных приложения:$\r$\n$unsafeInstallationAncestor$\r$\n$\r$\nИсправление удалит только опасные разрешения. Небезопасная установка оставит путь без изменений."

  LangString repairInstallationPermissionsButton ${LANG_ENGLISH} "&Repair permissions"
  LangString repairInstallationPermissionsButton ${LANG_SIMPCHINESE} "修复权限(&R)"
  LangString repairInstallationPermissionsButton ${LANG_TRADCHINESE} "修復權限(&R)"
  LangString repairInstallationPermissionsButton ${LANG_FARSI} "&اصلاح مجوزها"
  LangString repairInstallationPermissionsButton ${LANG_RUSSIAN} "&Исправить разрешения"

  LangString repairingInstallationPermissions ${LANG_ENGLISH} "Repairing path permissions..."
  LangString repairingInstallationPermissions ${LANG_SIMPCHINESE} "正在修复路径权限..."
  LangString repairingInstallationPermissions ${LANG_TRADCHINESE} "正在修復路徑權限..."
  LangString repairingInstallationPermissions ${LANG_FARSI} "در حال اصلاح مجوزهای مسیر..."
  LangString repairingInstallationPermissions ${LANG_RUSSIAN} "Исправление разрешений пути..."

  LangString unsafeInstallationButton ${LANG_ENGLISH} "&Unsafe installation"
  LangString unsafeInstallationButton ${LANG_SIMPCHINESE} "不安全安装(&U)"
  LangString unsafeInstallationButton ${LANG_TRADCHINESE} "不安全安裝(&U)"
  LangString unsafeInstallationButton ${LANG_FARSI} "&نصب ناامن"
  LangString unsafeInstallationButton ${LANG_RUSSIAN} "&Небезопасная установка"

  LangString unsafeInstallationConfirmationTitle ${LANG_ENGLISH} "Confirm unsafe installation"
  LangString unsafeInstallationConfirmationTitle ${LANG_SIMPCHINESE} "确认不安全安装"
  LangString unsafeInstallationConfirmationTitle ${LANG_TRADCHINESE} "確認不安全安裝"
  LangString unsafeInstallationConfirmationTitle ${LANG_FARSI} "تأیید نصب ناامن"
  LangString unsafeInstallationConfirmationTitle ${LANG_RUSSIAN} "Подтверждение небезопасной установки"

  LangString unsafeInstallationConfirmationSubtitle ${LANG_ENGLISH} "Select the acknowledgement below to continue."
  LangString unsafeInstallationConfirmationSubtitle ${LANG_SIMPCHINESE} "必须勾选下方确认项才能继续。"
  LangString unsafeInstallationConfirmationSubtitle ${LANG_TRADCHINESE} "必須勾選下方確認項才能繼續。"
  LangString unsafeInstallationConfirmationSubtitle ${LANG_FARSI} "برای ادامه باید تأیید زیر را انتخاب کنید."
  LangString unsafeInstallationConfirmationSubtitle ${LANG_RUSSIAN} "Чтобы продолжить, установите флажок подтверждения ниже."

  LangString unsafeInstallationConfirmationWarning ${LANG_ENGLISH} "The installer and service will skip path security checks and permission hardening. This can allow another program to replace sing-box data or binaries and elevate privileges to SYSTEM."
  LangString unsafeInstallationConfirmationWarning ${LANG_SIMPCHINESE} "安装程序和守护进程将跳过路径安全检查与权限加固。这可能允许其他程序替换 sing-box 数据或程序文件并提权到 SYSTEM。"
  LangString unsafeInstallationConfirmationWarning ${LANG_TRADCHINESE} "安裝程式和守護程序將略過路徑安全檢查與權限強化。這可能允許其他程式取代 sing-box 資料或程式檔案並將權限提升至 SYSTEM。"
  LangString unsafeInstallationConfirmationWarning ${LANG_FARSI} "نصب‌کننده و سرویس، بررسی امنیت مسیر و ایمن‌سازی مجوزها را نادیده می‌گیرند. این کار ممکن است به برنامه‌ای دیگر اجازه دهد داده‌ها یا فایل‌های sing-box را جایگزین کند و سطح دسترسی را به SYSTEM برساند."
  LangString unsafeInstallationConfirmationWarning ${LANG_RUSSIAN} "Установщик и служба пропустят проверку безопасности путей и усиление разрешений. Другая программа сможет подменить данные или файлы sing-box и повысить привилегии до SYSTEM."

  LangString unsafeInstallationAcknowledgement ${LANG_ENGLISH} "I understand and accept this security risk."
  LangString unsafeInstallationAcknowledgement ${LANG_SIMPCHINESE} "我理解并接受此安全风险。"
  LangString unsafeInstallationAcknowledgement ${LANG_TRADCHINESE} "我理解並接受此安全風險。"
  LangString unsafeInstallationAcknowledgement ${LANG_FARSI} "این خطر امنیتی را درک می‌کنم و می‌پذیرم."
  LangString unsafeInstallationAcknowledgement ${LANG_RUSSIAN} "Я понимаю и принимаю этот риск безопасности."

  LangString continueUnsafeInstallationButton ${LANG_ENGLISH} "Continue unsafe installation"
  LangString continueUnsafeInstallationButton ${LANG_SIMPCHINESE} "继续不安全安装"
  LangString continueUnsafeInstallationButton ${LANG_TRADCHINESE} "繼續不安全安裝"
  LangString continueUnsafeInstallationButton ${LANG_FARSI} "ادامهٔ نصب ناامن"
  LangString continueUnsafeInstallationButton ${LANG_RUSSIAN} "Продолжить небезопасную установку"

  LangString returnToInstallationChoiceButton ${LANG_ENGLISH} "Return"
  LangString returnToInstallationChoiceButton ${LANG_SIMPCHINESE} "返回"
  LangString returnToInstallationChoiceButton ${LANG_TRADCHINESE} "返回"
  LangString returnToInstallationChoiceButton ${LANG_FARSI} "بازگشت"
  LangString returnToInstallationChoiceButton ${LANG_RUSSIAN} "Вернуться"

  LangString invalidInstallationPageTitle ${LANG_ENGLISH} "Unsupported installation path"
  LangString invalidInstallationPageTitle ${LANG_SIMPCHINESE} "不支持的安装路径"
  LangString invalidInstallationPageTitle ${LANG_TRADCHINESE} "不支援的安裝路徑"
  LangString invalidInstallationPageTitle ${LANG_FARSI} "مسیر نصب پشتیبانی‌نشده"
  LangString invalidInstallationPageTitle ${LANG_RUSSIAN} "Неподдерживаемый путь установки"

  LangString invalidInstallationPageSubtitle ${LANG_ENGLISH} "The installer cannot continue with this path."
  LangString invalidInstallationPageSubtitle ${LANG_SIMPCHINESE} "安装程序无法继续使用此路径。"
  LangString invalidInstallationPageSubtitle ${LANG_TRADCHINESE} "安裝程式無法繼續使用此路徑。"
  LangString invalidInstallationPageSubtitle ${LANG_FARSI} "نصب‌کننده نمی‌تواند با این مسیر ادامه دهد."
  LangString invalidInstallationPageSubtitle ${LANG_RUSSIAN} "Установщик не может продолжить с этим путем."

  LangString untrustedInstallationAncestor ${LANG_ENGLISH} "The installer cannot guarantee the permissions of this installation path ancestor:$\r$\n$0"
  LangString untrustedInstallationAncestor ${LANG_SIMPCHINESE} "安装程序无法保证此安装路径上级目录的权限：$\r$\n$0"
  LangString untrustedInstallationAncestor ${LANG_TRADCHINESE} "安裝程式無法保證此安裝路徑上層目錄的權限：$\r$\n$0"
  LangString untrustedInstallationAncestor ${LANG_FARSI} "نصب‌کننده نمی‌تواند مجوزهای این پوشهٔ بالادستی مسیر نصب را تضمین کند:$\r$\n$0"
  LangString untrustedInstallationAncestor ${LANG_RUSSIAN} "Установщик не может гарантировать разрешения этого родительского каталога:$\r$\n$0"

  LangString installationDriveNotFixed ${LANG_ENGLISH} "This path is not on a fixed local drive:$\r$\n$0"
  LangString installationDriveNotFixed ${LANG_SIMPCHINESE} "此路径不在固定的本地磁盘上：$\r$\n$0"
  LangString installationDriveNotFixed ${LANG_TRADCHINESE} "此路徑不在固定的本機磁碟上：$\r$\n$0"
  LangString installationDriveNotFixed ${LANG_FARSI} "این مسیر روی یک درایو محلی ثابت نیست:$\r$\n$0"
  LangString installationDriveNotFixed ${LANG_RUSSIAN} "Этот путь находится не на постоянном локальном диске:$\r$\n$0"

  LangString installationFileSystemNotNTFS ${LANG_ENGLISH} "This path uses the $0 file system instead of NTFS. Permission hardening cannot be guaranteed."
  LangString installationFileSystemNotNTFS ${LANG_SIMPCHINESE} "此路径使用 $0 文件系统，而不是 NTFS，无法保证权限加固。"
  LangString installationFileSystemNotNTFS ${LANG_TRADCHINESE} "此路徑使用 $0 檔案系統，而不是 NTFS，無法保證權限強化。"
  LangString installationFileSystemNotNTFS ${LANG_FARSI} "این مسیر به‌جای NTFS از فایل‌سیستم $0 استفاده می‌کند و ایمن‌سازی مجوزها تضمین نمی‌شود."
  LangString installationFileSystemNotNTFS ${LANG_RUSSIAN} "Этот путь использует файловую систему $0 вместо NTFS; усиление разрешений не гарантируется."

  LangString installationVolumeNotVerified ${LANG_ENGLISH} "The installer could not verify the installation volume:$\r$\n$0"
  LangString installationVolumeNotVerified ${LANG_SIMPCHINESE} "安装程序无法验证安装卷：$\r$\n$0"
  LangString installationVolumeNotVerified ${LANG_TRADCHINESE} "安裝程式無法驗證安裝磁碟區：$\r$\n$0"
  LangString installationVolumeNotVerified ${LANG_FARSI} "نصب‌کننده نتوانست درایو نصب را بررسی کند:$\r$\n$0"
  LangString installationVolumeNotVerified ${LANG_RUSSIAN} "Установщик не смог проверить том установки:$\r$\n$0"

  LangString repairInstallationAncestorFailed ${LANG_ENGLISH} "Could not repair the path permissions (code $1). No application files were installed."
  LangString repairInstallationAncestorFailed ${LANG_SIMPCHINESE} "无法修复路径权限（代码 $1）。尚未安装任何应用程序文件。"
  LangString repairInstallationAncestorFailed ${LANG_TRADCHINESE} "無法修復路徑權限（代碼 $1）。尚未安裝任何應用程式檔案。"
  LangString repairInstallationAncestorFailed ${LANG_FARSI} "اصلاح مجوزهای مسیر ممکن نشد (کد $1). هیچ فایل برنامه‌ای نصب نشد."
  LangString repairInstallationAncestorFailed ${LANG_RUSSIAN} "Не удалось исправить разрешения пути (код $1). Файлы приложения ещё не устанавливались."

  !ifndef BUILD_UNINSTALLER
  LangString resetWorkingDirectoryPrompt ${LANG_ENGLISH} "The sing-box service data directory is invalid:$\r$\n$workingDirectory$\r$\nContinuing will delete this directory so the service can recreate it securely. Continue?"
  LangString resetWorkingDirectoryPrompt ${LANG_SIMPCHINESE} "sing-box 守护进程数据目录无效：$\r$\n$workingDirectory$\r$\n继续安装将删除此目录，以便守护进程用安全权限重新创建。是否继续？"
  LangString resetWorkingDirectoryPrompt ${LANG_TRADCHINESE} "sing-box 守護程序資料目錄無效：$\r$\n$workingDirectory$\r$\n繼續安裝將刪除此目錄，以便守護程序用安全權限重新建立。是否繼續？"
  LangString resetWorkingDirectoryPrompt ${LANG_FARSI} "پوشهٔ دادهٔ سرویس sing-box نامعتبر است:$\r$\n$workingDirectory$\r$\nبا ادامه، این پوشه حذف می‌شود تا سرویس آن را با مجوزهای امن دوباره ایجاد کند. ادامه می‌دهید؟"
  LangString resetWorkingDirectoryPrompt ${LANG_RUSSIAN} "Каталог данных службы sing-box недействителен:$\r$\n$workingDirectory$\r$\nПри продолжении каталог будет удалён, чтобы служба могла безопасно создать его заново. Продолжить?"

  LangString resettingWorkingDirectory ${LANG_ENGLISH} "Resetting the sing-box service data directory..."
  LangString resettingWorkingDirectory ${LANG_SIMPCHINESE} "正在重置 sing-box 守护进程数据目录..."
  LangString resettingWorkingDirectory ${LANG_TRADCHINESE} "正在重設 sing-box 守護程序資料目錄..."
  LangString resettingWorkingDirectory ${LANG_FARSI} "در حال بازنشانی پوشهٔ دادهٔ سرویس sing-box..."
  LangString resettingWorkingDirectory ${LANG_RUSSIAN} "Сброс каталога данных службы sing-box..."

  LangString resetWorkingDirectoryFailed ${LANG_ENGLISH} "Could not reset the sing-box service data directory (code $1). No application files were installed."
  LangString resetWorkingDirectoryFailed ${LANG_SIMPCHINESE} "无法重置 sing-box 守护进程数据目录（代码 $1）。尚未安装任何应用程序文件。"
  LangString resetWorkingDirectoryFailed ${LANG_TRADCHINESE} "無法重設 sing-box 守護程序資料目錄（代碼 $1）。尚未安裝任何應用程式檔案。"
  LangString resetWorkingDirectoryFailed ${LANG_FARSI} "بازنشانی پوشهٔ دادهٔ سرویس sing-box ممکن نشد (کد $1). هیچ فایل برنامه‌ای نصب نشد."
  LangString resetWorkingDirectoryFailed ${LANG_RUSSIAN} "Не удалось сбросить каталог данных службы sing-box (код $1). Файлы приложения ещё не устанавливались."
  !endif

  LangString preflightFailed ${LANG_ENGLISH} "Could not validate the installation directories (code $1)."
  LangString preflightFailed ${LANG_SIMPCHINESE} "无法验证安装目录（代码 $1）。"
  LangString preflightFailed ${LANG_TRADCHINESE} "無法驗證安裝目錄（代碼 $1）。"
  LangString preflightFailed ${LANG_FARSI} "اعتبارسنجی پوشه‌های نصب ممکن نشد (کد $1)."
  LangString preflightFailed ${LANG_RUSSIAN} "Не удалось проверить каталоги установки (код $1)."

  LangString removingService ${LANG_ENGLISH} "Removing the sing-box service..."
  LangString removingService ${LANG_SIMPCHINESE} "正在移除 sing-box 守护进程..."
  LangString removingService ${LANG_TRADCHINESE} "正在移除 sing-box 守護程序..."
  LangString removingService ${LANG_FARSI} "در حال حذف سرویس sing-box..."
  LangString removingService ${LANG_RUSSIAN} "Удаление службы sing-box..."

  LangString removeServiceFailed ${LANG_ENGLISH} "Failed to remove the sing-box service (code $1).$\r$\n$\r$\n$3"
  LangString removeServiceFailed ${LANG_SIMPCHINESE} "无法移除 sing-box 守护进程（代码 $1）。$\r$\n$\r$\n$3"
  LangString removeServiceFailed ${LANG_TRADCHINESE} "無法移除 sing-box 守護程序（代碼 $1）。$\r$\n$\r$\n$3"
  LangString removeServiceFailed ${LANG_FARSI} "حذف سرویس sing-box ناموفق بود (کد $1).$\r$\n$\r$\n$3"
  LangString removeServiceFailed ${LANG_RUSSIAN} "Не удалось удалить службу sing-box (код $1).$\r$\n$\r$\n$3"

  LangString removingData ${LANG_ENGLISH} "Removing sing-box data..."
  LangString removingData ${LANG_SIMPCHINESE} "正在移除 sing-box 数据..."
  LangString removingData ${LANG_TRADCHINESE} "正在移除 sing-box 資料..."
  LangString removingData ${LANG_FARSI} "در حال حذف داده‌های sing-box..."
  LangString removingData ${LANG_RUSSIAN} "Удаление данных sing-box..."

  # Reported when the previous version's daemon service could not be removed. Not fatal -
  # the installation has its own service under its own name - but the user should know an
  # obsolete service may still be listed under the upstream client's name.
  LangString legacyServiceCleanupFailed ${LANG_ENGLISH} "Could not remove the service registered by a previous version; it may still appear as 'sing-box-daemon'."
  LangString legacyServiceCleanupFailed ${LANG_SIMPCHINESE} "无法移除旧版本注册的服务；它可能仍以 'sing-box-daemon' 名称存在。"
  LangString legacyServiceCleanupFailed ${LANG_TRADCHINESE} "無法移除舊版本註冊的服務；它可能仍以 'sing-box-daemon' 名稱存在。"
  LangString legacyServiceCleanupFailed ${LANG_FARSI} "حذف سرویس ثبت‌شده توسط نسخهٔ قبلی ممکن نشد؛ ممکن است هنوز با نام 'sing-box-daemon' دیده شود."
  LangString legacyServiceCleanupFailed ${LANG_RUSSIAN} "Не удалось удалить службу, зарегистрированную предыдущей версией; она может остаться под именем 'sing-box-daemon'."
!macroend

!macro setInstallationLayoutRegistryView
  ${if} ${RunningX64}
  ${orif} ${IsNativeARM64}
    SetRegView 64
  ${else}
    SetRegView 32
  ${endif}
!macroend

!macro restoreInstallerRegistryView
  !ifdef APP_ARM64
    ${if} ${RunningX64}
    ${orif} ${IsNativeARM64}
      SetRegView 64
    ${else}
      SetRegView 32
    ${endif}
  !else
    !ifdef APP_64
      ${if} ${RunningX64}
        SetRegView 64
      ${else}
        SetRegView 32
      ${endif}
    !else
      SetRegView 32
    !endif
  !endif
!macroend

!macro daemonExecutable OUT
  StrCpy ${OUT} "$INSTDIR\resources\daemon\sing-box-daemon.exe"
!macroend

!macro registerTaildropVerb
  !insertmacro setInstallationLayoutRegistryView
  WriteRegStr HKLM "${TAILDROP_VERB_REGISTRY_KEY}" "" "$(taildropVerb)"
  WriteRegStr HKLM "${TAILDROP_VERB_REGISTRY_KEY}" "Icon" "$appExe,0"
  WriteRegStr HKLM "${TAILDROP_VERB_REGISTRY_KEY}" "MultiSelectModel" "Player"
  WriteRegStr HKLM "${TAILDROP_VERB_REGISTRY_KEY}\command" "" '"$appExe" --taildrop-send="%1"'
  !insertmacro restoreInstallerRegistryView
  System::Call 'shell32::SHChangeNotify(i 0x8000000, i 0, i 0, i 0)'
!macroend

!macro unregisterTaildropVerb
  !insertmacro setInstallationLayoutRegistryView
  DeleteRegKey HKLM "${TAILDROP_VERB_REGISTRY_KEY}"
  !insertmacro restoreInstallerRegistryView
  System::Call 'shell32::SHChangeNotify(i 0x8000000, i 0, i 0, i 0)'
!macroend

!macro refreshDesktopShortcutIfPresent NEW_LINK OLD_LINK REFRESHED
  StrCpy $7 0
  ${if} ${FileExists} "${NEW_LINK}"
    WinShell::UninstShortcut "${NEW_LINK}"
    Delete "${NEW_LINK}"
    StrCpy $7 1
  ${endif}
  ${if} "${OLD_LINK}" != "${NEW_LINK}"
  ${andif} ${FileExists} "${OLD_LINK}"
    WinShell::UninstShortcut "${OLD_LINK}"
    Delete "${OLD_LINK}"
    StrCpy $7 1
  ${endif}
  ${if} $7 == 1
    CreateShortCut "${NEW_LINK}" "$appExe" "" "$appExe" 0 "" "" "${APP_DESCRIPTION}"
    ClearErrors
    WinShell::SetLnkAUMI "${NEW_LINK}" "${APP_ID}"
    StrCpy ${REFRESHED} 1
  ${endif}
!macroend

!macro ciDiagnostic STAGE DETAIL
  # CI-only, opt-in: no-op unless /CI-DIAGNOSTIC-PATH= was given. Push and Pop
  # $9 so the caller's registers survive.
  ${if} $ciDiagnosticPath != ""
    Push $9
    ClearErrors
    FileOpen $9 "$ciDiagnosticPath" a
    ${ifNot} ${Errors}
      # NSIS FileOpen mode `a` PRESERVES the contents but leaves the file pointer at the START of
      # the file - it does not append on its own. Without this seek every marker overwrote the
      # previous one from offset 0, so a short write after a long one left the tail of the long
      # string behind.
      #
      # That single omission explains every anomaly in the diagnostic channel at once: the file
      # never grew, its size stayed near 162 bytes, `[customInstall] EXIT` was followed by a bare
      # `op=Commit`, and fragments like `ll` and `ore Authenticode signer certificate ...` appeared
      # - none of which are marker text, and all of which are what the tail of an overwritten line
      # looks like. No second writer was ever involved.
      FileSeek $9 0 END
      FileWrite $9 "[${STAGE}] ${DETAIL}$\r$\n"
      FileClose $9
    ${endif}
    Pop $9
  ${endif}
!macroend

!macro executeDaemonServiceCommand ACTION OPTIONS RESULT DETAILS
  !insertmacro ciDiagnostic "serviceCommand" "ENTER action=${ACTION}"
  Delete "$PLUGINSDIR\service-command.log"
  StrCpy ${RESULT} -1
  StrCpy ${DETAILS} ""
  ClearErrors
  nsExec::Exec '"$SYSDIR\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$PLUGINSDIR\installer-service.ps1" -ExecutablePath "$0" -ServiceAction ${ACTION} -OutputPath "$PLUGINSDIR\service-command.log" -DaemonDataDirectory "$daemonDataDirectory" ${OPTIONS}'
  Pop ${RESULT}
  ${if} ${RESULT} == "error"
    StrCpy ${RESULT} -1
  ${endif}
  ClearErrors
  FileOpen $4 "$PLUGINSDIR\service-command.log" r
  ${ifNot} ${Errors}
    FileReadUTF16LE $4 ${DETAILS}
    FileClose $4
  ${endif}
  Delete "$PLUGINSDIR\service-command.log"
  ${if} ${RESULT} != 0
    ${if} ${DETAILS} == ""
      StrCpy ${DETAILS} "$(serviceCommandNoDetails)"
    ${endif}
    DetailPrint "${DETAILS}"
  ${endif}
  !insertmacro ciDiagnostic "service ${ACTION}" "exit=${RESULT} ${DETAILS}"
  !insertmacro ciDiagnostic "serviceCommand" "EXIT action=${ACTION}"
!macroend

!macro confirmNativeArchitecture
  StrCpy $0 "x86"
  !ifdef APP_32
    StrCpy $0 "x86"
  !endif
  !ifdef APP_64
    StrCpy $0 "x64"
  !endif
  !ifdef APP_ARM64
    StrCpy $0 "ARM64"
  !endif
  StrCpy $1 "$(unknownNativeArchitecture)"
  ${if} ${IsNativeIA32}
    StrCpy $1 "x86"
  ${elseif} ${IsNativeAMD64}
    StrCpy $1 "x64"
  ${elseif} ${IsNativeARM64}
    StrCpy $1 "ARM64"
  ${endif}
  ${if} $0 != $1
    MessageBox MB_YESNO|MB_ICONEXCLAMATION|MB_DEFBUTTON2 "$(architectureMismatchPrompt)" /SD IDYES IDYES architectureMismatchAccepted IDNO architectureMismatchDeclined
    architectureMismatchDeclined:
      Abort
    architectureMismatchAccepted:
  ${endif}
!macroend

!macro customInit
  !insertmacro confirmNativeArchitecture
  !insertmacro setInstallationLayoutRegistryView
  StrCpy $allowUnsafeInstallation 0
  StrCpy $installationValidationAllowsUnsafe 0
  StrCpy $installationValidationMessage ""
  StrCpy $installationValidationRepairable 0
  StrCpy $unsafeInstallationConfirmationRequested 0
  StrCpy $unsafeInstallationAncestor ""
  StrCpy $resetWorkingDirectory 0
  StrCpy $reinstallExistingInstallation 0
  StrCpy $customInstallation 0
  # CI-only diagnostic channel. Absent the option this is inert: $ciDiagnosticPath
  # stays empty and every ciDiagnostic write is skipped.
  StrCpy $ciDiagnosticPath ""
  ClearErrors
  ${GetParameters} $R0
  ${GetOptions} $R0 "/CI-DIAGNOSTIC-PATH=" $R1
  ${ifNot} ${Errors}
    StrCpy $ciDiagnosticPath $R1
  ${endif}
  # The ENTER marker belongs AFTER the option is parsed, not before it.
  #
  # It used to be the first statement in this macro, so at that moment $ciDiagnosticPath was
  # still unset and the guard skipped the write - the marker could never appear in any run, no
  # matter what was passed on the command line. A marker that is structurally incapable of being
  # written is worse than no marker, because its absence reads as "this code did not run".
  !insertmacro ciDiagnostic "customInit" "ENTER"
  !insertmacro ciDiagnostic "customInit" "diagnostic channel opened; INSTDIR=$INSTDIR"
  StrCpy $migrateExistingData ${BST_CHECKED}
  StrCpy $migrateLegacyApplicationData 0
  StrCpy $applicationDataDirectory ""
  StrCpy $previousApplicationDataDirectory ""
  StrCpy $fixedApplicationDataDirectory ""
  StrCpy $userIndependentApplicationData ${BST_UNCHECKED}
  StrCpy $hasExistingInstallation 0
  StrCpy $hasInstallationLayout 0
  StrCpy $installationID ""
  StrCpy $previousInstallationID ""
  StrCpy $installationFailureTimer ""
  StrCpy $dataMigrationPrepared 0
  # Give this installation its own directory, before anything reads $INSTDIR. initMultiUser
  # set it from APP_FILENAME (the executable name) during .onInit; see
  # chooseForkInstallationDirectory for why the executable name cannot move instead.
  !insertmacro chooseForkInstallationDirectory
  StrCpy $defaultInstallationDirectory $INSTDIR
  SetShellVarContext all
  # The daemon's state tree is machine-wide, so it belongs in %ProgramData% - see
  # COMMON_APPLICATION_DATA at the top of this file, where the two wrong ways to spell it
  # are explained. %ProgramData% is also where the runtime's own fallback looks for it
  # (src/main/installationLayout.ts, CommonApplicationData), so this is the same path
  # whether or not an installation layout has been recorded yet.
  StrCpy $daemonDataDirectory "${COMMON_APPLICATION_DATA}\${DAEMON_DATA_DIRECTORY_NAME}"
  StrCpy $0 0
  ReadRegDWORD $0 HKLM "${INSTALLATION_LAYOUT_REGISTRY_KEY}" "LayoutVersion"
  ${if} $0 == 2
    ReadRegStr $applicationDataDirectory HKLM "${INSTALLATION_LAYOUT_REGISTRY_KEY}" "ApplicationDataDirectory"
    ReadRegStr $daemonDataDirectory HKLM "${INSTALLATION_LAYOUT_REGISTRY_KEY}" "DaemonDataDirectory"
    ReadRegStr $installationID HKLM "${INSTALLATION_LAYOUT_REGISTRY_KEY}" "InstallationID"
    StrCpy $hasInstallationLayout 1
  ${endif}
  !insertmacro restoreInstallerRegistryView
  ReadRegStr $0 HKLM "${INSTALL_REGISTRY_KEY}" "InstallLocation"
  ${if} $0 != ""
    StrCpy $hasExistingInstallation 1
  ${endif}
  ${if} $hasExistingInstallation == 1
  ${andif} $hasInstallationLayout == 0
    StrCpy $migrateLegacyApplicationData 1
  ${endif}
  ${if} $installationID == ""
    System::Call 'ole32::CoCreateGuid(g .s)'
    Pop $installationID
  ${endif}
  ${if} $daemonDataDirectory == ""
    StrCpy $daemonDataDirectory "${COMMON_APPLICATION_DATA}\${DAEMON_DATA_DIRECTORY_NAME}"
  ${endif}
  StrCpy $previousApplicationDataDirectory $applicationDataDirectory
  StrCpy $previousDaemonDataDirectory $daemonDataDirectory
  StrCpy $previousInstallationID $installationID
  ${if} $hasExistingInstallation == 0
    ${if} $applicationDataDirectory == ""
      StrCpy $applicationDataDirectory "$APPDATA\sing-box"
    ${endif}
    ${GetParameters} $R0
    ClearErrors
    ${GetOptions} $R0 "/APPLICATIONDATADIRECTORY=" $R1
    ${ifNot} ${Errors}
      StrCpy $applicationDataDirectory $R1
    ${else}
      ClearErrors
      ${GetOptions} $R0 "/APPLICATIONDATAROOT=" $R1
      ${ifNot} ${Errors}
        StrCpy $applicationDataDirectory $R1
      ${endif}
    ${endif}
    ClearErrors
    ${GetOptions} $R0 "/DAEMONDATADIRECTORY=" $R1
    ${ifNot} ${Errors}
      StrCpy $daemonDataDirectory $R1
    ${endif}
  ${endif}
  ${if} $applicationDataDirectory == ""
    StrCpy $fixedApplicationDataDirectory "$APPDATA\sing-box"
    StrCpy $userIndependentApplicationData ${BST_CHECKED}
  ${else}
    StrCpy $fixedApplicationDataDirectory $applicationDataDirectory
    StrCpy $userIndependentApplicationData ${BST_UNCHECKED}
  ${endif}
  SetShellVarContext current
  StrCpy $userApplicationDataDirectory "$APPDATA\sing-box"
  SetShellVarContext all
  StrCpy $defaultInstallationDirectory $INSTDIR
  StrCpy $defaultApplicationDataDirectory $applicationDataDirectory
  StrCpy $defaultDaemonDataDirectory $daemonDataDirectory
  StrCpy $workingDirectory $daemonDataDirectory
  # $PROFILE, not $APPDATA: the state file is per-user scratch space for one installer run,
  # and installer-data.ps1 validates this path against the CURRENT USER's roaming profile
  # (CommonApplicationData is NOT where it looks - see Initialize-TransitionStateStorage).
  # $PROFILE is the profile this installer was launched from and does not move when the
  # shell variable context does.
  StrCpy $dataTransitionStatePath "$PROFILE\AppData\Roaming\${INSTALLER_STATE_DIRECTORY_NAME}\data-transition.json"
  InitPluginsDir
  File /oname=$PLUGINSDIR\installer-preflight.ps1 "${BUILD_RESOURCES_DIR}\installer-preflight.ps1"
  File /oname=$PLUGINSDIR\installer-service.ps1 "${BUILD_RESOURCES_DIR}\installer-service.ps1"
  File /oname=$PLUGINSDIR\installer-stop-service.ps1 "${BUILD_RESOURCES_DIR}\installer-stop-service.ps1"
  File /oname=$PLUGINSDIR\installer-remove-legacy-service.ps1 "${BUILD_RESOURCES_DIR}\installer-remove-legacy-service.ps1"
  File /oname=$PLUGINSDIR\installer-legacy-service-ownership.ps1 "${BUILD_RESOURCES_DIR}\installer-legacy-service-ownership.ps1"
  File /oname=$PLUGINSDIR\installer-data.ps1 "${BUILD_RESOURCES_DIR}\installer-data.ps1"
  StrCpy $dataTransitionStatePresent 0
  ${if} ${FileExists} "$dataTransitionStatePath"
    StrCpy $dataTransitionStatePresent 1
  ${endif}
  !insertmacro ciDiagnostic "customInit" "data transition state present=$dataTransitionStatePresent at $dataTransitionStatePath"
  ${if} $dataTransitionStatePresent == 1
    nsExec::ExecToStack '"$SYSDIR\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$PLUGINSDIR\installer-data.ps1" -Operation Recover -StatePath "$dataTransitionStatePath"'
    Pop $0
    Pop $R0
    !insertmacro ciDiagnostic "customInit" "Recover exit=$0 out=[$R0]"
    ${if} $0 != 0
      StrCpy $1 $0
      Abort "$(dataMigrationCleanupFailed)"
    ${endif}
  ${endif}
  !insertmacro ciDiagnostic "customInit" "EXIT"
!macroend

!macro customWelcomePage
  Page custom showInstallationActionPage leaveInstallationActionPage

  Function showInstallationActionPage
    ${if} ${isUpdated}
      Abort
    ${endif}
    Call restoreInstallerNavigation
    GetDlgItem $0 $HWNDPARENT 3
    ShowWindow $0 ${SW_HIDE}
    nsDialogs::Create 1018
    Pop $installationActionDialog
    ${if} $installationActionDialog == error
      Abort
    ${endif}

    ${if} $hasExistingInstallation == 1
      !insertmacro MUI_HEADER_TEXT "$(existingInstallationPageTitle)" "$(existingInstallationPageSubtitle)"
      ${NSD_CreateRadioButton} 0u 0u 100% 14u "$(updateExistingInstallation)"
      Pop $updateExistingInstallationRadio
      ${NSD_CreateRadioButton} 0u 14u 100% 14u "$(reinstallExistingInstallation)"
      Pop $reinstallExistingInstallationRadio
      ${if} $reinstallExistingInstallation == 1
        ${NSD_SetState} $reinstallExistingInstallationRadio ${BST_CHECKED}
      ${else}
        ${NSD_SetState} $updateExistingInstallationRadio ${BST_CHECKED}
      ${endif}
    ${else}
      !insertmacro MUI_HEADER_TEXT "$(installationMethodPageTitle)" "$(existingInstallationPageSubtitle)"
      ${NSD_CreateRadioButton} 0u 0u 100% 14u "$(standardInstallation)"
      Pop $standardInstallationRadio
      ${NSD_CreateRadioButton} 0u 14u 100% 14u "$(customInstallation)"
      Pop $customInstallationRadio
      ${if} $customInstallation == 1
        ${NSD_SetState} $customInstallationRadio ${BST_CHECKED}
      ${else}
        ${NSD_SetState} $standardInstallationRadio ${BST_CHECKED}
      ${endif}
    ${endif}
    nsDialogs::Show
  FunctionEnd

  Function leaveInstallationActionPage
    ${if} $hasExistingInstallation == 1
      ${NSD_GetState} $reinstallExistingInstallationRadio $0
      ${if} $0 == ${BST_CHECKED}
        StrCpy $reinstallExistingInstallation 1
      ${else}
        StrCpy $reinstallExistingInstallation 0
        StrCpy $applicationDataDirectory $previousApplicationDataDirectory
        StrCpy $daemonDataDirectory $previousDaemonDataDirectory
        ${if} $applicationDataDirectory == ""
          StrCpy $userIndependentApplicationData ${BST_CHECKED}
        ${else}
          StrCpy $fixedApplicationDataDirectory $applicationDataDirectory
          StrCpy $userIndependentApplicationData ${BST_UNCHECKED}
        ${endif}
      ${endif}
    ${else}
      ${NSD_GetState} $customInstallationRadio $0
      ${if} $0 == ${BST_CHECKED}
        StrCpy $customInstallation 1
      ${else}
        StrCpy $customInstallation 0
        StrCpy $INSTDIR $defaultInstallationDirectory
        StrCpy $applicationDataDirectory $defaultApplicationDataDirectory
        StrCpy $daemonDataDirectory $defaultDaemonDataDirectory
        ${if} $applicationDataDirectory == ""
          StrCpy $userIndependentApplicationData ${BST_CHECKED}
        ${else}
          StrCpy $fixedApplicationDataDirectory $applicationDataDirectory
          StrCpy $userIndependentApplicationData ${BST_UNCHECKED}
        ${endif}
        StrCpy $workingDirectory $daemonDataDirectory
      ${endif}
    ${endif}
  FunctionEnd

  Function skipAcceptedLicensePage
    ${if} ${isUpdated}
    ${orif} $hasExistingInstallation == 1
      Abort
    ${endif}
  FunctionEnd

!macroend

!macro executeInstallationPreflight OPTIONS
  Delete "$PLUGINSDIR\installation-preflight-output.txt"
  nsExec::Exec '"$SYSDIR\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$PLUGINSDIR\installer-preflight.ps1" -InstallationDirectory "$INSTDIR" -ApplicationDataDirectory "$applicationDataDirectory" -DaemonWorkingDirectory "$daemonDataDirectory" -InstallationID "$installationID" -ResultOutputPath "$PLUGINSDIR\installation-preflight-output.txt" ${OPTIONS}'
  Pop $1
  StrCpy $0 ""
  ClearErrors
  FileOpen $4 "$PLUGINSDIR\installation-preflight-output.txt" r
  ${ifNot} ${Errors}
    FileReadUTF16LE $4 $0
    FileClose $4
  ${endif}
  Delete "$PLUGINSDIR\installation-preflight-output.txt"
  !insertmacro ciDiagnostic "preflight" "exit=$1 ${OPTIONS} $0"
!macroend

!macro executeInstallationPreflightAsync OPTIONS
  ClearErrors
  ExecShell "open" "$SYSDIR\WindowsPowerShell\v1.0\powershell.exe" '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "$PLUGINSDIR\installer-preflight.ps1" -InstallationDirectory "$INSTDIR" -ApplicationDataDirectory "$applicationDataDirectory" -DaemonWorkingDirectory "$daemonDataDirectory" -InstallationID "$installationID" -ResultOutputPath "$installationValidationOutputPath" -ResultCodePath "$installationValidationResultPath" -ProcessIDPath "$installationValidationProcessIDPath" ${OPTIONS}' SW_HIDE
  ${if} ${Errors}
    StrCpy $0 "error"
  ${else}
    StrCpy $0 "ok"
  ${endif}
!macroend

!macro executeDataTransition OPERATION RESULT
  !insertmacro ciDiagnostic "dataTransition" "ENTER op=${OPERATION}"
  StrCpy $3 ""
  ${if} $migrateLegacyApplicationData == 1
    StrCpy $3 "-MigrateLegacyApplicationData"
  ${endif}
  # ${RESULT} is a caller-supplied register. It used to be a hardcoded `$1`, and three different
  # meanings shared that one register: the macro wrote -1 into it as a default, wrote the exit
  # code into it, and the Prepare call site TESTED it. The effect was that the caller could not
  # tell "the helper returned 7" from "the helper never ran", and the record could not say which.
  StrCpy ${RESULT} -1
  ClearErrors
  # nsExec pushes the exit code and then the output, so the first Pop is the exit code. The
  # pairing is recorded below rather than assumed, because it is the one thing here that reading
  # the call site cannot confirm.
  nsExec::ExecToStack '"$SYSDIR\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$PLUGINSDIR\installer-data.ps1" -Operation ${OPERATION} -StatePath "$dataTransitionStatePath" -PreviousApplicationDataDirectory "$previousApplicationDataDirectory" -ApplicationDataDirectory "$applicationDataDirectory" -PreviousDaemonDataDirectory "$previousDaemonDataDirectory" -DaemonDataDirectory "$daemonDataDirectory" -PreviousInstallationID "$previousInstallationID" -InstallationID "$installationID" $3'
  Pop ${RESULT}
  Pop $R0
  ${if} ${RESULT} == "error"
    StrCpy ${RESULT} -1
  ${endif}
  # A silent helper that fails has to leave its reason somewhere, and the diagnostic channel is
  # the only surface that survives the installer deleting its own evidence.
  !insertmacro ciDiagnostic "dataTransition" "EXIT op=${OPERATION} exit=${RESULT} out=[$R0]"
!macroend

!macro customPageAfterChangeDir
  Page custom showDataDirectoriesPage leaveDataDirectoriesPage
  Page custom showInstallationDirectoryValidationPage
  Page custom showUnsafeInstallationConfirmationPage

  Function expandInstallerToFitControl
    Exch $0
    System::Call 'user32::GetWindowRect(p r0, @r1)'
    System::Call '*$1(i.r2, i.r3, i.r4, i.r5)'
    IntOp $6 $5 - $3
    IntOp $6 $6 / 2
    IntOp $5 $5 + $6
    System::Call 'user32::GetWindowRect(p $dataDirectoriesDialog, @r1)'
    System::Call '*$1(i, i, i, i.r6)'
    IntOp $installerHeightExtension $5 - $6
    ${if} $installerHeightExtension <= 0
      Pop $0
      Return
    ${endif}

    !insertmacro resizeWindowHeight $HWNDPARENT $installerHeightExtension
    !insertmacro resizeWindowHeight $dataDirectoriesDialog $installerHeightExtension
    GetDlgItem $0 $HWNDPARENT 1018
    !insertmacro resizeWindowHeight $0 $installerHeightExtension
    GetDlgItem $0 $HWNDPARENT 1044
    !insertmacro resizeWindowHeight $0 $installerHeightExtension

    GetDlgItem $0 $HWNDPARENT 1035
    !insertmacro moveWindowDown $0 $installerHeightExtension
    GetDlgItem $0 $HWNDPARENT 1045
    !insertmacro moveWindowDown $0 $installerHeightExtension
    GetDlgItem $0 $HWNDPARENT 1256
    !insertmacro moveWindowDown $0 $installerHeightExtension
    GetDlgItem $0 $HWNDPARENT 1028
    !insertmacro moveWindowDown $0 $installerHeightExtension
    GetDlgItem $0 $HWNDPARENT 1
    !insertmacro moveWindowDown $0 $installerHeightExtension
    GetDlgItem $0 $HWNDPARENT 2
    !insertmacro moveWindowDown $0 $installerHeightExtension
    GetDlgItem $0 $HWNDPARENT 3
    !insertmacro moveWindowDown $0 $installerHeightExtension
    System::Call 'user32::RedrawWindow(p $HWNDPARENT, p0, p0, i0x185)'
    Pop $0
  FunctionEnd

  Function showDataDirectoriesPage
    ${if} $hasExistingInstallation == 1
    ${andif} $reinstallExistingInstallation == 0
      Abort
    ${elseif} $hasExistingInstallation == 0
    ${andif} $customInstallation == 0
      Abort
    ${endif}
    Call restoreInstallerNavigation
    !insertmacro MUI_HEADER_TEXT "$(dataDirectoriesPageTitle)" "$(dataDirectoriesPageSubtitle)"
    nsDialogs::Create 1018
    Pop $dataDirectoriesDialog
    ${if} $dataDirectoriesDialog == error
      Abort
    ${endif}

    ${NSD_CreateLabel} 0u 0u 100% 12u "$(installationDirectoryLabel)"
    Pop $1
    ${NSD_CreateDirRequest} 0u 16u 76% 13u "$INSTDIR"
    Pop $installationDirectoryInput
    ${NSD_CreateBrowseButton} 78% 15u 22% 15u "$(browseDirectoryButton)"
    Pop $installationDirectoryBrowseButton
    ${NSD_OnClick} $installationDirectoryBrowseButton browseInstallationDirectory

    ${NSD_CreateCheckBox} 0u 38u 100% 12u "$(userIndependentApplicationData)"
    Pop $userIndependentApplicationDataCheckbox
    ${NSD_SetState} $userIndependentApplicationDataCheckbox $userIndependentApplicationData
    ${NSD_OnClick} $userIndependentApplicationDataCheckbox updateApplicationDataDirectoryMode

    StrCpy $0 56
    ${NSD_CreateLabel} 0u $0u 100% 12u "$(applicationDataDirectoryLabel)"
    Pop $1
    IntOp $0 $0 + 16
    ${if} $userIndependentApplicationData == ${BST_CHECKED}
      StrCpy $1 $userApplicationDataDirectory
    ${else}
      StrCpy $1 $fixedApplicationDataDirectory
    ${endif}
    ${NSD_CreateDirRequest} 0u $0u 76% 13u "$1"
    Pop $applicationDataDirectoryInput
    IntOp $0 $0 - 1
    ${NSD_CreateBrowseButton} 78% $0u 22% 15u "$(browseDirectoryButton)"
    Pop $applicationDataDirectoryBrowseButton
    ${NSD_OnClick} $applicationDataDirectoryBrowseButton browseApplicationDataDirectory
    ${if} $userIndependentApplicationData == ${BST_CHECKED}
      EnableWindow $applicationDataDirectoryInput 0
      EnableWindow $applicationDataDirectoryBrowseButton 0
    ${endif}

    IntOp $0 $0 + 27
    ${NSD_CreateLabel} 0u $0u 100% 12u "$(daemonDataDirectoryLabel)"
    Pop $1
    IntOp $0 $0 + 16
    ${NSD_CreateDirRequest} 0u $0u 76% 13u "$daemonDataDirectory"
    Pop $daemonDataDirectoryInput
    IntOp $0 $0 - 1
    ${NSD_CreateBrowseButton} 78% $0u 22% 15u "$(browseDirectoryButton)"
    Pop $daemonDataDirectoryBrowseButton
    ${NSD_OnClick} $daemonDataDirectoryBrowseButton browseDaemonDataDirectory

    ${if} $hasInstallationLayout == 1
    ${orif} $hasExistingInstallation == 1
      IntOp $0 $0 + 23
      ${NSD_CreateCheckBox} 0u $0u 100% 12u "$(migrateExistingData)"
      Pop $migrateExistingDataCheckbox
      ${NSD_SetState} $migrateExistingDataCheckbox $migrateExistingData
      Push $migrateExistingDataCheckbox
      Call expandInstallerToFitControl
    ${endif}

    nsDialogs::Show
  FunctionEnd

  Function leaveDataDirectoriesPage
    ${NSD_GetText} $installationDirectoryInput $INSTDIR
    ${if} $INSTDIR == ""
      Abort
    ${endif}
    ${NSD_GetState} $userIndependentApplicationDataCheckbox $userIndependentApplicationData
    ${if} $userIndependentApplicationData == ${BST_CHECKED}
      StrCpy $applicationDataDirectory ""
    ${else}
      ${NSD_GetText} $applicationDataDirectoryInput $applicationDataDirectory
      ${if} $applicationDataDirectory == ""
        StrCpy $0 ""
        MessageBox MB_OK|MB_ICONSTOP "$(invalidApplicationDataDirectory)"
        Abort
      ${endif}
      StrCpy $fixedApplicationDataDirectory $applicationDataDirectory
    ${endif}
    ${NSD_GetText} $daemonDataDirectoryInput $daemonDataDirectory
    ${if} $daemonDataDirectory == ""
      StrCpy $0 ""
      MessageBox MB_OK|MB_ICONSTOP "$(invalidDaemonDataDirectory)"
      Abort
    ${endif}
    ${if} $hasInstallationLayout == 1
    ${orif} $hasExistingInstallation == 1
      ${NSD_GetState} $migrateExistingDataCheckbox $migrateExistingData
    ${endif}
    StrCpy $workingDirectory $daemonDataDirectory
  FunctionEnd

  Function browseApplicationDataDirectory
    Pop $0
    ${NSD_GetText} $applicationDataDirectoryInput $0
    nsDialogs::SelectFolderDialog "$(applicationDataDirectoryLabel)" "$0"
    Pop $0
    ${if} $0 != error
      ${NSD_SetText} $applicationDataDirectoryInput $0
    ${endif}
  FunctionEnd

  Function updateApplicationDataDirectoryMode
    Pop $0
    ${NSD_GetState} $userIndependentApplicationDataCheckbox $userIndependentApplicationData
    ${if} $userIndependentApplicationData == ${BST_CHECKED}
      ${NSD_GetText} $applicationDataDirectoryInput $fixedApplicationDataDirectory
      ${NSD_SetText} $applicationDataDirectoryInput $userApplicationDataDirectory
      EnableWindow $applicationDataDirectoryInput 0
      EnableWindow $applicationDataDirectoryBrowseButton 0
    ${else}
      ${NSD_SetText} $applicationDataDirectoryInput $fixedApplicationDataDirectory
      EnableWindow $applicationDataDirectoryInput 1
      EnableWindow $applicationDataDirectoryBrowseButton 1
    ${endif}
  FunctionEnd

  Function browseInstallationDirectory
    Pop $0
    ${NSD_GetText} $installationDirectoryInput $0
    nsDialogs::SelectFolderDialog "$(installationDirectoryLabel)" "$0"
    Pop $0
    ${if} $0 != error
      ${NSD_SetText} $installationDirectoryInput $0
    ${endif}
  FunctionEnd

  Function browseDaemonDataDirectory
    Pop $0
    ${NSD_GetText} $daemonDataDirectoryInput $0
    nsDialogs::SelectFolderDialog "$(daemonDataDirectoryLabel)" "$0"
    Pop $0
    ${if} $0 != error
      ${NSD_SetText} $daemonDataDirectoryInput $0
    ${endif}
  FunctionEnd

  Function showInstallationDirectoryValidationPage
    !insertmacro fixForkInstallationDirectory
    StrCpy $allowUnsafeInstallation 0
    StrCpy $installationValidationAllowsUnsafe 0
    StrCpy $installationValidationMessage ""
    StrCpy $installationValidationRepairable 0
    StrCpy $unsafeInstallationConfirmationRequested 0
    StrCpy $unsafeInstallationAncestor ""
    StrCpy $installationValidationProcessHandle ""
    StrCpy $installationValidationProcessIDPath "$PLUGINSDIR\installation-validation-process-id.txt"
    StrCpy $installationValidationOutputPath "$PLUGINSDIR\installation-validation-output.txt"
    StrCpy $installationValidationResultPath "$PLUGINSDIR\installation-validation-result.txt"
    StrCpy $installationValidationOutput ""
    Delete "$installationValidationProcessIDPath"
    Delete "$installationValidationOutputPath"
    Delete "$installationValidationResultPath"
    !insertmacro MUI_HEADER_TEXT "$(checkingInstallationLocations)" ""
    nsDialogs::Create 1018
    Pop $installationValidationDialog
    ${if} $installationValidationDialog == error
      Abort
    ${endif}

    ${NSD_CreateLabel} 0u 20u 100% 16u "$(checkingInstallationLocations)"
    Pop $installationValidationStatusLabel
    ${NSD_CreateProgressBar} 0u 46u 100% 12u ""
    Pop $installationValidationProgressBar
    ${NSD_AddStyle} $installationValidationProgressBar 0x8
    SendMessage $installationValidationProgressBar ${PBM_SETMARQUEE} 1 30

    GetDlgItem $0 $HWNDPARENT 1
    ShowWindow $0 ${SW_HIDE}
    GetDlgItem $0 $HWNDPARENT 2
    ShowWindow $0 ${SW_SHOW}
    GetDlgItem $0 $HWNDPARENT 3
    ShowWindow $0 ${SW_HIDE}

    !insertmacro executeInstallationPreflightAsync ""
    ${if} $0 == "ok"
      ${NSD_CreateTimer} pollInstallationDirectoryValidation 100
    ${else}
      StrCpy $installationValidationResult 30
      Call showInstallationDirectoryValidationResult
    ${endif}
    nsDialogs::Show
  FunctionEnd

  Function pollInstallationDirectoryValidation
    ${if} $installationValidationProcessHandle == ""
    ${andif} ${FileExists} "$installationValidationProcessIDPath"
      ClearErrors
      FileOpen $0 "$installationValidationProcessIDPath" r
      ${ifNot} ${Errors}
        FileRead $0 $1
        FileClose $0
        System::Call 'kernel32::OpenProcess(i 0x00100001, i 0, i r1) p.r0'
        ${if} $0 != 0
          StrCpy $installationValidationProcessHandle $0
        ${endif}
      ${endif}
    ${endif}
    ${if} ${FileExists} "$installationValidationResultPath"
      ${NSD_KillTimer} pollInstallationDirectoryValidation
      ClearErrors
      FileOpen $0 "$installationValidationResultPath" r
      ${ifNot} ${Errors}
        FileRead $0 $installationValidationResult
        FileClose $0
      ${else}
        StrCpy $installationValidationResult 30
      ${endif}
      Goto installationDirectoryValidationFinished
    ${endif}
    ${if} $installationValidationProcessHandle == ""
      Return
    ${endif}
    StrCpy $0 $installationValidationProcessHandle
    System::Call 'kernel32::WaitForSingleObject(p r0, i 0) i.r1'
    ${if} $1 == 258
      Return
    ${endif}
    ${NSD_KillTimer} pollInstallationDirectoryValidation
    StrCpy $installationValidationResult 30

    installationDirectoryValidationFinished:
    ${if} $installationValidationProcessHandle != ""
      StrCpy $0 $installationValidationProcessHandle
      System::Call 'kernel32::CloseHandle(p r0)'
    ${endif}
    StrCpy $installationValidationProcessHandle ""
    ClearErrors
    FileOpen $0 "$installationValidationOutputPath" r
    ${ifNot} ${Errors}
      FileReadUTF16LE $0 $installationValidationOutput
      FileClose $0
    ${endif}
    Delete "$installationValidationProcessIDPath"
    Delete "$installationValidationOutputPath"
    Delete "$installationValidationResultPath"
    Call showInstallationDirectoryValidationResult
  FunctionEnd

  Function showInstallationDirectoryValidationResult
    ShowWindow $installationValidationStatusLabel ${SW_HIDE}
    ShowWindow $installationValidationProgressBar ${SW_HIDE}
    ${if} $installationValidationResult == 0
      Call advanceInstallationDirectoryValidationPage
      Return
    ${elseif} $installationValidationResult == 20
    ${orif} $installationValidationResult == 21
    ${orif} $installationValidationResult == 22
      MessageBox MB_YESNO|MB_ICONEXCLAMATION|MB_DEFBUTTON1 "$(resetWorkingDirectoryPrompt)" /SD IDYES IDYES acceptWorkingDirectoryReset IDNO declineWorkingDirectoryReset
      acceptWorkingDirectoryReset:
        StrCpy $resetWorkingDirectory 1
        Call advanceInstallationDirectoryValidationPage
        Return
      declineWorkingDirectoryReset:
        Quit
    ${endif}
    StrCpy $0 $installationValidationOutput
    StrCpy $1 $installationValidationResult
    Call setInstallationValidationMessage
    ${if} $installationValidationRepairable == 1
      !insertmacro MUI_HEADER_TEXT "$(repairPathPermissionsPageTitle)" "$(repairPathPermissionsPageSubtitle)"
    ${elseif} $installationValidationAllowsUnsafe == 1
      !insertmacro MUI_HEADER_TEXT "$(unsafeInstallationPageTitle)" "$(unsafeInstallationPageSubtitle)"
    ${else}
      !insertmacro MUI_HEADER_TEXT "$(invalidInstallationPageTitle)" "$(invalidInstallationPageSubtitle)"
    ${endif}

    ${NSD_CreateLabel} 0u 0u 100% 84u "$installationValidationMessage"
    Pop $0

    ${if} $installationValidationAllowsUnsafe == 1
      ${if} $installationValidationRepairable == 1
        ${NSD_CreateButton} 0u 90u 100% 18u "$(repairInstallationPermissionsButton)"
        Pop $installationValidationRepairButton
        ${NSD_OnClick} $installationValidationRepairButton repairInstallationPermissions

        ${NSD_CreateButton} 0u 112u 100% 18u "$(unsafeInstallationButton)"
        Pop $installationValidationUnsafeButton
        ${NSD_OnClick} $installationValidationUnsafeButton openUnsafeInstallationConfirmation
      ${else}
        ${NSD_CreateButton} 0u 90u 100% 18u "$(unsafeInstallationButton)"
        Pop $installationValidationUnsafeButton
        ${NSD_OnClick} $installationValidationUnsafeButton openUnsafeInstallationConfirmation
      ${endif}
    ${endif}

    GetDlgItem $0 $HWNDPARENT 2
    ShowWindow $0 ${SW_SHOW}
    ${if} $installationValidationRepairable == 1
      SendMessage $installationValidationDialog ${WM_NEXTDLGCTL} $installationValidationRepairButton 1
    ${else}
      SendMessage $installationValidationDialog ${WM_NEXTDLGCTL} $0 1
    ${endif}
    GetDlgItem $0 $HWNDPARENT 3
    ShowWindow $0 ${SW_SHOW}
  FunctionEnd

  Function showUnsafeInstallationConfirmationPage
    ${if} $installationValidationAllowsUnsafe != 1
    ${orif} $unsafeInstallationConfirmationRequested != 1
      Abort
    ${endif}
    !insertmacro MUI_HEADER_TEXT "$(unsafeInstallationConfirmationTitle)" "$(unsafeInstallationConfirmationSubtitle)"
    nsDialogs::Create 1018
    Pop $installationValidationDialog
    ${if} $installationValidationDialog == error
      Abort
    ${endif}

    ${NSD_CreateLabel} 0u 0u 100% 32u "$installationValidationMessage"
    Pop $0

    ${NSD_CreateLabel} 0u 34u 100% 35u "$(unsafeInstallationConfirmationWarning)"
    Pop $0
    SetCtlColors $0 "C42B1C" transparent

    ${NSD_CreateCheckBox} 0u 73u 100% 12u "$(unsafeInstallationAcknowledgement)"
    Pop $unsafeInstallationAcknowledgementCheckbox
    ${NSD_SetState} $unsafeInstallationAcknowledgementCheckbox ${BST_UNCHECKED}
    ${NSD_OnClick} $unsafeInstallationAcknowledgementCheckbox updateUnsafeInstallationAcknowledgement

    ${NSD_CreateButton} 0u 91u 100% 18u "$(continueUnsafeInstallationButton)"
    Pop $installationValidationUnsafeButton
    ${NSD_OnClick} $installationValidationUnsafeButton continueUnsafeInstallation
    EnableWindow $installationValidationUnsafeButton 0

    ${NSD_CreateButton} 0u 113u 100% 18u "$(returnToInstallationChoiceButton)"
    Pop $unsafeInstallationReturnButton
    ${NSD_OnClick} $unsafeInstallationReturnButton returnToInstallationChoice

    GetDlgItem $0 $HWNDPARENT 1
    ShowWindow $0 ${SW_HIDE}
    GetDlgItem $0 $HWNDPARENT 2
    ShowWindow $0 ${SW_HIDE}
    GetDlgItem $0 $HWNDPARENT 3
    ShowWindow $0 ${SW_HIDE}
    SendMessage $installationValidationDialog ${WM_NEXTDLGCTL} $unsafeInstallationReturnButton 1
    nsDialogs::Show
  FunctionEnd

  Function setInstallationValidationMessage
    StrCpy $installationValidationAllowsUnsafe 0
    StrCpy $installationValidationRepairable 0
    StrCpy $unsafeInstallationAncestor ""
    ${if} $1 == 10
      StrCpy $installationValidationAllowsUnsafe 1
      StrCpy $installationValidationMessage "$(unsafeInstallationDirectory)"
    ${elseif} $1 == 11
      StrCpy $installationValidationAllowsUnsafe 1
      StrCpy $installationValidationMessage "$(invalidInstallationAncestor)"
    ${elseif} $1 == 12
      StrCpy $installationValidationAllowsUnsafe 1
      StrCpy $installationValidationMessage "$(untrustedInstallationAncestor)"
    ${elseif} $1 == 13
      StrCpy $installationValidationAllowsUnsafe 1
      StrCpy $installationValidationRepairable 1
      StrCpy $unsafeInstallationAncestor "$0"
      StrCpy $installationValidationMessage "$(unsafeInstallationPageBody)"
    ${elseif} $1 == 14
      StrCpy $installationValidationAllowsUnsafe 1
      StrCpy $installationValidationMessage "$(installationDriveNotFixed)"
    ${elseif} $1 == 15
      StrCpy $installationValidationAllowsUnsafe 1
      StrCpy $installationValidationMessage "$(installationFileSystemNotNTFS)"
    ${elseif} $1 == 16
      StrCpy $installationValidationAllowsUnsafe 1
      StrCpy $installationValidationMessage "$(installationVolumeNotVerified)"
    ${elseif} $1 == 17
      StrCpy $installationValidationAllowsUnsafe 1
      StrCpy $installationValidationRepairable 1
      StrCpy $unsafeInstallationAncestor "$0"
      StrCpy $installationValidationMessage "$(unsafeDaemonDataDirectoryPageBody)"
    ${elseif} $1 == 18
      StrCpy $installationValidationAllowsUnsafe 1
      StrCpy $installationValidationRepairable 1
      StrCpy $unsafeInstallationAncestor "$0"
      StrCpy $installationValidationMessage "$(unsafeApplicationDataDirectoryPageBody)"
    ${elseif} $1 == 23
      StrCpy $installationValidationMessage "$(overlappingDaemonDataDirectory)"
    ${elseif} $1 == 24
      StrCpy $installationValidationMessage "$(overlappingApplicationDataDirectory)"
    ${elseif} $1 == 25
    ${orif} $1 == 26
    ${orif} $1 == 28
      StrCpy $installationValidationMessage "$(invalidApplicationDataDirectory)"
    ${elseif} $1 == 27
      StrCpy $installationValidationMessage "$(invalidDaemonDataDirectory)"
    ${else}
      StrCpy $installationValidationMessage "$(preflightFailed)"
    ${endif}
  FunctionEnd

  Function openUnsafeInstallationConfirmation
    Pop $0
    StrCpy $unsafeInstallationConfirmationRequested 1
    Call restoreInstallerNavigation
    SendMessage $HWNDPARENT ${WM_COMMAND} 1 0
  FunctionEnd

  Function returnToInstallationChoice
    Pop $0
    StrCpy $unsafeInstallationConfirmationRequested 0
    Call restoreInstallerNavigation
    SendMessage $HWNDPARENT ${WM_COMMAND} 3 0
  FunctionEnd

  Function continueUnsafeInstallation
    Pop $0
    ${NSD_GetState} $unsafeInstallationAcknowledgementCheckbox $0
    ${if} $0 != ${BST_CHECKED}
      Return
    ${endif}
    StrCpy $allowUnsafeInstallation 1
    !insertmacro showPendingInstallerOperation "$(checkingInstallationLocations)"
    !insertmacro executeInstallationPreflight "-AllowUnsafeInstallationDirectory"
    ${if} $1 == 0
      Call advanceInstallationDirectoryValidationPage
    ${elseif} $1 == 20
    ${orif} $1 == 21
    ${orif} $1 == 22
      MessageBox MB_YESNO|MB_ICONEXCLAMATION|MB_DEFBUTTON1 "$(resetWorkingDirectoryPrompt)" IDYES acceptWorkingDirectoryResetAfterUnsafeChoice IDNO declineWorkingDirectoryResetAfterUnsafeChoice
      acceptWorkingDirectoryResetAfterUnsafeChoice:
        StrCpy $resetWorkingDirectory 1
        Call advanceInstallationDirectoryValidationPage
        Return
      declineWorkingDirectoryResetAfterUnsafeChoice:
        Return
    ${else}
      StrCpy $allowUnsafeInstallation 0
      Call setInstallationValidationMessage
      MessageBox MB_OK|MB_ICONSTOP "$installationValidationMessage"
    ${endif}
  FunctionEnd

  Function updateUnsafeInstallationAcknowledgement
    Pop $0
    ${NSD_GetState} $unsafeInstallationAcknowledgementCheckbox $0
    ${if} $0 == ${BST_CHECKED}
      EnableWindow $installationValidationUnsafeButton 1
    ${else}
      EnableWindow $installationValidationUnsafeButton 0
    ${endif}
  FunctionEnd

  Function repairInstallationPermissions
    Pop $0
    !insertmacro showPendingInstallerOperation "$(repairingInstallationPermissions)"
    !insertmacro executeInstallationPreflight "-RepairPathAncestors"
    ${if} $1 == 0
      StrCpy $allowUnsafeInstallation 0
      Call advanceInstallationDirectoryValidationPage
    ${elseif} $1 == 20
    ${orif} $1 == 21
    ${orif} $1 == 22
      MessageBox MB_YESNO|MB_ICONEXCLAMATION|MB_DEFBUTTON1 "$(resetWorkingDirectoryPrompt)" IDYES acceptWorkingDirectoryResetAfterRepair IDNO declineWorkingDirectoryResetAfterRepair
      acceptWorkingDirectoryResetAfterRepair:
        StrCpy $resetWorkingDirectory 1
        StrCpy $allowUnsafeInstallation 0
        Call advanceInstallationDirectoryValidationPage
        Return
      declineWorkingDirectoryResetAfterRepair:
        Return
    ${elseif} $1 == 32
      MessageBox MB_OK|MB_ICONSTOP "$(repairInstallationAncestorFailed)"
    ${else}
      Call setInstallationValidationMessage
      MessageBox MB_OK|MB_ICONSTOP "$installationValidationMessage"
    ${endif}
  FunctionEnd

  Function restoreInstallerNavigation
    GetDlgItem $0 $HWNDPARENT 1
    ShowWindow $0 ${SW_SHOW}
    GetDlgItem $0 $HWNDPARENT 2
    ShowWindow $0 ${SW_SHOW}
    GetDlgItem $0 $HWNDPARENT 3
    ShowWindow $0 ${SW_SHOW}
  FunctionEnd

  Function advanceInstallationDirectoryValidationPage
    StrCpy $unsafeInstallationConfirmationRequested 0
    Call restoreInstallerNavigation
    SendMessage $HWNDPARENT ${WM_COMMAND} 1 0
  FunctionEnd

  Function scheduleInstallationFailureState
    ${if} ${Abort}
      ${StdUtils.TimerCreate} $installationFailureTimer applyInstallationFailureState 1
    ${endif}
  FunctionEnd

  Function applyInstallationFailureState
    ${StdUtils.TimerDestroy} $0 $installationFailureTimer
    StrCpy $installationFailureTimer ""
    GetDlgItem $0 $HWNDPARENT 2
    SendMessage $0 ${WM_SETTEXT} 0 "STR:$(MUI_BUTTONTEXT_FINISH)"
    FindWindow $0 "#32770" "" $HWNDPARENT
    GetDlgItem $0 $0 1004
    SendMessage $0 ${PBM_SETSTATE} ${PBST_ERROR} 0
  FunctionEnd

  !define MUI_PAGE_CUSTOMFUNCTION_LEAVE scheduleInstallationFailureState
!macroend

# Gives this fork the installation directory its own name, out of the upstream client's
# namespace.
#
# # The collision this prevents
#
# electron-builder names the default installation directory `APP_FILENAME`, which is
# `appInfo.productFilename` for a per-machine assisted installer - and productFilename is
# `platformSpecificOptions?.executableName ?? info.config.executableName ?? productName`
# (appInfo.js, `AppInfo`'s constructor). So it follows the EXECUTABLE name, not the product
# name, and this fork's `win.executableName: sing-box` made both clients default to
#
#     C:\Program Files\sing-box
#
# The upstream client is per-machine too (`nsis.perMachine: true`), so two products would
# install over each other: the second one's Add/Remove entry replaces the first's, and either
# uninstall takes the other's files with it.
#
# # Why the fix is here and not in the config
#
# The two names have to come apart, and only ONE of them can move. `executableName` is a
# security dependency: experimental/boxdd resolves `<install>\sing-box.exe` and compares its
# Authenticode signer against the daemon's, both when the service is registered and on every
# peer handshake.
#
# The installation directory cannot be changed from the config either. `APP_FILENAME` is
# passed to makensis on the command line, and a second `!define` of the same name is a fatal
# NSIS error rather than an override - so a `!define APP_FILENAME` in this file would not win,
# it would break the build. Verified, not assumed; see build/rename-probe.nsi.
#
# What is left is `$INSTDIR`. `initMultiUser` (multiUser.nsh, `setInstallModePerAllUsers`) sets
# it to `<program files>\${APP_FILENAME}` during `.onInit`, and `customInit` runs immediately
# afterwards (installer.nsi) and before any page is created - so this hook sees the derived
# default and can replace it.
#
# # Why it reconstructs the path instead of editing it
#
# The first version of this appended `\..\Jiejiebox` to `$INSTDIR` when its last component was
# `${APP_FILENAME}`. That needed `StrCpy $var $in "" -1` to read the last component, which
# SILENTLY RETURNS NOTHING - a command-line assertion on Windows is required for that form, and
# NSIS does not flag it. The macro compiled, ran, and renamed nothing. build/rename-probe.nsi
# is what caught it, and this version needs no path parsing at all: the root comes from the
# same variables electron-builder's own template uses.
#
# # What it deliberately does not do
#
# `/D=<path>` is the documented way to choose an installation directory, and a path recorded
# from a previous installation is where that user's files already are. Both win over the
# default; only electron-builder's own derived default is replaced.
!macro chooseForkInstallationDirectory
  Push $0
  StrCpy $0 ""

  # A previous installation's own record of where it went. The key is
  # `Software\${APP_GUID}` under SHELL_CONTEXT - the same key electron-builder's multiUser.nsh
  # reads before falling back to a default, so this agrees with it rather than competing.
  # On a fresh machine it is empty, which is what leaves the default below in charge.
  ReadRegStr $0 SHELL_CONTEXT "${INSTALL_REGISTRY_KEY}" "InstallLocation"

  ${if} $0 == ""
    StrCpy $0 "$PROGRAMFILES"
    !ifdef APP_64
      # Same condition as multiUser.nsh: a 64-bit installer's default on a 64-bit Windows is
      # the 64-bit Program Files. On a 32-bit Windows $PROGRAMFILES already is Program Files.
      ${if} ${RunningX64}
        StrCpy $0 "$PROGRAMFILES64"
      ${endif}
    !endif
    !ifdef APP_ARM64
      ${if} ${RunningX64}
      ${orif} ${IsNativeARM64}
        StrCpy $0 "$PROGRAMFILES64"
      ${endif}
    !endif
    # BOTH components, not just the fork's own name.
    #
    # This used to be `"$0\${FORK_INSTALLATION_DIRECTORY_NAME}"`, which left `$INSTDIR` as
    # `C:\Program Files\Jiejiebox` - a path that does NOT end with `${APP_FILENAME}`, and so
    # violates the contract described at FORK_INSTALLATION_SUBDIRECTORY. The `\sing-box` was then
    # put back by customInstallBeforeInstallationChanges, whose test for whether it was needed was
    # `${StrContains} $0 "${APP_FILENAME}" $INSTDIR` - a SUBSTRING search, not a path check.
    #
    # The installed directory is unchanged by this edit: `...\Jiejiebox` + the append and
    # `...\Jiejiebox\sing-box` directly are the same path, and the observed records show the
    # installer producing `C:\Program Files\Jiejiebox\sing-box` both before and after. What
    # changes is that the path is now CONSTRUCTED rather than repaired by a string search, and the
    # substring search that could silently accept a wrong directory is gone.
    StrCpy $0 "$0\${FORK_INSTALLATION_SUBDIRECTORY}"
  ${endif}

  # Set INSTDIR rather than the default-only variable: everything downstream - the data
  # directories page, the preflight, the service command, the uninstaller - reads $INSTDIR.
  StrCpy $INSTDIR $0
  Pop $0
!macroend

# Restores the one property every route into this installer is supposed to arrive with:
# `$INSTDIR` ends with `${APP_FILENAME}`.
#
# # Why this is a SUFFIX test and not the substring test it replaces
#
# Both insertion points used to run
#
#     ${StrContains} $0 "${APP_FILENAME}" $INSTDIR
#     ${if} $0 == ""
#       StrCpy $INSTDIR "$INSTDIR\${APP_FILENAME}"
#     ${endif}
#
# `${StrContains}` asks whether the string "sing-box" appears ANYWHERE in the path. That is not
# the contract and it is not a directory boundary: `C:\Program Files\sing-box-tools`,
# `C:\Program Files\old\sing-box-backup` and `C:\sing-box\Jiejiebox` all contain it and all
# therefore SKIP the repair, leaving `$INSTDIR` a directory that does not end in the executable
# name. This fork has already paid for exactly this class of bug once - the instance guard's bare
# `StartsWith($INSTDIR)` matched `Jiejiebox-old` and `Jiejiebox2`, which is why it now compares
# against `$INSTDIR\`.
#
# The suffix test has the same effect on every path that reaches it today (all of them end in
# `\sing-box` or in nothing at all) and refuses to be fooled by a path that merely mentions the
# name. The function touches only `$R1`, which is not a register either call site relies on:
# customInstallBeforeInstallationChanges treats `$0`, `$1` and `$2` as live, and
# showInstallationDirectoryValidationPage uses `$0` for the dialog handle.
!macro fixForkInstallationDirectory
  Call fixForkInstallationDirectoryOnce
!macroend

# The body of the macro above, as a FUNCTION rather than inline macro text.
#
# NSIS labels are scoped to the enclosing function and not to the macro, so a loop label written
# inline collides as soon as the macro is inserted more than once: makensis reports
#
#     Error: label "..." already declared in section
#
# This macro has two insertion points (customInstallBeforeInstallationChanges and
# showInstallationDirectoryValidationPage), so the trim loop cannot live in the macro body. A
# function has its own label scope, so a function can carry the loop no matter how many call
# sites there are - and the macro stays a one-line call.
#
# It touches only $R1, and that register belongs to this function's macro, not to the callers.
# Both call sites treat $0, $1 and $2 as live.
Function fixForkInstallationDirectoryOnce
  # Drop trailing separators first. `C:\...\sing-box\` and `C:\...\sing-box` are the same
  # directory, but only the second matches the suffix check below - and a `/D=` argument, or a
  # registry value copied by hand, can easily carry the separator. Without this the repair would
  # append a second one (`...\sing-box\\sing-box`), which is a different path, not the same one.
  trimTrailingSeparators:
    StrCpy $R1 $INSTDIR 1 -1
    StrCmp $R1 "\" 0 trailingSeparatorsTrimmed
    StrCpy $INSTDIR $INSTDIR -1
    StrCmp $INSTDIR "" 0 trimTrailingSeparators
  trailingSeparatorsTrimmed:

  # Nothing to repair in an empty $INSTDIR, and repairing it would produce the rooted-looking
  # garbage "\sing-box". Left alone so a caller that reached here with nothing gets an obvious
  # failure at the preflight, not a plausible directory name.
  StrCmp $INSTDIR "" fixForkInstallationDirectoryDone

  # `${APP_FILENAME}` is 8 characters, so `\` + it is 9 - the same slice the
  # `StrCpy $var $in "" -1` form would need, and this form is not silently empty.
  StrCpy $R1 $INSTDIR 9 -9
  StrCmp $R1 "\${APP_FILENAME}" fixForkInstallationDirectoryDone 0
  StrCmp $INSTDIR "${APP_FILENAME}" fixForkInstallationDirectoryDone 0
  StrCpy $INSTDIR "$INSTDIR\${APP_FILENAME}"
  fixForkInstallationDirectoryDone:
FunctionEnd

!macro customInstallBeforeCheckAppRunning
  SetDetailsPrint both
  DetailPrint "$(checkingRunningApplication)"
!macroend

!macro customInstallBeforeInstallationChanges
  SetDetailsPrint both
  !insertmacro fixForkInstallationDirectory
  # The previous version's daemon service, removed BEFORE electron-builder's
  # `uninstallOldVersion` and before any file is written - see
  # installer-remove-legacy-service.ps1, which owns the ownership decision and is invoked with
  # the evidence it needs. This step has to run here rather than in customInstall for two
  # reasons: `uninstallOldVersion` removes the old tree, and the running daemon holds files the
  # new installation has to replace.
  nsExec::ExecToLog '"$SYSDIR\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$PLUGINSDIR\installer-remove-legacy-service.ps1" -LegacyLayoutRegistryKey "${LEGACY_INSTALLATION_LAYOUT_REGISTRY_KEY}" -LegacyApplicationDataDirectoryName "${LEGACY_APPLICATION_DATA_DIRECTORY_NAME}"'
  Pop $1
  ${if} $1 != 0
    # Not fatal, and deliberately not an Abort: the service this installer registers is a
    # different one, so a failure here leaves the new installation working and only the
    # obsolete service behind. Failing the install would trade a leftover for a broken product.
    DetailPrint "$(legacyServiceCleanupFailed)"
  ${endif}
  ${if} $resetWorkingDirectory == 1
    DetailPrint "$(resettingWorkingDirectory)"
    ${if} $allowUnsafeInstallation == 1
      nsExec::ExecToLog '"$SYSDIR\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$PLUGINSDIR\installer-preflight.ps1" -InstallationDirectory "$INSTDIR" -ApplicationDataDirectory "$applicationDataDirectory" -DaemonWorkingDirectory "$daemonDataDirectory" -InstallationID "$installationID" -AllowUnsafeInstallationDirectory -ResetWorkingDirectory'
    ${else}
      nsExec::ExecToLog '"$SYSDIR\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$PLUGINSDIR\installer-preflight.ps1" -InstallationDirectory "$INSTDIR" -ApplicationDataDirectory "$applicationDataDirectory" -DaemonWorkingDirectory "$daemonDataDirectory" -InstallationID "$installationID" -ResetWorkingDirectory'
    ${endif}
    Pop $1
    ${if} $1 != 0
      Abort "$(resetWorkingDirectoryFailed)"
    ${endif}
  ${endif}
  validateInstallationDirectory:
  DetailPrint "$(checkingInstallationLocations)"
  ${if} $allowUnsafeInstallation == 1
    !insertmacro executeInstallationPreflight "-AllowUnsafeInstallationDirectory"
  ${else}
    !insertmacro executeInstallationPreflight ""
  ${endif}
  ${if} $1 == 13
  ${orif} $1 == 17
  ${orif} $1 == 18
    ${if} ${Silent}
      !insertmacro executeInstallationPreflight "-RepairPathAncestors"
      ${if} $1 == 0
        Goto validateInstallationDirectory
      ${elseif} $1 != 20
      ${andif} $1 != 21
      ${andif} $1 != 22
        Abort "$(repairInstallationAncestorFailed)"
      ${endif}
    ${endif}
  ${endif}
  ${if} $1 == 20
  ${orif} $1 == 21
  ${orif} $1 == 22
    ${if} ${Silent}
      DetailPrint "$(resettingWorkingDirectory)"
      nsExec::ExecToLog '"$SYSDIR\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$PLUGINSDIR\installer-preflight.ps1" -InstallationDirectory "$INSTDIR" -ApplicationDataDirectory "$applicationDataDirectory" -DaemonWorkingDirectory "$daemonDataDirectory" -InstallationID "$installationID" -ResetWorkingDirectory'
      Pop $1
      ${if} $1 != 0
        Abort "$(resetWorkingDirectoryFailed)"
      ${endif}
      Goto validateInstallationDirectory
    ${endif}
  ${endif}
  ${if} $1 != 0
    Call setInstallationValidationMessage
    Abort "$installationValidationMessage"
  ${endif}
  ${if} $applicationDataDirectory != ""
    DetailPrint "$(preparingApplicationDataDirectory)"
    ${if} $allowUnsafeInstallation == 1
      !insertmacro executeInstallationPreflight "-AllowUnsafeInstallationDirectory -PrepareApplicationDataDirectory"
    ${else}
      !insertmacro executeInstallationPreflight "-PrepareApplicationDataDirectory"
    ${endif}
    ${if} $1 != 0
      Call setInstallationValidationMessage
      Abort "$installationValidationMessage"
    ${endif}
  ${endif}
  DetailPrint "$(stoppingService)"
  # Stopping a service by name is only safe when the service is ours - see
  # installer-stop-service.ps1, which resolves the SCM's own record of the daemon's path and
  # refuses to touch a service registered outside this installation.
  nsExec::ExecToLog '"$SYSDIR\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$PLUGINSDIR\installer-stop-service.ps1" -ServiceName "${DEFINE_SERVICE_NAME}" -InstallationDirectory "$INSTDIR"'
  Pop $1
  ${if} $1 != 0
    Abort "$(stopServiceFailed)"
  ${endif}
  StrCpy $2 0
  ${if} $reinstallExistingInstallation == 1
    StrCpy $2 1
  ${elseif} $migrateLegacyApplicationData == 1
    StrCpy $2 1
  ${elseif} $hasExistingInstallation == 0
  ${andif} $hasInstallationLayout == 1
    StrCpy $2 1
  ${endif}
  ${if} $2 == 1
  ${andif} $migrateExistingData == ${BST_CHECKED}
    DetailPrint "$(migratingExistingData)"
    # The gating state goes into the record: a Prepare that should not have run, and one that ran
    # and failed, are indistinguishable from the outside otherwise.
    !insertmacro ciDiagnostic "customInstallBeforeInstallationChanges" "Prepare gating: existing=$hasExistingInstallation layout=$hasInstallationLayout reinstall=$reinstallExistingInstallation legacyMigrate=$migrateLegacyApplicationData statePresent=$dataTransitionStatePresent"
    !insertmacro executeDataTransition "Prepare" $R2
    ${if} $R2 != 0
      StrCpy $2 $R2
      !insertmacro executeDataTransition "Rollback" $R2
      StrCpy $1 $2
      Abort "$(dataMigrationFailed)"
    ${endif}
    StrCpy $dataMigrationPrepared 1
  ${endif}
!macroend

!macro customInstallBeforeRemovingPreviousVersion
  ${if} $hasExistingInstallation == 1
    DetailPrint "$(removingPreviousVersion)"
  ${endif}
!macroend

!macro customInstallBeforeApplicationFiles
  DetailPrint "$(copyingApplicationFiles)"
!macroend

!macro customUnInstallCheck
  ${if} $R0 != 0
    DetailPrint "$(previousUninstallerFailed)"
  ${endif}
!macroend

!macro customInstall
  !insertmacro ciDiagnostic "customInstall" "ENTER"
  !insertmacro daemonExecutable $0
  SetDetailsPrint both
  DetailPrint "$(registeringService)"
  ${if} $allowUnsafeInstallation == 1
    !insertmacro executeDaemonServiceCommand "install" "-AllowUnsafeInstallationDirectoryPermissions" $1 $3
  ${else}
    !insertmacro executeDaemonServiceCommand "install" "" $1 $3
  ${endif}
  ${if} $1 != 0
    StrCpy $5 $1
    !insertmacro ciDiagnostic "customInstall" "service install failed with code $1; starting rollback"
    DetailPrint "$(rollingBackInstallation)"
    StrCpy $2 -1
    ClearErrors
    ExecWait '"$INSTDIR\${UNINSTALL_FILENAME}" /allusers /S' $2
    ${if} ${Errors}
      StrCpy $2 -1
    ${endif}
    !insertmacro executeDataTransition "Rollback" $R2
    StrCpy $1 $5
    !insertmacro ciDiagnostic "customInstall" "rollback uninstaller exit=$2; original service install code=$1"
    ${if} $2 == 0
      Abort "$(registerServiceFailedRolledBack)"
    ${else}
      Abort "$(registerServiceFailedRollbackFailed)"
    ${endif}
  ${endif}
  !insertmacro setInstallationLayoutRegistryView
  WriteRegDWORD HKLM "${INSTALLATION_LAYOUT_REGISTRY_KEY}" "LayoutVersion" 2
  WriteRegStr HKLM "${INSTALLATION_LAYOUT_REGISTRY_KEY}" "InstallationID" "$installationID"
  ${if} $applicationDataDirectory == ""
    DeleteRegValue HKLM "${INSTALLATION_LAYOUT_REGISTRY_KEY}" "ApplicationDataDirectory"
  ${else}
    WriteRegStr HKLM "${INSTALLATION_LAYOUT_REGISTRY_KEY}" "ApplicationDataDirectory" "$applicationDataDirectory"
  ${endif}
  WriteRegStr HKLM "${INSTALLATION_LAYOUT_REGISTRY_KEY}" "DaemonDataDirectory" "$daemonDataDirectory"
  !insertmacro restoreInstallerRegistryView
  !insertmacro registerTaildropVerb
  ${if} $dataMigrationPrepared == 1
    DetailPrint "$(completingDataMigration)"
  ${endif}
  # The result is read from its OWN register, not from $1. $1 is a live caller register here
  # (customInstallBeforeInstallationChanges leaves the service-install code in it) and this macro
  # no longer writes $1 at all, so testing $1 would test an unrelated value.
  !insertmacro executeDataTransition "Commit" $R2
  ${if} $R2 != 0
    MessageBox MB_OK|MB_ICONEXCLAMATION "$(dataMigrationCleanupFailed)" /SD IDOK
  ${endif}
  StrCpy $4 0
  !insertmacro refreshDesktopShortcutIfPresent "$newDesktopLink" "$oldDesktopLink" $4
  SetShellVarContext current
  StrCpy $5 "$DESKTOP\${SHORTCUT_NAME}.lnk"
  StrCpy $6 "$DESKTOP\$oldShortcutName.lnk"
  !insertmacro refreshDesktopShortcutIfPresent "$5" "$6" $4
  SetShellVarContext all
  ${if} $4 == 1
    System::Call 'shell32::SHChangeNotify(i 0x8000000, i 0, i 0, i 0)'
  ${endif}
  !insertmacro ciDiagnostic "customInstall" "EXIT"
!macroend

!macro customFinishPage
  !define MUI_FINISHPAGE_SHOWREADME
  !define MUI_FINISHPAGE_SHOWREADME_TEXT "$(createDesktopShortcut)"
  !define MUI_FINISHPAGE_SHOWREADME_FUNCTION "createDesktopShortcut"
  !define MUI_PAGE_CUSTOMFUNCTION_SHOW showDesktopShortcutFinishOption
  !define MUI_PAGE_CUSTOMFUNCTION_LEAVE leaveCustomFinishPage
  !insertmacro MUI_PAGE_FINISH

  Function StartApp
    !insertmacro ciDiagnostic "StartApp" "ENTER"
    ${if} ${isUpdated}
      StrCpy $1 "--updated"
    ${else}
      StrCpy $1 ""
    ${endif}
    ${StdUtils.ExecShellAsUser} $0 "$launchLink" "open" "$1"
    !insertmacro ciDiagnostic "StartApp" "RETURN"
  FunctionEnd

  Function createDesktopShortcut
    !insertmacro ciDiagnostic "createDesktopShortcut" "ENTER"
    ${ifNot} ${FileExists} "$newDesktopLink"
      CreateShortCut "$newDesktopLink" "$appExe" "" "$appExe" 0 "" "" "${APP_DESCRIPTION}"
      ClearErrors
      WinShell::SetLnkAUMI "$newDesktopLink" "${APP_ID}"
      System::Call 'shell32::SHChangeNotify(i 0x8000000, i 0, i 0, i 0)'
    ${endif}
  FunctionEnd

  Function showDesktopShortcutFinishOption
    !insertmacro ciDiagnostic "showDesktopShortcutFinishOption" "ENTER"
    ${if} ${isUpdated}
    ${andif} ${isForceRun}
      Call StartApp
      !insertmacro quitSuccess
    ${endif}
    StrCpy $0 0
    ${if} ${FileExists} "$newDesktopLink"
    ${orif} ${FileExists} "$oldDesktopLink"
      StrCpy $0 1
    ${endif}
    SetShellVarContext current
    ${if} ${FileExists} "$DESKTOP\${SHORTCUT_NAME}.lnk"
    ${orif} ${FileExists} "$DESKTOP\$oldShortcutName.lnk"
      StrCpy $0 1
    ${endif}
    SetShellVarContext all
    ${if} $0 == 1
      ${NSD_SetState} $mui.FinishPage.ShowReadme ${BST_UNCHECKED}
      ShowWindow $mui.FinishPage.ShowReadme ${SW_HIDE}
      StrCpy $0 90
    ${else}
      StrCpy $0 100
    ${endif}
    ${ifNot} ${RebootFlag}
      ${NSD_CreateCheckBox} 120u $0u 195u 10u "$(MUI_TEXT_FINISH_RUN)"
      Pop $finishRunCheckbox
      SetCtlColors $finishRunCheckbox "${MUI_TEXTCOLOR}" "${MUI_BGCOLOR}"
      ${NSD_SetState} $finishRunCheckbox ${BST_CHECKED}
    ${endif}
  FunctionEnd

  Function leaveCustomFinishPage
    !insertmacro ciDiagnostic "leaveCustomFinishPage" "ENTER"
    ${ifNot} ${RebootFlag}
      ${NSD_GetState} $finishRunCheckbox $0
      ${if} $0 == ${BST_CHECKED}
        Call StartApp
      ${endif}
    ${endif}
  FunctionEnd

!macroend

!macro customUnWelcomePage
  Var keepUninstallData
  Var keepUninstallDataCheckbox

  !define MUI_PAGE_CUSTOMFUNCTION_SHOW un.showKeepDataCheckbox
  !define MUI_PAGE_CUSTOMFUNCTION_LEAVE un.readKeepDataCheckbox
  !insertmacro MUI_UNPAGE_WELCOME

  Function un.showKeepDataCheckbox
    ${NSD_CreateCheckBox} 120u 175u 195u 12u "$(keepData)"
    Pop $keepUninstallDataCheckbox
    ${NSD_SetState} $keepUninstallDataCheckbox $keepUninstallData
    SetCtlColors $keepUninstallDataCheckbox "${MUI_TEXTCOLOR}" "${MUI_BGCOLOR}"
  FunctionEnd

  Function un.readKeepDataCheckbox
    ${NSD_GetState} $keepUninstallDataCheckbox $keepUninstallData
  FunctionEnd
!macroend

!macro customUnInit
  # Open the diagnostic channel here too. The path variable is shared with the installer
  # pass, and the installer's customInit is what normally sets it - but customInit never
  # runs during an uninstall, so every uninstall-side marker was inert and the record
  # looked as if the uninstall code had never executed at all.
  StrCpy $ciDiagnosticPath ""
  ClearErrors
  ${GetParameters} $R0
  ${GetOptions} $R0 "/CI-DIAGNOSTIC-PATH=" $R1
  ${ifNot} ${Errors}
    StrCpy $ciDiagnosticPath $R1
  ${endif}
  !insertmacro ciDiagnostic "customUnInit" "ENTER"
  StrCpy $keepUninstallData ${BST_CHECKED}
  !insertmacro setInstallationLayoutRegistryView
  StrCpy $applicationDataDirectory ""
  StrCpy $installationID ""
  SetShellVarContext all
  # Read back from the same place the installer wrote. This is the fallback for a layout
  # key that was never written; it has to be %ProgramData% for the same reason customInit
  # says so - see COMMON_APPLICATION_DATA at the top of this file.
  StrCpy $daemonDataDirectory "${COMMON_APPLICATION_DATA}\${DAEMON_DATA_DIRECTORY_NAME}"
  StrCpy $0 0
  ReadRegDWORD $0 HKLM "${INSTALLATION_LAYOUT_REGISTRY_KEY}" "LayoutVersion"
  ${if} $0 == 2
    ReadRegStr $applicationDataDirectory HKLM "${INSTALLATION_LAYOUT_REGISTRY_KEY}" "ApplicationDataDirectory"
    ReadRegStr $daemonDataDirectory HKLM "${INSTALLATION_LAYOUT_REGISTRY_KEY}" "DaemonDataDirectory"
    ReadRegStr $installationID HKLM "${INSTALLATION_LAYOUT_REGISTRY_KEY}" "InstallationID"
  ${endif}
  !insertmacro restoreInstallerRegistryView
  InitPluginsDir
  # Staged for customUnInstall, which runs the legacy service cleanup too - see there for why
  # the uninstall direction needs it as well.
  File /oname=$PLUGINSDIR\installer-remove-legacy-service.ps1 "${BUILD_RESOURCES_DIR}\installer-remove-legacy-service.ps1"
  File /oname=$PLUGINSDIR\installer-legacy-service-ownership.ps1 "${BUILD_RESOURCES_DIR}\installer-legacy-service-ownership.ps1"
  File /oname=$PLUGINSDIR\installer-service.ps1 "${BUILD_RESOURCES_DIR}\installer-service.ps1"
  File /oname=$PLUGINSDIR\installer-preflight.ps1 "${BUILD_RESOURCES_DIR}\installer-preflight.ps1"
  ${GetParameters} $R0
  ${GetOptions} $R0 "--delete-app-data" $R1
  ${ifNot} ${Errors}
    StrCpy $keepUninstallData ${BST_UNCHECKED}
  ${endif}
  !insertmacro ciDiagnostic "customUnInit" "EXIT"
!macroend

!macro customUnInstall
  !insertmacro ciDiagnostic "customUnInstall" "ENTER"
  SetDetailsPrint both
  ${ifNot} ${isUpdated}
    !insertmacro ciDiagnostic "customUnInstall" "branch=standalone (isUpdated false)"
    !insertmacro daemonExecutable $0
    !insertmacro ciDiagnostic "customUnInstall" "daemon path resolved; FileExists checked next"
    ${if} ${FileExists} "$0"
      !insertmacro ciDiagnostic "customUnInstall" "daemon PRESENT; calling service uninstall"
      DetailPrint "$(removingService)"
      !insertmacro executeDaemonServiceCommand "uninstall" "" $1 $3
      ${if} $1 != 0
        Abort "$(removeServiceFailed)"
      ${endif}
    ${endif}
    # The same cleanup the installer runs, for the other order: a previous version installed,
    # this version never installed over it, and now this version is being removed. Only
    # `jiejiebox-daemon` is registered at this point, so `service uninstall` above leaves the
    # older `sing-box-daemon` behind - and the upgrade path removed it only if an upgrade
    # actually happened.
    #
    # It is the same script, so it is the same evidence: nothing is deleted unless the
    # ownership marker this client writes is present. On a machine where the service belongs to
    # the upstream client, this does nothing.
    nsExec::ExecToLog '"$SYSDIR\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$PLUGINSDIR\installer-remove-legacy-service.ps1" -LegacyLayoutRegistryKey "${LEGACY_INSTALLATION_LAYOUT_REGISTRY_KEY}" -LegacyApplicationDataDirectoryName "${LEGACY_APPLICATION_DATA_DIRECTORY_NAME}"'
    Pop $1
    ${if} $1 != 0
      DetailPrint "$(legacyServiceCleanupFailed)"
    ${endif}
    !insertmacro unregisterTaildropVerb
    ${if} $keepUninstallData == ${BST_UNCHECKED}
      DetailPrint "$(removingData)"
      nsExec::ExecToLog '"$SYSDIR\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$PLUGINSDIR\installer-preflight.ps1" -InstallationDirectory "$INSTDIR" -ApplicationDataDirectory "$applicationDataDirectory" -DaemonWorkingDirectory "$daemonDataDirectory" -InstallationID "$installationID" -AllowUnsafeInstallationDirectory -DeleteDataDirectories'
      Pop $1
        !insertmacro ciDiagnostic "uninstallDeleteData" "preflight returned ${1}"
      ${if} $1 != 0
        Abort "$(preflightFailed)"
      ${endif}
      # No remove-data fallback for the application data directory, deliberately.
      #
      # This used to be `RMDir /r "$APPDATA\sing-box"` - the UPSTREAM client's directory, which
      # this client no longer uses. An uninstall that removes data must remove this
      # installation's data, and "the layout says nothing, so delete the other product's
      # folder" is the opposite of that: it is the one destructive path in the whole installer
      # that could reach into an installation it does not own.
      #
      # Nothing is lost by leaving it to the branch above. When the layout names a directory,
      # the preflight deletes it with the installation-id check. When it does not name one,
      # this installation never created one - the installer always writes
      # ApplicationDataDirectory, or leaves the value absent to mean "the default", and the
      # runtime's default is %APPDATA%\jiejiebox, which no uninstall should ever guess at.
      !insertmacro setInstallationLayoutRegistryView
      DeleteRegKey HKLM "${INSTALLATION_LAYOUT_REGISTRY_KEY}"
      !insertmacro restoreInstallerRegistryView
    ${endif}
  ${endIf}
  !insertmacro ciDiagnostic "customUnInstall" "EXIT"
!macroend
