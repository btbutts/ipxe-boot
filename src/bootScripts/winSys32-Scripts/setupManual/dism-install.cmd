@echo off
setlocal enabledelayedexpansion

REM ============================================================
REM  dism-install.cmd  (setupManual — DISM installation path)
REM  Partitions the iSCSI target LUN and applies Windows 11 via DISM.
REM  Called by winpeshl.ini AFTER presetup.cmd completes —
REM  msiscsi is already running and the win-lvrgamingpc LUN is
REM  already connected when this script starts.
REM
REM  install.wim is sourced from a second iSCSI LUN
REM  (windows-installation) connected in Step 0 below.
REM  Both LUN credentials are loaded from iscsi-creds.cmd.
REM ============================================================

REM ── Configuration ───────────────────────────────────────────
set ISCSI_DISK_NUM=1
set WIN_IMG_INDEX=1
set WIN_DRIVE=W
set EFI_DRIVE=V

REM Install source LUN disk number.
REM Typical layout: 0=WinPE (X:), 1=win-lvrgamingpc (sanhook), 2=install source.
REM Verify from Ctrl+F10 debug shell with: diskpart > list disk
set INSTALL_SRC_DISK_NUM=2
set INSTALL_DRIVE=I
REM ─────────────────────────────────────────────────────────────

set _D=%date%
set _D=%_D: =0%
set _D=%_D:/=-%
set DISMLOG=%SYSTEMDRIVE%\dism-install_%_D%.log
echo [dism] %date% %time% - Starting >> %DISMLOG%

echo ========================================
echo   Windows 11 DISM Installer
echo ========================================
echo.

REM ── Step 0: Connect install source LUN ──────────────────────
echo [0/3] Connecting Windows installation source LUN...
echo [dism] Step 0: Connecting install source LUN... >> %DISMLOG%

REM This script runs in a fresh process (separate cmd.exe from presetup.cmd),
REM so environment variables from iscsi-connect.cmd are not inherited.
REM Load credentials directly — sets both ISCSI_* and INSTALL_* variables.
if not exist %SYSTEMDRIVE%\Windows\System32\iscsi-creds.cmd (
    echo   ERROR: iscsi-creds.cmd not found. Cannot continue.
    echo [dism] ERROR: iscsi-creds.cmd not found. >> %DISMLOG%
    exit /b 1
)
call %SYSTEMDRIVE%\Windows\System32\iscsi-creds.cmd
echo [dism] Credentials loaded. >> %DISMLOG%

REM Fall back to primary LUN portal/port if install source LUN overrides are not set.
if "%INSTALL_PORTAL%"=="" set INSTALL_PORTAL=%ISCSI_PORTAL%
if "%INSTALL_PORT%"=="" set INSTALL_PORT=%ISCSI_PORT%
echo [dism] Install source portal: %INSTALL_PORTAL%:%INSTALL_PORT% >> %DISMLOG%

REM Set Mutual CHAP secret for the install source LUN.
REM The primary LUN session is already established — CHAPSecret only
REM affects the login handshake for new sessions.
iscsicli CHAPSecret %INSTALL_CHAP_SECRET% >> %DISMLOG% 2>&1
echo [dism] CHAPSecret ^(install^) exit code: %errorlevel% >> %DISMLOG%

iscsicli AddTargetPortal %INSTALL_PORTAL% %INSTALL_PORT% >> %DISMLOG% 2>&1
echo [dism] AddTargetPortal ^(install^) exit code: %errorlevel% >> %DISMLOG%
echo [dism] ListTargets after AddTargetPortal: >> %DISMLOG%
iscsicli ListTargets T >> %DISMLOG% 2>&1
echo   Attempting login: %INSTALL_IQN%
echo   Portal: %INSTALL_PORTAL%:%INSTALL_PORT%

REM LoginFlags=2 (ISCSI_LOGIN_FLAG_MULTIPATH_ENABLED) required because the
REM windows-installation target has "Allow clustered access" enabled on the QNAP.
iscsicli LoginTarget %INSTALL_IQN% F %INSTALL_PORTAL% %INSTALL_PORT% "*" "*" "*" 2 0 0 0 0 0 %INSTALL_USER% "%INSTALL_PASS%" 2 "*" 0 >> %DISMLOG% 2>&1
set /a install_login_err=%errorlevel%
echo [dism] LoginTarget ^(install^) exit code: !install_login_err! >> %DISMLOG%
if !install_login_err! neq 0 (
    echo   WARNING: Install source login returned code !install_login_err!.
    echo   Check %DISMLOG% for iscsicli output. Verify INSTALL_* vars in iscsi-creds.cmd.
    echo [dism] WARNING: Install source login code !install_login_err! >> %DISMLOG%
)

REM Wait for install source disk to enumerate in diskpart.
REM Uses rescan + select disk; success string = "is now the selected disk".
<nul set /p "=  Waiting for install source disk (disk %INSTALL_SRC_DISK_NUM%)"
set /a disk_wait=0
:WaitInstallDisk
echo rescan                              > %SYSTEMDRIVE%\__inst_chk.txt
echo select disk %INSTALL_SRC_DISK_NUM% >> %SYSTEMDRIVE%\__inst_chk.txt
echo exit                               >> %SYSTEMDRIVE%\__inst_chk.txt
diskpart /s %SYSTEMDRIVE%\__inst_chk.txt > %SYSTEMDRIVE%\__inst_out.txt 2>&1
findstr /i "is now the selected disk" %SYSTEMDRIVE%\__inst_out.txt >nul 2>&1
if not errorlevel 1 goto InstallDiskFound
set /a disk_wait+=1
if !disk_wait! geq 15 goto InstallDiskTimeout
<nul set /p "= ."
echo [dism] Install disk attempt !disk_wait!/15 >> %DISMLOG%
ping -n 3 127.0.0.1 >nul 2>&1
goto WaitInstallDisk

:InstallDiskTimeout
echo.
echo   ERROR: Install source disk ^(disk %INSTALL_SRC_DISK_NUM%^) not found after 15 attempts.
echo [dism] ERROR: Install source disk %INSTALL_SRC_DISK_NUM% not found after 15 attempts. >> %DISMLOG%
del %SYSTEMDRIVE%\__inst_chk.txt >nul 2>&1
del %SYSTEMDRIVE%\__inst_out.txt >nul 2>&1
exit /b 1

:InstallDiskFound
echo.
del %SYSTEMDRIVE%\__inst_chk.txt >nul 2>&1
del %SYSTEMDRIVE%\__inst_out.txt >nul 2>&1
echo   Install source disk found after !disk_wait! attempt^(s^).
echo [dism] Install source disk found after !disk_wait! attempt^(s^). >> %DISMLOG%

REM Assign drive letter to the install source NTFS partition ^(partition 3^).
REM Partition layout on windows-installation LUN: 1=MSR, 2=EFI ^(300MB^), 3=NTFS ^(ISO content^).
echo   Assigning drive %INSTALL_DRIVE%: to install source partition...
echo select disk %INSTALL_SRC_DISK_NUM% > %SYSTEMDRIVE%\__inst_part.txt
echo select partition 3                 >> %SYSTEMDRIVE%\__inst_part.txt
echo assign letter=%INSTALL_DRIVE%      >> %SYSTEMDRIVE%\__inst_part.txt
echo exit                               >> %SYSTEMDRIVE%\__inst_part.txt
diskpart /s %SYSTEMDRIVE%\__inst_part.txt >> %DISMLOG% 2>&1
del %SYSTEMDRIVE%\__inst_part.txt >nul 2>&1
echo   Install source mounted as %INSTALL_DRIVE%:
echo [dism] Install source disk %INSTALL_SRC_DISK_NUM% partition 3 assigned %INSTALL_DRIVE%: >> %DISMLOG%
echo.

REM ── Step 1: Partition iSCSI target LUN ^(GPT/UEFI layout^) ───
echo [1/3] Partitioning iSCSI disk ^(Disk %ISCSI_DISK_NUM%^)...
echo [dism] Partitioning disk %ISCSI_DISK_NUM%... >> %DISMLOG%
echo select disk %ISCSI_DISK_NUM%        > %SYSTEMDRIVE%\__dism_part.txt
echo clean                              >> %SYSTEMDRIVE%\__dism_part.txt
echo convert gpt                        >> %SYSTEMDRIVE%\__dism_part.txt
echo create partition efi size=260      >> %SYSTEMDRIVE%\__dism_part.txt
echo format quick fs=fat32 label="System" >> %SYSTEMDRIVE%\__dism_part.txt
echo assign letter=%EFI_DRIVE%          >> %SYSTEMDRIVE%\__dism_part.txt
echo create partition msr size=16       >> %SYSTEMDRIVE%\__dism_part.txt
echo create partition primary           >> %SYSTEMDRIVE%\__dism_part.txt
echo format quick fs=ntfs label="Windows" >> %SYSTEMDRIVE%\__dism_part.txt
echo assign letter=%WIN_DRIVE%          >> %SYSTEMDRIVE%\__dism_part.txt
echo exit                               >> %SYSTEMDRIVE%\__dism_part.txt
diskpart /s %SYSTEMDRIVE%\__dism_part.txt >> %DISMLOG% 2>&1
del %SYSTEMDRIVE%\__dism_part.txt >nul 2>&1
echo   Disk partitioned. EFI=%EFI_DRIVE%: Windows=%WIN_DRIVE%:
echo [dism] Disk partitioned. >> %DISMLOG%
echo.

REM ── Step 2: Apply Windows image ─────────────────────────────
REM  install.wim at %INSTALL_DRIVE%:\sources\install.wim
REM  (standard Windows ISO layout on the windows-installation iSCSI LUN).
echo [2/3] Applying Windows 11 image ^(index %WIN_IMG_INDEX%^) — this will take several minutes...
echo [dism] Applying %INSTALL_DRIVE%:\sources\install.wim index %WIN_IMG_INDEX% to %WIN_DRIVE%:\ >> %DISMLOG%
dism /apply-image /imagefile:%INSTALL_DRIVE%:\sources\install.wim /index:%WIN_IMG_INDEX% /applydir:%WIN_DRIVE%:\ >> %DISMLOG% 2>&1
set /a dism_err=%errorlevel%
if !dism_err! neq 0 (
    echo   ERROR: DISM apply-image failed ^(code !dism_err!^). Check %DISMLOG%.
    echo [dism] ERROR: dism /apply-image failed ^(code !dism_err!^). >> %DISMLOG%
    exit /b 1
)
echo   Image applied successfully.
echo [dism] Image applied. >> %DISMLOG%
echo.

REM ── Step 3: Configure UEFI boot ─────────────────────────────
echo [3/3] Configuring UEFI boot with bcdboot...
echo [dism] Running bcdboot %WIN_DRIVE%:\Windows /s %EFI_DRIVE%: /f UEFI >> %DISMLOG%
bcdboot %WIN_DRIVE%:\Windows /s %EFI_DRIVE%: /f UEFI >> %DISMLOG% 2>&1
set /a bcd_err=%errorlevel%
if !bcd_err! neq 0 (
    echo   ERROR: bcdboot failed ^(code !bcd_err!^). Check %DISMLOG%.
    echo [dism] ERROR: bcdboot failed ^(code !bcd_err!^). >> %DISMLOG%
    exit /b 1
)
echo   Boot configured.
echo [dism] Boot configured. >> %DISMLOG%
echo.

echo [dism] %date% %time% - Done. Installation complete. >> %DISMLOG%

echo.
echo ========================================
echo   Installation complete.
echo   Reboot and select "Network Boot Windows 11"
echo   from the iPXE menu to start Windows.
echo ========================================
echo.

endlocal
exit /b 0
