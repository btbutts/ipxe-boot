@echo off
setlocal enabledelayedexpansion

REM ============================================================
REM  dism-install.cmd  (setupManual — DISM installation path)
REM  Partitions the iSCSI LUN and applies Windows 11 via DISM.
REM  Called by winpeshl.ini after presetup.cmd finishes iSCSI setup.
REM
REM  install.wim is served on-demand by wimboot from the QNAP HTTP
REM  server via initrd — no SMB or credentials needed for the image.
REM  It is available at %SYSTEMDRIVE%\install.wim inside WinPE.
REM ============================================================

REM ── Configuration ───────────────────────────────────────────
set ISCSI_DISK_NUM=1
set WIN_IMG_INDEX=1
set WIN_DRIVE=W
set EFI_DRIVE=V
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

REM ── Step 1: Partition iSCSI LUN ^(GPT/UEFI layout^) ──────────
echo [1/3] Partitioning iSCSI disk ^(Disk %ISCSI_DISK_NUM%^)...
echo [dism] Partitioning disk %ISCSI_DISK_NUM%... >> %DISMLOG%
echo select disk %ISCSI_DISK_NUM% > %SYSTEMDRIVE%\__dism_part.txt
echo clean                        >> %SYSTEMDRIVE%\__dism_part.txt
echo convert gpt                  >> %SYSTEMDRIVE%\__dism_part.txt
echo create partition efi size=260 >> %SYSTEMDRIVE%\__dism_part.txt
echo format quick fs=fat32 label="System" >> %SYSTEMDRIVE%\__dism_part.txt
echo assign letter=%EFI_DRIVE%    >> %SYSTEMDRIVE%\__dism_part.txt
echo create partition msr size=16 >> %SYSTEMDRIVE%\__dism_part.txt
echo create partition primary      >> %SYSTEMDRIVE%\__dism_part.txt
echo format quick fs=ntfs label="Windows" >> %SYSTEMDRIVE%\__dism_part.txt
echo assign letter=%WIN_DRIVE%    >> %SYSTEMDRIVE%\__dism_part.txt
echo exit                         >> %SYSTEMDRIVE%\__dism_part.txt
diskpart /s %SYSTEMDRIVE%\__dism_part.txt >> %DISMLOG% 2>&1
del %SYSTEMDRIVE%\__dism_part.txt >nul 2>&1
echo   Disk partitioned. EFI=%EFI_DRIVE%: Windows=%WIN_DRIVE%:
echo [dism] Disk partitioned. >> %DISMLOG%
echo.

REM ── Step 2: Apply Windows image ─────────────────────────────
REM  install.wim is served by wimboot from QNAP HTTP on-demand.
REM  It appears at %SYSTEMDRIVE%\install.wim inside WinPE.
echo [2/3] Applying Windows 11 image ^(index %WIN_IMG_INDEX%^) — this will take several minutes...
echo [dism] Applying %SYSTEMDRIVE%\install.wim index %WIN_IMG_INDEX% to %WIN_DRIVE%:\ >> %DISMLOG%
dism /apply-image /imagefile:%SYSTEMDRIVE%\install.wim /index:%WIN_IMG_INDEX% /applydir:%WIN_DRIVE%:\ >> %DISMLOG% 2>&1
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
