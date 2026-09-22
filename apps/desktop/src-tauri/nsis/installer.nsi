; Derived from Tauri CLI v2.11.4 installer.nsi. MIT license: TAURI-LICENSE-MIT.
; Codex-X changes: exact MSI migration, original-user context, exit handshake, logs.
Unicode true
ManifestDPIAware true
; Add in `dpiAwareness` `PerMonitorV2` to manifest for Windows 10 1607+ (note this should not affect lower versions since they should be able to ignore this and pick up `dpiAware` `true` set by `ManifestDPIAware true`)
; Currently undocumented on NSIS's website but is in the Docs folder of source tree, see
; https://github.com/kichik/nsis/blob/5fc0b87b819a9eec006df4967d08e522ddd651c9/Docs/src/attributes.but#L286-L300
; https://github.com/tauri-apps/tauri/pull/10106
ManifestDPIAwareness PerMonitorV2

!if "{{compression}}" == "none"
  SetCompress off
!else
  ; Set the compression algorithm. We default to LZMA.
  SetCompressor /SOLID "{{compression}}"
!endif

; Keep above !include to stay ahead of any plugin command
; see https://github.com/tauri-apps/tauri/pull/15422#discussion_r3289239624
{{#if signed_plugins_path}}
!addplugindir "{{signed_plugins_path}}"
{{/if}}

!include MUI2.nsh
!include FileFunc.nsh
!include x64.nsh
!include WordFunc.nsh
!include "utils.nsh"
!include "FileAssociation.nsh"
!include "Win\COM.nsh"
!include "Win\Propkey.nsh"
!include "StrFunc.nsh"
${StrLoc}

{{#if installer_hooks}}
!include "{{installer_hooks}}"
{{/if}}

!define WEBVIEW2APPGUID "{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}"

!define MANUFACTURER "{{manufacturer}}"
!define PRODUCTNAME "{{product_name}}"
!define VERSION "{{version}}"
!define VERSIONWITHBUILD "{{version_with_build}}"
!define HOMEPAGE "{{homepage}}"
!define INSTALLMODE "{{install_mode}}"
!define LICENSE "{{license}}"
!define INSTALLERICON "{{installer_icon}}"
!define SIDEBARIMAGE "{{sidebar_image}}"
!define HEADERIMAGE "{{header_image}}"
!define UNINSTALLERICON "{{uninstaller_icon}}"
!define UNINSTALLERHEADERIMAGE "{{uninstaller_header_image}}"
!define MAINBINARYNAME "{{main_binary_name}}"
!define MAINBINARYSRCPATH "{{main_binary_path}}"
!define BUNDLEID "{{bundle_id}}"
!define COPYRIGHT "{{copyright}}"
!define OUTFILE "{{out_file}}"
!define ARCH "{{arch}}"
!define ADDITIONALPLUGINSPATH "{{additional_plugins_path}}"
!define ALLOWDOWNGRADES "{{allow_downgrades}}"
!define DISPLAYLANGUAGESELECTOR "{{display_language_selector}}"
!define INSTALLWEBVIEW2MODE "{{install_webview2_mode}}"
!define WEBVIEW2INSTALLERARGS "{{webview2_installer_args}}"
!define WEBVIEW2BOOTSTRAPPERPATH "{{webview2_bootstrapper_path}}"
!define WEBVIEW2INSTALLERPATH "{{webview2_installer_path}}"
!define MINIMUMWEBVIEW2VERSION "{{minimum_webview2_version}}"
!define UNINSTKEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\${PRODUCTNAME}"
!define MANUKEY "Software\${MANUFACTURER}"
!define MANUPRODUCTKEY "${MANUKEY}\${PRODUCTNAME}"
!define UNINSTALLERSIGNCOMMAND "{{uninstaller_sign_cmd}}"
!define ESTIMATEDSIZE "{{estimated_size}}"
!define STARTMENUFOLDER "{{start_menu_folder}}"

Var PassiveMode
Var UpdateMode
Var NoShortcutMode
Var WixMode
Var OldMainBinaryName

Name "${PRODUCTNAME}"
BrandingText "${COPYRIGHT}"
OutFile "${OUTFILE}"

; We don't actually use this value as default install path,
; it's just for nsis to append the product name folder in the directory selector
; https://nsis.sourceforge.io/Reference/InstallDir
!define PLACEHOLDER_INSTALL_DIR "placeholder\${PRODUCTNAME}"
InstallDir "${PLACEHOLDER_INSTALL_DIR}"

VIProductVersion "${VERSIONWITHBUILD}"
VIAddVersionKey "ProductName" "${PRODUCTNAME}"
VIAddVersionKey "FileDescription" "${PRODUCTNAME}"
VIAddVersionKey "LegalCopyright" "${COPYRIGHT}"
VIAddVersionKey "FileVersion" "${VERSION}"
VIAddVersionKey "ProductVersion" "${VERSION}"

# additional plugins
!addplugindir "${ADDITIONALPLUGINSPATH}"

; Codex-X additions. Parent installer always stays in the original user context.
!define CODEXX_LEGACY_UPGRADE_CODE "{1482A8E8-9217-517B-8528-93A6C90E0C2F}"
Var CXLogPath
Var CXError
Var CXLegacyProduct
Var CXLegacyVersion
Var CXMsiLog
Var CXProcess
Var CXOldProcess
Var CXWaitTicks
Var CXExitCode
Var CXMigrations
Var CXLegacyDirectory
Var CXPathInput
Var CXPathFull
Var CXPathSuffix
Var CXPathResult
Var CXPathDepth
Var CXDestinationFull
Var CXDestinationReal
Var CXDirectoryIndex
Var CXReservedPath
!define CX_DIRECTORY_KEY "Software\${MANUFACTURER}\${PRODUCTNAME} Installer\LegacyDirectories"

Function CXLog
  Exch $R9
  Push $R8
  DetailPrint "$R9"
  FileOpen $R8 "$CXLogPath" a
  FileSeek $R8 0 END
  FileWriteUTF16LE $R8 "$R9$\r$\n"
  FileClose $R8
  Pop $R8
  Pop $R9
FunctionEnd

Function CXFail
  Pop $CXError
  Push "$CXError"
  Call CXLog
  IfSilent +2
    MessageBox MB_ICONSTOP|MB_OK "$CXError$\r$\n$\r$\n安装日志 / Installer log:$\r$\n$CXLogPath"
  SetErrorLevel 1
  Quit
FunctionEnd

Function CXCanonicalDirectory
  ; Resolve the nearest existing ancestor through a real directory handle.
  ; Volume GUID names unify drive letters, junctions, symbolic links and 8.3
  ; aliases. Append only the normalized, non-existent suffix afterwards.
  System::Call 'shlwapi::PathIsRelativeW(w "$CXPathInput")i.r0'
  ${If} $0 != 0
    Push "安装目录必须是完整路径。 / An absolute installation path is required."
    Call CXFail
  ${EndIf}
  ClearErrors
  GetFullPathName $CXPathFull "$CXPathInput"
  ${If} ${Errors}
    Push "无法读取安装目录。 / Cannot resolve the installation directory."
    Call CXFail
  ${EndIf}
  StrLen $0 $CXPathFull
  StrCpy $1 $CXPathFull 1 -1
  ${If} $0 > 3
  ${AndIf} $1 == "\"
    StrCpy $CXPathFull $CXPathFull -1
  ${EndIf}
  StrCpy $CXPathSuffix ""
  StrCpy $CXPathDepth 0
  cx_resolve_ancestor:
    System::Call 'kernel32::CreateFileW(w "$CXPathFull",i 0,i 7,p 0,i 3,i 0x02000000,p 0)p.r0 ?e'
    Pop $1
    ${If} $0 != -1
      System::Call 'kernel32::GetFinalPathNameByHandleW(p r0,w .r2,i ${NSIS_MAX_STRLEN},i 1)i.r3'
      System::Call 'kernel32::CloseHandle(p r0)'
      ${If} $3 = 0
      ${OrIf} $3 >= ${NSIS_MAX_STRLEN}
        Push "无法确认安装目录的实际位置。请选择本机上的其他目录。 / Cannot verify the real directory; choose another local path."
        Call CXFail
      ${EndIf}
      StrCpy $4 $2 1 -1
      ${If} $4 == "\"
        StrCpy $2 $2 -1
      ${EndIf}
      StrCpy $CXPathResult "$2$CXPathSuffix\"
      Return
    ${EndIf}
    ${If} $1 != 2
    ${AndIf} $1 != 3
      Push "无法访问安装目录 (Windows $1)。请选择本机上的其他目录。 / Cannot access the installation directory."
      Call CXFail
    ${EndIf}
    ${GetParent} "$CXPathFull" $2
    ${GetFileName} "$CXPathFull" $3
    ${If} $2 == ""
    ${OrIf} $2 == $CXPathFull
    ${OrIf} $3 == ""
      Push "无法确认安装目录的上级位置。 / Cannot resolve the installation directory's parent."
      Call CXFail
    ${EndIf}
    StrCpy $CXPathSuffix "\$3$CXPathSuffix"
    StrCpy $CXPathFull $2
    ; GetParent of C:\child can return C:, which is drive-relative to Win32.
    StrLen $0 $CXPathFull
    ${If} $0 = 2
      StrCpy $CXPathFull "$CXPathFull\"
    ${EndIf}
    IntOp $CXPathDepth $CXPathDepth + 1
    ${If} $CXPathDepth > 256
      Push "安装路径层级过深。 / Installation path is too deeply nested."
      Call CXFail
    ${EndIf}
    Goto cx_resolve_ancestor
FunctionEnd

Function CXRememberLegacyDirectory
  System::Call 'msi::MsiGetProductInfoExW(w "$CXLegacyProduct",p 0,i 4,w "InstallLocation",w .r0,*i ${NSIS_MAX_STRLEN})i.r1'
  ${If} $1 != 0
  ${OrIf} $0 == ""
    Push "无法读取旧版安装目录。请先在系统设置中卸载旧版，再安装新版本。 / Cannot verify the legacy installation directory."
    Call CXFail
  ${EndIf}
  System::Call 'shlwapi::PathIsRelativeW(w r0)i.r1'
  ${If} $1 != 0
    Push "旧版安装目录不是有效的完整路径，已停止迁移。 / The legacy installation path is not absolute."
    Call CXFail
  ${EndIf}
  GetFullPathName $CXLegacyDirectory "$0"
  StrCpy $0 $CXLegacyDirectory 1 -1
  ${If} $0 != "\"
    StrCpy $CXLegacyDirectory "$CXLegacyDirectory\"
  ${EndIf}
  StrCpy $CXPathInput $CXLegacyDirectory
  Call CXCanonicalDirectory
  ; Retain both lexical and resolved names. A later junction change must not
  ; redirect a delayed removal from the old lexical path into the new app.
  ; Kept outside the normal uninstall key so an interrupted/retried migration
  ; cannot forget these reserved paths. These values contain paths, no secrets.
  ClearErrors
  WriteRegStr HKCU "${CX_DIRECTORY_KEY}" "Path_$CXLegacyProduct" $CXLegacyDirectory
  WriteRegStr HKCU "${CX_DIRECTORY_KEY}" "Real_$CXLegacyProduct" $CXPathResult
  ${If} ${Errors}
    Push "无法保存旧版安装目录，未卸载旧版。 / Cannot save the legacy directory for safe migration."
    Call CXFail
  ${EndIf}
FunctionEnd

Function CXValidateDestination
  ; No filesystem scan is needed for normal fresh installs without history.
  EnumRegValue $0 HKCU "${CX_DIRECTORY_KEY}" 0
  ${If} $0 == ""
    Return
  ${EndIf}
  GetFullPathName $CXDestinationFull "$INSTDIR"
  StrCpy $0 $CXDestinationFull 1 -1
  ${If} $0 != "\"
    StrCpy $CXDestinationFull "$CXDestinationFull\"
  ${EndIf}
  StrCpy $CXPathInput $CXDestinationFull
  Call CXCanonicalDirectory
  StrCpy $CXDestinationReal $CXPathResult
  StrCpy $CXDirectoryIndex 0
  cx_check_reserved:
    EnumRegValue $0 HKCU "${CX_DIRECTORY_KEY}" $CXDirectoryIndex
    ${If} $0 == ""
      Return
    ${EndIf}
    ReadRegStr $1 HKCU "${CX_DIRECTORY_KEY}" "$0"
    ${If} $1 == ""
      Push "旧版安装目录记录不完整，已停止安装。 / The legacy directory record is incomplete."
      Call CXFail
    ${EndIf}
    StrCpy $CXReservedPath $1
    StrCpy $2 $0 5
    ${If} $2 == "Path_"
      ; Re-resolve the old lexical name as well: a junction may have changed
      ; since cancellation. Keep the originally saved Real_ guard too.
      StrCpy $CXPathInput $CXReservedPath
      Call CXCanonicalDirectory
      StrLen $2 $CXPathResult
      StrCpy $3 $CXDestinationReal $2
      ${If} $3 == $CXPathResult
        Push "新版本不能安装到旧目录指向的位置。请选择独立目录。 / The chosen path resolves inside a legacy installation directory."
        Call CXFail
      ${EndIf}
    ${EndIf}
    StrCpy $1 $CXReservedPath
    StrLen $2 $1
    StrCpy $3 $CXDestinationFull $2
    StrCpy $4 $CXDestinationReal $2
    ; NSIS StrCmp / LogicLib == are case insensitive. All names end in '\',
    ; so sibling folders such as Codex-X-New do not falsely match Codex-X.
    ${If} $3 == $1
    ${OrIf} $4 == $1
      Push "新版本需要安装到独立目录。请使用默认用户目录，不要选择旧版目录或它的子目录。 / Choose a separate directory, not the legacy MSI directory or its children."
      Call CXFail
    ${EndIf}
    IntOp $CXDirectoryIndex $CXDirectoryIndex + 1
    Goto cx_check_reserved
FunctionEnd

Function CXInitialize
  CreateDirectory "$LOCALAPPDATA\Codex-X-updates\logs"
  System::Call 'kernel32::GetCurrentProcessId()i.r0'
  System::Call 'kernel32::GetTickCount()i.r1'
  StrCpy $CXLogPath "$LOCALAPPDATA\Codex-X-updates\logs\install-$0-$1.log"
  ClearErrors
  FileOpen $2 "$CXLogPath" w
  IfErrors 0 +3
    MessageBox MB_ICONSTOP "无法创建安装日志。请检查当前用户目录的写入权限。 / Cannot create installer log."
    Quit
  FileWriteUTF16LE /BOM $2 'Codex-X ${VERSION}: current-user installer, NSIS x86 Unicode, target ${ARCH}$\r$\n'
  FileClose $2
  ; The actual wait is in EarlyChecks on the installation worker thread. Keep
  ; the handle now so a recycled PID cannot make us wait on an unrelated app.
  StrCpy $CXOldProcess 0
  ClearErrors
  ${GetOptions} $CMDLINE "/CODEXXPID=" $0
  ${IfNot} ${Errors}
    StrLen $1 $0
    ${If} $1 = 0
    ${OrIf} $1 > 10
      Push "无效的更新进程参数。 / Invalid updater process ID."
      Call CXFail
    ${EndIf}
    StrCpy $2 0
    cx_pid_digit:
      StrCpy $3 $0 1 $2
      ${StrLoc} $4 "0123456789" $3 ">"
      ${If} $4 == ""
        Push "无效的更新进程参数。 / Invalid updater process ID."
        Call CXFail
      ${EndIf}
      IntOp $2 $2 + 1
      IntCmp $2 $1 cx_pid_valid cx_pid_digit cx_pid_valid
    cx_pid_valid:
    System::Call 'kernel32::OpenProcess(i 0x100000,i 0,i r0)p.r1 ?e'
    Pop $2
    StrCpy $CXOldProcess $1
    ${If} $CXOldProcess = 0
    ${AndIf} $2 != 87
      Push "无法等待旧版退出 (Windows $2)。请关闭 Codex-X 后重新运行安装包。 / Could not wait for the old app to exit."
      Call CXFail
    ${EndIf}
  ${EndIf}
  Call CXDetectLegacyMsi
FunctionEnd

Function CXDetectLegacyMsi
  ; MsiEnumRelatedProducts matches our exact UpgradeCode, never an arbitrary
  ; DisplayName / Publisher or a registry-provided executable command.
  StrCpy $CXLegacyProduct ""
  StrCpy $CXLegacyVersion ""
  System::Call 'msi::MsiEnumRelatedProductsW(w "${CODEXX_LEGACY_UPGRADE_CODE}",i 0,i 0,w .r0)i.r1'
  Push "MSI enum: result=$1, product=$0, upgrade=${CODEXX_LEGACY_UPGRADE_CODE}"
  Call CXLog
  ${If} $1 = 259
    Return
  ${EndIf}
  ${If} $1 != 0
    Push "无法检查旧版安装 (Windows $1)。未更改已安装的软件。 / Could not inspect the previous installation."
    Call CXFail
  ${EndIf}
  StrCpy $CXLegacyProduct $0
  ; Only the shipped, machine-wide MSI is supported for automatic migration.
  ; Query its machine context explicitly, including with alternate UAC creds.
  System::Call 'msi::MsiGetProductInfoExW(w "$CXLegacyProduct",p 0,i 4,w "VersionString",w .r0,*i ${NSIS_MAX_STRLEN})i.r1'
  Push "MSI machine-context version: result=$1, version=$0, product=$CXLegacyProduct"
  Call CXLog
  ${If} $1 != 0
    Push "旧版安装信息不完整 (Windows $1)。请先在系统设置中卸载旧版 Codex-X，再运行此安装包。 / Previous installation could not be verified."
    Call CXFail
  ${EndIf}
  StrCpy $CXLegacyVersion $0
  Call CXRememberLegacyDirectory
  nsis_tauri_utils::SemverCompare "${VERSION}" $CXLegacyVersion
  Pop $0
  ${If} $0 = -1
    Push "已安装更新的 Codex-X $CXLegacyVersion，已停止安装旧版本。 / A newer Codex-X version is already installed."
    Call CXFail
  ${EndIf}
  ; WixMode is retained solely to make Tauri recreate shortcuts after MSI
  ; removal, including /UPDATE. The stock name-based MSI removal is disabled.
  StrCpy $WixMode 1
FunctionEnd

Function CXWaitForOldApp
  ${If} $CXOldProcess = 0
    Return
  ${EndIf}
  SetDetailsView show
  Push "正在等待 Codex-X 安全退出… / Waiting for Codex-X to exit…"
  Call CXLog
  StrCpy $CXWaitTicks 0
  cx_old_wait:
    System::Call 'kernel32::WaitForSingleObject(p $CXOldProcess,i 250)i.r0'
    ${If} $0 = 0
      System::Call 'kernel32::CloseHandle(p $CXOldProcess)'
      StrCpy $CXOldProcess 0
      Return
    ${EndIf}
    IntOp $CXWaitTicks $CXWaitTicks + 1
    ${If} $0 != 258
    ${OrIf} $CXWaitTicks >= 120
      System::Call 'kernel32::CloseHandle(p $CXOldProcess)'
      StrCpy $CXOldProcess 0
      Push "旧版尚未退出。请完全关闭 Codex-X 后重试；当前安装未被更改。 / Codex-X did not exit within 30 seconds. Close it and retry."
      Call CXFail
    ${EndIf}
    Goto cx_old_wait
FunctionEnd

Function CXWaitForRunningApp
  ; Also covers older MSI clients which do not pass /CODEXXPID, and a manually
  ; launched installer. Never kill the app while it may be restoring routes.
  StrCpy $CXWaitTicks 0
  cx_app_wait:
    nsis_tauri_utils::FindProcessCurrentUser "${MAINBINARYNAME}.exe"
    Pop $0
    ${If} $0 = 1
      Return
    ${EndIf}
    ${If} $CXWaitTicks = 0
      SetDetailsView show
      Push "请关闭 Codex-X（包括托盘），安装将在退出后继续。 / Close Codex-X, including its tray icon, to continue."
      Call CXLog
    ${EndIf}
    ${If} $0 != 0
    ${OrIf} $CXWaitTicks >= 120
      Push "Codex-X 仍在运行。请退出软件后重新运行安装包；尚未更改安装。 / Codex-X is still running. Exit the app and retry."
      Call CXFail
    ${EndIf}
    Sleep 250
    IntOp $CXWaitTicks $CXWaitTicks + 1
    Goto cx_app_wait
FunctionEnd

Function CXMigrateLegacyMsi
  StrCpy $CXMigrations 0
  cx_migrate_next:
  Call CXDetectLegacyMsi
  ${If} $CXLegacyProduct = ""
    Return
  ${EndIf}
  IntOp $CXMigrations $CXMigrations + 1
  ${If} $CXMigrations > 16
    Push "发现异常的旧版安装记录，已停止安装。 / Too many legacy registrations; migration stopped."
    Call CXFail
  ${EndIf}
  Call CXValidateDestination
  SetDetailsView show
  Push "正在迁移旧版 $CXLegacyVersion（仅本次需要管理员授权）。 / Migrating the previous MSI installation; administrator approval is needed once."
  Call CXLog
  StrCpy $CXMsiLog "$CXLogPath-msi-$CXMigrations.log"
  Push "MSI log: $CXMsiLog"
  Call CXLog
  ; Only elevate the trusted system msiexec child. Never restart this per-user
  ; installer with runas: alternate admin credentials must not change HKCU,
  ; LOCALAPPDATA, app settings, shortcuts, or the account launching the app.
  StrCpy $3 '/x $CXLegacyProduct /passive /norestart /L*v "$CXMsiLog"'
  ; SHELLEXECUTEINFOW, sized by System. NSIS uses the x86 stub on every target.
  ; SEE_MASK_NOCLOSEPROCESS | SEE_MASK_NOASYNC; retain the handle for exit code.
  System::Call '*( &l4, i 0x140, p $HWNDPARENT, w "runas", w "$SYSDIR\msiexec.exe", w r3, p 0, i 1, p 0, p 0, p 0, p 0, i 0, p 0, p 0)p.r0'
  System::Call 'shell32::ShellExecuteExW(p r0)i.r1 ?e'
  Pop $2
  System::Call '*$0(i,i,p,p,p,p,p,i,p,p,p,p,i,p,p.r4)'
  System::Free $0
  ${If} $1 = 0
  ${OrIf} $4 = 0
    Push "未完成管理员授权 (Windows $2)，旧版保持不变。请重新运行安装包并允许卸载旧版。 / Administrator approval was not completed."
    Call CXFail
  ${EndIf}
  StrCpy $CXProcess $4
  GetDlgItem $0 $HWNDPARENT 2
  EnableWindow $0 0
  StrCpy $CXWaitTicks 0
  cx_msi_wait:
    ; EarlyChecks runs on NSIS's worker thread, so its main UI keeps pumping
    ; messages. Never terminate msiexec or interrupt a transaction on timeout.
    System::Call 'kernel32::WaitForSingleObject(p $CXProcess,i 1000)i.r0'
    ${If} $0 = 0
      Goto cx_msi_done
    ${EndIf}
    ${If} $0 != 258
      System::Call 'kernel32::CloseHandle(p $CXProcess)'
      Push "无法跟踪旧版卸载进度。请检查系统安装窗口，完成后再重试；不会安装第二份软件。 / Could not monitor MSI removal."
      Call CXFail
    ${EndIf}
    IntOp $CXWaitTicks $CXWaitTicks + 1
    IntOp $0 $CXWaitTicks % 30
    ${If} $0 = 0
      Push "Windows 正在移除旧版，已等待 $CXWaitTicks 秒；请检查管理员授权或其他安装窗口。后续更新无需此步骤。 / Still waiting for Windows Installer."
      Call CXLog
      Push "详细日志 / Details: $CXMsiLog"
      Call CXLog
    ${EndIf}
    Goto cx_msi_wait
  cx_msi_done:
    System::Call 'kernel32::GetExitCodeProcess(p $CXProcess,*i .r0)i.r1'
    StrCpy $CXExitCode $0
    System::Call 'kernel32::CloseHandle(p $CXProcess)'
    GetDlgItem $0 $HWNDPARENT 2
    EnableWindow $0 1
    Push "MSI exit code: $CXExitCode"
    Call CXLog
    ${If} $1 = 0
      Push "无法读取旧版卸载结果，已停止安装。 / Could not read the MSI result."
      Call CXFail
    ${EndIf}
    ${If} $CXExitCode = 1618
      Push "Windows 正在安装其他软件。请等待它完成，再重新运行 Codex-X 安装包。 / Another Windows installation is running. Wait for it to finish and retry."
      Call CXFail
    ${EndIf}
    ${If} $CXExitCode = 1602
      Push "已取消旧版卸载，未安装新版本。 / Previous-version removal was cancelled."
      Call CXFail
    ${EndIf}
    ${If} $CXExitCode != 0
    ${AndIf} $CXExitCode != 3010
      Push "旧版卸载失败 (Windows $CXExitCode)，未安装新版本。请查看安装日志。 / MSI removal failed; no second installation was created."
      Call CXFail
    ${EndIf}
    ; Verify the exact product really disappeared before touching new files.
    System::Call 'msi::MsiGetProductInfoExW(w "$CXLegacyProduct",p 0,i 4,w "VersionString",w .r0,*i ${NSIS_MAX_STRLEN})i.r1'
    ${If} $1 != 1605
      Push "Windows 仍保留旧版安装记录，已停止安装以避免重复。 / Previous MSI is still registered; migration stopped."
      Call CXFail
    ${EndIf}
    Call CXValidateDestination
    ${If} $CXExitCode = 3010
      Push "旧版卸载完成；Windows 将稍后清理旧目录中的残留文件。新版本安装在独立目录，可继续使用，无需立即重启。 / Legacy cleanup is deferred; the new app can run from its separate directory."
      Call CXLog
    ${EndIf}
    Push "旧版 MSI 已安全移除。 / Previous MSI removed."
    Call CXLog
    Goto cx_migrate_next
FunctionEnd

; Uninstaller signing command
!if "${UNINSTALLERSIGNCOMMAND}" != ""
  !uninstfinalize '${UNINSTALLERSIGNCOMMAND}'
!endif

; Handle install mode, `perUser`, `perMachine` or `both`
!if "${INSTALLMODE}" == "perMachine"
  RequestExecutionLevel admin
!endif

!if "${INSTALLMODE}" == "currentUser"
  RequestExecutionLevel user
!endif

!if "${INSTALLMODE}" == "both"
  !define MULTIUSER_MUI
  !define MULTIUSER_INSTALLMODE_INSTDIR "${PRODUCTNAME}"
  !define MULTIUSER_INSTALLMODE_COMMANDLINE
  !if "${ARCH}" == "x64"
    !define MULTIUSER_USE_PROGRAMFILES64
  !else if "${ARCH}" == "arm64"
    !define MULTIUSER_USE_PROGRAMFILES64
  !endif
  !define MULTIUSER_INSTALLMODE_DEFAULT_REGISTRY_KEY "${UNINSTKEY}"
  !define MULTIUSER_INSTALLMODE_DEFAULT_REGISTRY_VALUENAME "CurrentUser"
  !define MULTIUSER_INSTALLMODEPAGE_SHOWUSERNAME
  !define MULTIUSER_INSTALLMODE_FUNCTION RestorePreviousInstallLocation
  !define MULTIUSER_EXECUTIONLEVEL Highest
  !include MultiUser.nsh
!endif

; Installer icon
!if "${INSTALLERICON}" != ""
  !define MUI_ICON "${INSTALLERICON}"
!endif

; Installer sidebar image
!if "${SIDEBARIMAGE}" != ""
  !define MUI_WELCOMEFINISHPAGE_BITMAP "${SIDEBARIMAGE}"
!endif

; Enable header images for installer and uninstaller pages when either image is configured.
!if "${HEADERIMAGE}" != ""
  !define MUI_HEADERIMAGE
!else if "${UNINSTALLERHEADERIMAGE}" != ""
  !define MUI_HEADERIMAGE
!endif

; Installer header image
!if "${HEADERIMAGE}" != ""
  !define MUI_HEADERIMAGE_BITMAP "${HEADERIMAGE}"
!endif

; Uninstaller header image
!if "${UNINSTALLERHEADERIMAGE}" != ""
  !define MUI_HEADERIMAGE_UNBITMAP "${UNINSTALLERHEADERIMAGE}"
!endif

; Uninstaller icon
!if "${UNINSTALLERICON}" != ""
  !define MUI_UNICON "${UNINSTALLERICON}"
!endif

; Define registry key to store installer language
!define MUI_LANGDLL_REGISTRY_ROOT "HKCU"
!define MUI_LANGDLL_REGISTRY_KEY "${MANUPRODUCTKEY}"
!define MUI_LANGDLL_REGISTRY_VALUENAME "Installer Language"

; Installer pages, must be ordered as they appear
; 1. Welcome Page
!define MUI_PAGE_CUSTOMFUNCTION_PRE SkipIfPassive
!insertmacro MUI_PAGE_WELCOME

; 2. License Page (if defined)
!if "${LICENSE}" != ""
  !define MUI_PAGE_CUSTOMFUNCTION_PRE SkipIfPassive
  !insertmacro MUI_PAGE_LICENSE "${LICENSE}"
!endif

; 3. Install mode (if it is set to `both`)
!if "${INSTALLMODE}" == "both"
  !define MUI_PAGE_CUSTOMFUNCTION_PRE SkipIfPassive
  !insertmacro MULTIUSER_PAGE_INSTALLMODE
!endif

; 4. Custom page to ask user if he wants to reinstall/uninstall
;    only if a previous installation was detected
Var ReinstallPageCheck
Page custom PageReinstall PageLeaveReinstall
Function PageReinstall
  ; Legacy MSI migration is verified and executed in EarlyChecks.
  ${If} $CXLegacyProduct != ""
    Abort
  ${EndIf}

  ; Check if there is an existing installation, if not, abort the reinstall page
  ReadRegStr $R0 SHCTX "${UNINSTKEY}" ""
  ReadRegStr $R1 SHCTX "${UNINSTKEY}" "UninstallString"
  ${IfThen} "$R0$R1" == "" ${|} Abort ${|}

  ; Compare this installar version with the existing installation
  ; and modify the messages presented to the user accordingly
  StrCpy $R4 "$(older)"
  ${If} $WixMode = 1
    ReadRegStr $R0 HKLM "$R6" "DisplayVersion"
  ${Else}
    ReadRegStr $R0 SHCTX "${UNINSTKEY}" "DisplayVersion"
  ${EndIf}
  ${IfThen} $R0 == "" ${|} StrCpy $R4 "$(unknown)" ${|}

  nsis_tauri_utils::SemverCompare "${VERSION}" $R0
  Pop $R0
  ; Reinstalling the same version
  ${If} $R0 = 0
    StrCpy $R1 "$(alreadyInstalledLong)"
    StrCpy $R2 "$(addOrReinstall)"
    StrCpy $R3 "$(uninstallApp)"
    !insertmacro MUI_HEADER_TEXT "$(alreadyInstalled)" "$(chooseMaintenanceOption)"
  ; Upgrading
  ${ElseIf} $R0 = 1
    StrCpy $R1 "$(olderOrUnknownVersionInstalled)"
    StrCpy $R2 "$(uninstallBeforeInstalling)"
    StrCpy $R3 "$(dontUninstall)"
    !insertmacro MUI_HEADER_TEXT "$(alreadyInstalled)" "$(choowHowToInstall)"
  ; Downgrading
  ${ElseIf} $R0 = -1
    StrCpy $R1 "$(newerVersionInstalled)"
    StrCpy $R2 "$(uninstallBeforeInstalling)"
    !if "${ALLOWDOWNGRADES}" == "true"
      StrCpy $R3 "$(dontUninstall)"
    !else
      StrCpy $R3 "$(dontUninstallDowngrade)"
    !endif
    !insertmacro MUI_HEADER_TEXT "$(alreadyInstalled)" "$(choowHowToInstall)"
  ${Else}
    Abort
  ${EndIf}

  ; Skip showing the page if passive
  ;
  ; Note that we don't call this earlier at the begining
  ; of this function because we need to populate some variables
  ; related to current installed version if detected and whether
  ; we are downgrading or not.
  ${If} $PassiveMode = 1
    Call PageLeaveReinstall
  ${Else}
    nsDialogs::Create 1018
    Pop $R4
    ${IfThen} $(^RTL) = 1 ${|} nsDialogs::SetRTL $(^RTL) ${|}

    ${NSD_CreateLabel} 0 0 100% 24u $R1
    Pop $R1

    ${NSD_CreateRadioButton} 30u 50u -30u 8u $R2
    Pop $R2
    ${NSD_OnClick} $R2 PageReinstallUpdateSelection

    ${NSD_CreateRadioButton} 30u 70u -30u 8u $R3
    Pop $R3
    ; Disable this radio button if downgrading and downgrades are disabled
    !if "${ALLOWDOWNGRADES}" == "false"
      ${IfThen} $R0 = -1 ${|} EnableWindow $R3 0 ${|}
    !endif
    ${NSD_OnClick} $R3 PageReinstallUpdateSelection

    ; Check the first radio button if this the first time
    ; we enter this page or if the second button wasn't
    ; selected the last time we were on this page
    ${If} $ReinstallPageCheck <> 2
      SendMessage $R2 ${BM_SETCHECK} ${BST_CHECKED} 0
    ${Else}
      SendMessage $R3 ${BM_SETCHECK} ${BST_CHECKED} 0
    ${EndIf}

    ${NSD_SetFocus} $R2
    nsDialogs::Show
  ${EndIf}
FunctionEnd
Function PageReinstallUpdateSelection
  ${NSD_GetState} $R2 $R1
  ${If} $R1 == ${BST_CHECKED}
    StrCpy $ReinstallPageCheck 1
  ${Else}
    StrCpy $ReinstallPageCheck 2
  ${EndIf}
FunctionEnd
Function PageLeaveReinstall
  ${NSD_GetState} $R2 $R1

  ; In update mode, always proceeds without uninstalling
  ${If} $UpdateMode = 1
    Goto reinst_done
  ${EndIf}

  ; $R0 holds whether same(0)/upgrading(1)/downgrading(-1) version
  ; $R1 holds the radio buttons state:
  ;   1 => first choice was selected
  ;   0 => second choice was selected
  ${If} $R0 = 0 ; Same version, proceed
    ${If} $R1 = 1              ; User chose to add/reinstall
      Goto reinst_done
    ${Else}                    ; User chose to uninstall
      Goto reinst_uninstall
    ${EndIf}
  ${ElseIf} $R0 = 1 ; Upgrading
    ${If} $R1 = 1              ; User chose to uninstall
      Goto reinst_uninstall
    ${Else}
      Goto reinst_done         ; User chose NOT to uninstall
    ${EndIf}
  ${ElseIf} $R0 = -1 ; Downgrading
    ${If} $R1 = 1              ; User chose to uninstall
      Goto reinst_uninstall
    ${Else}
      Goto reinst_done         ; User chose NOT to uninstall
    ${EndIf}
  ${EndIf}

  reinst_uninstall:
    HideWindow
    ClearErrors

    ReadRegStr $4 SHCTX "${MANUPRODUCTKEY}" ""
    ReadRegStr $R1 SHCTX "${UNINSTKEY}" "UninstallString"
    ${IfThen} $UpdateMode = 1 ${|} StrCpy $R1 "$R1 /UPDATE" ${|}
    ${IfThen} $PassiveMode = 1 ${|} StrCpy $R1 "$R1 /P" ${|}
    StrCpy $R1 "$R1 _?=$4"
    ExecWait '$R1' $0

    BringToFront

    ${IfThen} ${Errors} ${|} StrCpy $0 2 ${|} ; ExecWait failed, set fake exit code

    ${If} $0 <> 0
    ${OrIf} ${FileExists} "$INSTDIR\${MAINBINARYNAME}.exe"
      ; User cancelled wix uninstaller? return to select un/reinstall page
      ${If} $WixMode = 1
      ${AndIf} $0 = 1602
        Abort
      ${EndIf}

      ; User cancelled NSIS uninstaller? return to select un/reinstall page
      ${If} $0 = 1
        Abort
      ${EndIf}

      ; Other erros? show generic error message and return to select un/reinstall page
      MessageBox MB_ICONEXCLAMATION "$(unableToUninstall)"
      Abort
    ${EndIf}
  reinst_done:
FunctionEnd

; 5. Choose install directory page
!define MUI_PAGE_CUSTOMFUNCTION_PRE SkipIfPassive
!insertmacro MUI_PAGE_DIRECTORY

; 6. Start menu shortcut page
Var AppStartMenuFolder
!if "${STARTMENUFOLDER}" != ""
  !define MUI_PAGE_CUSTOMFUNCTION_PRE SkipIfPassive
  !define MUI_STARTMENUPAGE_DEFAULTFOLDER "${STARTMENUFOLDER}"
!else
  !define MUI_PAGE_CUSTOMFUNCTION_PRE Skip
!endif
!insertmacro MUI_PAGE_STARTMENU Application $AppStartMenuFolder

; 7. Installation page
!insertmacro MUI_PAGE_INSTFILES

; 8. Finish page
;
; Don't auto jump to finish page after installation page,
; because the installation page has useful info that can be used debug any issues with the installer.
!define MUI_FINISHPAGE_NOAUTOCLOSE
; Use show readme button in the finish page as a button create a desktop shortcut
!define MUI_FINISHPAGE_SHOWREADME
!define MUI_FINISHPAGE_SHOWREADME_TEXT "$(createDesktop)"
!define MUI_FINISHPAGE_SHOWREADME_FUNCTION CreateOrUpdateDesktopShortcut
; Show run app after installation.
!define MUI_FINISHPAGE_RUN
!define MUI_FINISHPAGE_RUN_FUNCTION RunMainBinary
!define MUI_PAGE_CUSTOMFUNCTION_PRE SkipIfPassive
!insertmacro MUI_PAGE_FINISH

Function RunMainBinary
  nsis_tauri_utils::RunAsUser "$INSTDIR\${MAINBINARYNAME}.exe" ""
FunctionEnd

; Uninstaller Pages
; 1. Confirm uninstall page
Var DeleteAppDataCheckbox
Var DeleteAppDataCheckboxState
!define /ifndef WS_EX_LAYOUTRTL         0x00400000
!define MUI_PAGE_CUSTOMFUNCTION_SHOW un.ConfirmShow
Function un.ConfirmShow ; Add add a `Delete app data` check box
  ; $1 inner dialog HWND
  ; $2 window DPI
  ; $3 style
  ; $4 x
  ; $5 y
  ; $6 width
  ; $7 height
  FindWindow $1 "#32770" "" $HWNDPARENT ; Find inner dialog
  System::Call "user32::GetDpiForWindow(p r1) i .r2"
  ${If} $(^RTL) = 1
    StrCpy $3 "${__NSD_CheckBox_EXSTYLE} | ${WS_EX_LAYOUTRTL}"
    IntOp $4 50 * $2
  ${Else}
    StrCpy $3 "${__NSD_CheckBox_EXSTYLE}"
    IntOp $4 0 * $2
  ${EndIf}
  IntOp $5 100 * $2
  IntOp $6 400 * $2
  IntOp $7 25 * $2
  IntOp $4 $4 / 96
  IntOp $5 $5 / 96
  IntOp $6 $6 / 96
  IntOp $7 $7 / 96
  System::Call 'user32::CreateWindowEx(i r3, w "${__NSD_CheckBox_CLASS}", w "$(deleteAppData)", i ${__NSD_CheckBox_STYLE}, i r4, i r5, i r6, i r7, p r1, i0, i0, i0) i .s'
  Pop $DeleteAppDataCheckbox
  SendMessage $HWNDPARENT ${WM_GETFONT} 0 0 $1
  SendMessage $DeleteAppDataCheckbox ${WM_SETFONT} $1 1
FunctionEnd
!define MUI_PAGE_CUSTOMFUNCTION_LEAVE un.ConfirmLeave
Function un.ConfirmLeave
  SendMessage $DeleteAppDataCheckbox ${BM_GETCHECK} 0 0 $DeleteAppDataCheckboxState
FunctionEnd
!define MUI_PAGE_CUSTOMFUNCTION_PRE un.SkipIfPassive
!insertmacro MUI_UNPAGE_CONFIRM

; 2. Uninstalling Page
!insertmacro MUI_UNPAGE_INSTFILES

;Languages
{{#each languages}}
!insertmacro MUI_LANGUAGE "{{this}}"
{{/each}}
!insertmacro MUI_RESERVEFILE_LANGDLL
{{#each language_files}}
  !include "{{this}}"
{{/each}}

Function .onInit
  ${GetOptions} $CMDLINE "/P" $PassiveMode
  ${IfNot} ${Errors}
    StrCpy $PassiveMode 1
  ${EndIf}

  ${GetOptions} $CMDLINE "/NS" $NoShortcutMode
  ${IfNot} ${Errors}
    StrCpy $NoShortcutMode 1
  ${EndIf}

  ${GetOptions} $CMDLINE "/UPDATE" $UpdateMode
  ${IfNot} ${Errors}
    StrCpy $UpdateMode 1
  ${EndIf}

  !if "${DISPLAYLANGUAGESELECTOR}" == "true"
    !insertmacro MUI_LANGDLL_DISPLAY
  !endif

  !insertmacro SetContext
  Call CXInitialize

  ${If} $INSTDIR == "${PLACEHOLDER_INSTALL_DIR}"
    ; Set default install location
    !if "${INSTALLMODE}" == "perMachine"
      ${If} ${RunningX64}
        !if "${ARCH}" == "x64"
          StrCpy $INSTDIR "$PROGRAMFILES64\${PRODUCTNAME}"
        !else if "${ARCH}" == "arm64"
          StrCpy $INSTDIR "$PROGRAMFILES64\${PRODUCTNAME}"
        !else
          StrCpy $INSTDIR "$PROGRAMFILES\${PRODUCTNAME}"
        !endif
      ${Else}
        StrCpy $INSTDIR "$PROGRAMFILES\${PRODUCTNAME}"
      ${EndIf}
    !else if "${INSTALLMODE}" == "currentUser"
      StrCpy $INSTDIR "$LOCALAPPDATA\${PRODUCTNAME}"
    !endif

    Call RestorePreviousInstallLocation
  ${EndIf}


  !if "${INSTALLMODE}" == "both"
    !insertmacro MULTIUSER_INIT
  !endif
FunctionEnd


Section EarlyChecks
  Call CXWaitForOldApp
  Call CXWaitForRunningApp
  Call CXValidateDestination
  Call CXMigrateLegacyMsi
  ; Abort silent installer if downgrades is disabled
  !if "${ALLOWDOWNGRADES}" == "false"
  ${If} ${Silent}
    ; If downgrading
    ${If} $R0 = -1
      System::Call 'kernel32::AttachConsole(i -1)i.r0'
      ${If} $0 <> 0
        System::Call 'kernel32::GetStdHandle(i -11)i.r0'
        System::call 'kernel32::SetConsoleTextAttribute(i r0, i 0x0004)' ; set red color
        FileWrite $0 "$(silentDowngrades)"
      ${EndIf}
      Abort
    ${EndIf}
  ${EndIf}
  !endif

SectionEnd

Section WebView2
  ; Check if Webview2 is already installed and skip this section
  ${If} ${RunningX64}
    ReadRegStr $4 HKLM "SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\${WEBVIEW2APPGUID}" "pv"
  ${Else}
    ReadRegStr $4 HKLM "SOFTWARE\Microsoft\EdgeUpdate\Clients\${WEBVIEW2APPGUID}" "pv"
  ${EndIf}
  ${If} $4 == ""
    ReadRegStr $4 HKCU "SOFTWARE\Microsoft\EdgeUpdate\Clients\${WEBVIEW2APPGUID}" "pv"
  ${EndIf}

  ${If} $4 == ""
    ; Webview2 installation
    ;
    ; Skip if updating
    ${If} $UpdateMode <> 1
      !if "${INSTALLWEBVIEW2MODE}" == "downloadBootstrapper"
        Delete "$TEMP\MicrosoftEdgeWebview2Setup.exe"
        DetailPrint "$(webview2Downloading)"
        NSISdl::download "https://go.microsoft.com/fwlink/p/?LinkId=2124703" "$TEMP\MicrosoftEdgeWebview2Setup.exe"
        Pop $0
        ${If} $0 == "success"
          DetailPrint "$(webview2DownloadSuccess)"
        ${Else}
          DetailPrint "$(webview2DownloadError)"
          Abort "$(webview2AbortError)"
        ${EndIf}
        StrCpy $6 "$TEMP\MicrosoftEdgeWebview2Setup.exe"
        Goto install_webview2
      !endif

      !if "${INSTALLWEBVIEW2MODE}" == "embedBootstrapper"
        Delete "$TEMP\MicrosoftEdgeWebview2Setup.exe"
        File "/oname=$TEMP\MicrosoftEdgeWebview2Setup.exe" "${WEBVIEW2BOOTSTRAPPERPATH}"
        DetailPrint "$(installingWebview2)"
        StrCpy $6 "$TEMP\MicrosoftEdgeWebview2Setup.exe"
        Goto install_webview2
      !endif

      !if "${INSTALLWEBVIEW2MODE}" == "offlineInstaller"
        Delete "$TEMP\MicrosoftEdgeWebView2RuntimeInstaller.exe"
        File "/oname=$TEMP\MicrosoftEdgeWebView2RuntimeInstaller.exe" "${WEBVIEW2INSTALLERPATH}"
        DetailPrint "$(installingWebview2)"
        StrCpy $6 "$TEMP\MicrosoftEdgeWebView2RuntimeInstaller.exe"
        Goto install_webview2
      !endif

      Goto webview2_done

      install_webview2:
        DetailPrint "$(installingWebview2)"
        ; $6 holds the path to the webview2 installer
        ExecWait "$6 ${WEBVIEW2INSTALLERARGS} /install" $1
        ${If} $1 = 0
          DetailPrint "$(webview2InstallSuccess)"
        ${Else}
          DetailPrint "$(webview2InstallError)"
          Abort "$(webview2AbortError)"
        ${EndIf}
      webview2_done:
    ${EndIf}
  ${Else}
    !if "${MINIMUMWEBVIEW2VERSION}" != ""
      ${VersionCompare} "${MINIMUMWEBVIEW2VERSION}" "$4" $R0
      ${If} $R0 = 1
        update_webview:
          DetailPrint "$(installingWebview2)"
          ${If} ${RunningX64}
            ReadRegStr $R1 HKLM "SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate" "path"
          ${Else}
            ReadRegStr $R1 HKLM "SOFTWARE\Microsoft\EdgeUpdate" "path"
          ${EndIf}
          ${If} $R1 == ""
            ReadRegStr $R1 HKCU "SOFTWARE\Microsoft\EdgeUpdate" "path"
          ${EndIf}
          ${If} $R1 != ""
            ; Chromium updater docs: https://source.chromium.org/chromium/chromium/src/+/main:docs/updater/user_manual.md
            ; Modified from "HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft EdgeWebView\ModifyPath"
            ExecWait `"$R1" /install appguid=${WEBVIEW2APPGUID}&needsadmin=true` $1
            ${If} $1 = 0
              DetailPrint "$(webview2InstallSuccess)"
            ${Else}
              MessageBox MB_ICONEXCLAMATION|MB_ABORTRETRYIGNORE "$(webview2InstallError)" IDIGNORE ignore IDRETRY update_webview
              Quit
              ignore:
            ${EndIf}
          ${EndIf}
      ${EndIf}
    !endif
  ${EndIf}
SectionEnd

Section Install
  Call CXValidateDestination
  SetOutPath $INSTDIR

  !ifmacrodef NSIS_HOOK_PREINSTALL
    !insertmacro NSIS_HOOK_PREINSTALL
  !endif

  Call CXWaitForRunningApp

  ; Copy main executable
  File "${MAINBINARYSRCPATH}"

  ; Copy resources
  {{#each resources_dirs}}
    CreateDirectory "$INSTDIR\\{{this}}"
  {{/each}}
  {{#each resources}}
    File /a "/oname={{this.[1]}}" "{{no-escape @key}}"
  {{/each}}

  ; Copy external binaries
  {{#each binaries}}
    File /a "/oname={{this}}" "{{no-escape @key}}"
  {{/each}}

  ; Create file associations
  {{#each file_associations as |association| ~}}
    {{#each association.ext as |ext| ~}}
       !insertmacro APP_ASSOCIATE "{{ext}}" "{{or association.name ext}}" "{{association-description association.description ext}}" "$INSTDIR\${MAINBINARYNAME}.exe,0" "Open with ${PRODUCTNAME}" "$INSTDIR\${MAINBINARYNAME}.exe $\"%1$\""
    {{/each}}
  {{/each}}

  ; Register deep links
  {{#each deep_link_protocols as |protocol| ~}}
    WriteRegStr SHCTX "Software\Classes\\{{protocol}}" "URL Protocol" ""
    WriteRegStr SHCTX "Software\Classes\\{{protocol}}" "" "URL:${BUNDLEID} protocol"
    WriteRegStr SHCTX "Software\Classes\\{{protocol}}\DefaultIcon" "" "$\"$INSTDIR\${MAINBINARYNAME}.exe$\",0"
    WriteRegStr SHCTX "Software\Classes\\{{protocol}}\shell\open\command" "" "$\"$INSTDIR\${MAINBINARYNAME}.exe$\" $\"%1$\""
  {{/each}}

  ; Create uninstaller
  WriteUninstaller "$INSTDIR\uninstall.exe"

  ; Save $INSTDIR in registry for future installations
  WriteRegStr SHCTX "${MANUPRODUCTKEY}" "" $INSTDIR

  !if "${INSTALLMODE}" == "both"
    ; Save install mode to be selected by default for the next installation such as updating
    ; or when uninstalling
    WriteRegStr SHCTX "${UNINSTKEY}" $MultiUser.InstallMode 1
  !endif

  ; Remove old main binary if it doesn't match new main binary name
  ReadRegStr $OldMainBinaryName SHCTX "${UNINSTKEY}" "MainBinaryName"
  ${If} $OldMainBinaryName != ""
  ${AndIf} $OldMainBinaryName != "${MAINBINARYNAME}.exe"
    Delete "$INSTDIR\$OldMainBinaryName"
  ${EndIf}

  ; Save current MAINBINARYNAME for future updates
  WriteRegStr SHCTX "${UNINSTKEY}" "MainBinaryName" "${MAINBINARYNAME}.exe"

  ; Registry information for add/remove programs
  WriteRegStr SHCTX "${UNINSTKEY}" "DisplayName" "${PRODUCTNAME}"
  WriteRegStr SHCTX "${UNINSTKEY}" "DisplayIcon" "$\"$INSTDIR\${MAINBINARYNAME}.exe$\""
  WriteRegStr SHCTX "${UNINSTKEY}" "DisplayVersion" "${VERSION}"
  WriteRegStr SHCTX "${UNINSTKEY}" "Publisher" "${MANUFACTURER}"
  WriteRegStr SHCTX "${UNINSTKEY}" "InstallLocation" "$\"$INSTDIR$\""
  WriteRegStr SHCTX "${UNINSTKEY}" "UninstallString" "$\"$INSTDIR\uninstall.exe$\""
  WriteRegDWORD SHCTX "${UNINSTKEY}" "NoModify" "1"
  WriteRegDWORD SHCTX "${UNINSTKEY}" "NoRepair" "1"

  ${GetSize} "$INSTDIR" "/M=uninstall.exe /S=0K /G=0" $0 $1 $2
  IntOp $0 $0 + ${ESTIMATEDSIZE}
  IntFmt $0 "0x%08X" $0
  WriteRegDWORD SHCTX "${UNINSTKEY}" "EstimatedSize" "$0"

  !if "${HOMEPAGE}" != ""
    WriteRegStr SHCTX "${UNINSTKEY}" "URLInfoAbout" "${HOMEPAGE}"
    WriteRegStr SHCTX "${UNINSTKEY}" "URLUpdateInfo" "${HOMEPAGE}"
    WriteRegStr SHCTX "${UNINSTKEY}" "HelpLink" "${HOMEPAGE}"
  !endif

  ; Create start menu shortcut
  !insertmacro MUI_STARTMENU_WRITE_BEGIN Application
    Call CreateOrUpdateStartMenuShortcut
  !insertmacro MUI_STARTMENU_WRITE_END

  ; Create desktop shortcut for silent and passive installers
  ; because finish page will be skipped
  ${If} $PassiveMode = 1
  ${OrIf} ${Silent}
    Call CreateOrUpdateDesktopShortcut
  ${EndIf}

  !ifmacrodef NSIS_HOOK_POSTINSTALL
    !insertmacro NSIS_HOOK_POSTINSTALL
  !endif

  ; Auto close this page for passive mode
  ${If} $PassiveMode = 1
    SetAutoClose true
  ${EndIf}
SectionEnd

Function .onInstSuccess
  Push "Installation completed: $INSTDIR"
  Call CXLog
  ; Check for `/R` flag only in silent and passive installers because
  ; GUI installer has a toggle for the user to (re)start the app
  ${If} $PassiveMode = 1
  ${OrIf} ${Silent}
    ${GetOptions} $CMDLINE "/R" $R0
    ${IfNot} ${Errors}
      ${GetOptions} $CMDLINE "/ARGS" $R0
      nsis_tauri_utils::RunAsUser "$INSTDIR\${MAINBINARYNAME}.exe" "$R0"
    ${EndIf}
  ${EndIf}
FunctionEnd

Function un.onInit
  !insertmacro SetContext

  !if "${INSTALLMODE}" == "both"
    !insertmacro MULTIUSER_UNINIT
  !endif

  !insertmacro MUI_UNGETLANGUAGE

  ${GetOptions} $CMDLINE "/P" $PassiveMode
  ${IfNot} ${Errors}
    StrCpy $PassiveMode 1
  ${EndIf}

  ${GetOptions} $CMDLINE "/UPDATE" $UpdateMode
  ${IfNot} ${Errors}
    StrCpy $UpdateMode 1
  ${EndIf}
FunctionEnd

Section Uninstall

  !ifmacrodef NSIS_HOOK_PREUNINSTALL
    !insertmacro NSIS_HOOK_PREUNINSTALL
  !endif

  !insertmacro CheckIfAppIsRunning "${MAINBINARYNAME}.exe" "${PRODUCTNAME}"

  ; Delete the app directory and its content from disk
  ; Copy main executable
  Delete "$INSTDIR\${MAINBINARYNAME}.exe"

  ; Delete resources
  {{#each resources}}
    Delete "$INSTDIR\\{{this.[1]}}"
  {{/each}}

  ; Delete external binaries
  {{#each binaries}}
    Delete "$INSTDIR\\{{this}}"
  {{/each}}

  ; Delete app associations
  {{#each file_associations as |association| ~}}
    {{#each association.ext as |ext| ~}}
      !insertmacro APP_UNASSOCIATE "{{ext}}" "{{or association.name ext}}"
    {{/each}}
  {{/each}}

  ; Delete deep links
  {{#each deep_link_protocols as |protocol| ~}}
    ReadRegStr $R7 SHCTX "Software\Classes\\{{protocol}}\shell\open\command" ""
    ${If} $R7 == "$\"$INSTDIR\${MAINBINARYNAME}.exe$\" $\"%1$\""
      DeleteRegKey SHCTX "Software\Classes\\{{protocol}}"
    ${EndIf}
  {{/each}}


  ; Delete uninstaller
  Delete "$INSTDIR\uninstall.exe"

  {{#each resources_ancestors}}
  RMDir /REBOOTOK "$INSTDIR\\{{this}}"
  {{/each}}
  RMDir "$INSTDIR"

  ; Remove shortcuts if not updating
  ${If} $UpdateMode <> 1
    !insertmacro DeleteAppUserModelId

    ; Remove start menu shortcut
    !insertmacro MUI_STARTMENU_GETFOLDER Application $AppStartMenuFolder
    !insertmacro IsShortcutTarget "$SMPROGRAMS\$AppStartMenuFolder\${PRODUCTNAME}.lnk" "$INSTDIR\${MAINBINARYNAME}.exe"
    Pop $0
    ${If} $0 = 1
      !insertmacro UnpinShortcut "$SMPROGRAMS\$AppStartMenuFolder\${PRODUCTNAME}.lnk"
      Delete "$SMPROGRAMS\$AppStartMenuFolder\${PRODUCTNAME}.lnk"
      RMDir "$SMPROGRAMS\$AppStartMenuFolder"
    ${EndIf}
    !insertmacro IsShortcutTarget "$SMPROGRAMS\${PRODUCTNAME}.lnk" "$INSTDIR\${MAINBINARYNAME}.exe"
    Pop $0
    ${If} $0 = 1
      !insertmacro UnpinShortcut "$SMPROGRAMS\${PRODUCTNAME}.lnk"
      Delete "$SMPROGRAMS\${PRODUCTNAME}.lnk"
    ${EndIf}

    ; Remove desktop shortcuts
    !insertmacro IsShortcutTarget "$DESKTOP\${PRODUCTNAME}.lnk" "$INSTDIR\${MAINBINARYNAME}.exe"
    Pop $0
    ${If} $0 = 1
      !insertmacro UnpinShortcut "$DESKTOP\${PRODUCTNAME}.lnk"
      Delete "$DESKTOP\${PRODUCTNAME}.lnk"
    ${EndIf}
  ${EndIf}

  ; Remove registry information for add/remove programs
  !if "${INSTALLMODE}" == "both"
    DeleteRegKey SHCTX "${UNINSTKEY}"
  !else if "${INSTALLMODE}" == "perMachine"
    DeleteRegKey HKLM "${UNINSTKEY}"
  !else
    DeleteRegKey HKCU "${UNINSTKEY}"
  !endif

  ; Removes the Autostart entry for ${PRODUCTNAME} from the HKCU Run key if it exists.
  ; This ensures the program does not launch automatically after uninstallation if it exists.
  ; If it doesn't exist, it does nothing.
  ; We do this when not updating (to preserve the registry value on updates)
  ${If} $UpdateMode <> 1
    DeleteRegValue HKCU "Software\Microsoft\Windows\CurrentVersion\Run" "${PRODUCTNAME}"
  ${EndIf}

  ; Delete app data if the checkbox is selected
  ; and if not updating
  ${If} $DeleteAppDataCheckboxState = 1
  ${AndIf} $UpdateMode <> 1
    ; Clear the install location $INSTDIR from registry
    DeleteRegKey SHCTX "${MANUPRODUCTKEY}"
    DeleteRegKey /ifempty SHCTX "${MANUKEY}"

    ; Clear the install language from registry
    DeleteRegValue HKCU "${MANUPRODUCTKEY}" "Installer Language"
    DeleteRegKey /ifempty HKCU "${MANUPRODUCTKEY}"
    DeleteRegKey /ifempty HKCU "${MANUKEY}"

    SetShellVarContext current
    RmDir /r "$APPDATA\${BUNDLEID}"
    RmDir /r "$LOCALAPPDATA\${BUNDLEID}"
  ${EndIf}

  !ifmacrodef NSIS_HOOK_POSTUNINSTALL
    !insertmacro NSIS_HOOK_POSTUNINSTALL
  !endif

  ; Auto close if passive mode or updating
  ${If} $PassiveMode = 1
  ${OrIf} $UpdateMode = 1
    SetAutoClose true
  ${EndIf}
SectionEnd

Function RestorePreviousInstallLocation
  ; Old MSI wrote this same manufacturer key in HKCU with Program Files.
  ; Only inherit it when a current-user NSIS registration also exists.
  ReadRegStr $4 SHCTX "${UNINSTKEY}" "UninstallString"
  ${If} $4 == ""
    Return
  ${EndIf}
  ReadRegStr $4 SHCTX "${MANUPRODUCTKEY}" ""
  StrCmp $4 "" +2 0
    StrCpy $INSTDIR $4
FunctionEnd

Function Skip
  Abort
FunctionEnd

Function SkipIfPassive
  ${IfThen} $PassiveMode = 1  ${|} Abort ${|}
FunctionEnd
Function un.SkipIfPassive
  ${IfThen} $PassiveMode = 1  ${|} Abort ${|}
FunctionEnd

Function CreateOrUpdateStartMenuShortcut
  ; We used to use product name as MAINBINARYNAME
  ; migrate old shortcuts to target the new MAINBINARYNAME
  StrCpy $R0 0

  !insertmacro IsShortcutTarget "$SMPROGRAMS\$AppStartMenuFolder\${PRODUCTNAME}.lnk" "$INSTDIR\$OldMainBinaryName"
  Pop $0
  ${If} $0 = 1
    !insertmacro SetShortcutTarget "$SMPROGRAMS\$AppStartMenuFolder\${PRODUCTNAME}.lnk" "$INSTDIR\${MAINBINARYNAME}.exe"
    StrCpy $R0 1
  ${EndIf}

  !insertmacro IsShortcutTarget "$SMPROGRAMS\${PRODUCTNAME}.lnk" "$INSTDIR\$OldMainBinaryName"
  Pop $0
  ${If} $0 = 1
    !insertmacro SetShortcutTarget "$SMPROGRAMS\${PRODUCTNAME}.lnk" "$INSTDIR\${MAINBINARYNAME}.exe"
    StrCpy $R0 1
  ${EndIf}

  ${If} $R0 = 1
    Return
  ${EndIf}

  ; Skip creating shortcut if in update mode or no shortcut mode
  ; but always create if migrating from wix
  ${If} $WixMode = 0
    ${If} $UpdateMode = 1
    ${OrIf} $NoShortcutMode = 1
      Return
    ${EndIf}
  ${EndIf}

  !if "${STARTMENUFOLDER}" != ""
    CreateDirectory "$SMPROGRAMS\$AppStartMenuFolder"
    CreateShortcut "$SMPROGRAMS\$AppStartMenuFolder\${PRODUCTNAME}.lnk" "$INSTDIR\${MAINBINARYNAME}.exe"
    !insertmacro SetLnkAppUserModelId "$SMPROGRAMS\$AppStartMenuFolder\${PRODUCTNAME}.lnk"
  !else
    CreateShortcut "$SMPROGRAMS\${PRODUCTNAME}.lnk" "$INSTDIR\${MAINBINARYNAME}.exe"
    !insertmacro SetLnkAppUserModelId "$SMPROGRAMS\${PRODUCTNAME}.lnk"
  !endif
FunctionEnd

Function CreateOrUpdateDesktopShortcut
  ; We used to use product name as MAINBINARYNAME
  ; migrate old shortcuts to target the new MAINBINARYNAME
  !insertmacro IsShortcutTarget "$DESKTOP\${PRODUCTNAME}.lnk" "$INSTDIR\$OldMainBinaryName"
  Pop $0
  ${If} $0 = 1
    !insertmacro SetShortcutTarget "$DESKTOP\${PRODUCTNAME}.lnk" "$INSTDIR\${MAINBINARYNAME}.exe"
    Return
  ${EndIf}

  ; Skip creating shortcut if in update mode or no shortcut mode
  ; but always create if migrating from wix
  ${If} $WixMode = 0
    ${If} $UpdateMode = 1
    ${OrIf} $NoShortcutMode = 1
      Return
    ${EndIf}
  ${EndIf}

  CreateShortcut "$DESKTOP\${PRODUCTNAME}.lnk" "$INSTDIR\${MAINBINARYNAME}.exe"
  !insertmacro SetLnkAppUserModelId "$DESKTOP\${PRODUCTNAME}.lnk"
FunctionEnd
