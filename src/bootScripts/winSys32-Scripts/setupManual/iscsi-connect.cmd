@echo off
setlocal enabledelayedexpansion

REM ============================================================
REM  iscsi-connect.cmd  (setupManual — DISM installation path)
REM  Connects the iSCSI LUN for use by dism-install.cmd.
REM  Differs from setupDefault: MiniNT key is NOT restored
REM  because setup.exe is not launched in this path.
REM ============================================================

set _D=%date%
set _D=%_D: =0%
set _D=%_D:/=-%
set ISCSILOG=%SYSTEMDRIVE%\iscsi-connect_%_D%.log
echo [iscsi] %date% %time% - Starting >> %ISCSILOG%

REM ── Load credentials ────────────────────────────────────────
if not exist %SYSTEMDRIVE%\Windows\System32\iscsi-creds.cmd (
    echo [iscsi] ERROR: iscsi-creds.cmd not found. Cannot connect. >> %ISCSILOG%
    exit /b 1
)
call %SYSTEMDRIVE%\Windows\System32\iscsi-creds.cmd
echo [iscsi] Credentials loaded. >> %ISCSILOG%

echo ========================================
echo   iSCSI Connection Script
echo ========================================
echo.

echo [1/4] Waiting for WinPE Network Configuration to settle...
echo [iscsi] Step 1: Waiting for target portal %ISCSI_PORTAL%... >> %ISCSILOG%
set /a retries=0
:NetworkWait
ping -n 1 %ISCSI_PORTAL% >nul 2>&1
if errorlevel 1 (
    set /a retries+=1
    if !retries! geq 60 (
        echo   ERROR: Target portal unreachable after 120s. Aborting iSCSI setup.
        echo [iscsi] ERROR: Portal unreachable after 60 attempts ^(120s^). Aborting. >> %ISCSILOG%
        echo [iscsi] %date% %time% - Exiting with code 1 >> %ISCSILOG%
        exit /b 1
    )
    echo   ..Target Portal not reachable yet ^(attempt !retries!/60^). Retrying in 2 seconds...
    echo [iscsi] Portal not reachable, attempt !retries!/60 >> %ISCSILOG%
    ping -n 3 127.0.0.1 >nul 2>&1
    goto NetworkWait
)
echo   Network link verified^! Target portal is reachable after !retries! attempt(s).
echo [iscsi] Portal reachable after !retries! attempt(s). >> %ISCSILOG%
echo.

echo [2/4] Applying WinPE iSCSI Registry Workaround and Starting Service...
echo [iscsi] Step 2: Registry workaround + starting msiscsi... >> %ISCSILOG%
net stop eventlog >nul 2>&1
reg delete HKLM\SYSTEM\CurrentControlSet\Control\MiniNT /f >nul 2>&1
net start eventlog >nul 2>&1
net start msiscsi >> %ISCSILOG% 2>&1
echo [iscsi] msiscsi start exit code: %errorlevel% >> %ISCSILOG%
echo.

echo [3/4] Setting CHAP credentials...
echo [iscsi] Step 3: Setting CHAP credentials... >> %ISCSILOG%
iscsicli CHAPSecret %ISCSI_CHAP_SECRET% >> %ISCSILOG% 2>&1
echo [iscsi] CHAPSecret exit code: %errorlevel% >> %ISCSILOG%
echo.

echo [4/4] Adding target portal and logging in with mutual CHAP...
echo [iscsi] Step 4: AddTargetPortal + LoginTarget... >> %ISCSILOG%
iscsicli AddTargetPortal %ISCSI_PORTAL% %ISCSI_PORT% >> %ISCSILOG% 2>&1
echo [iscsi] AddTargetPortal exit code: %errorlevel% >> %ISCSILOG%

iscsicli LoginTarget %ISCSI_IQN% F %ISCSI_PORTAL% %ISCSI_PORT% "*" "*" "*" 0 0 0 0 0 0 %ISCSI_USER% "%ISCSI_PASS%" 2 "*" 0 >> %ISCSILOG% 2>&1
set /a login_err=%errorlevel%
echo [iscsi] LoginTarget exit code: %login_err% >> %ISCSILOG%
if %login_err% equ 0 (
    echo   iSCSI login successful.
    echo [iscsi] Login successful. >> %ISCSILOG%
) else (
    echo   WARNING: iSCSI login returned code %login_err% ^(may be already connected via sanhook^).
    echo [iscsi] WARNING: Login code %login_err% - may already be connected via sanhook. >> %ISCSILOG%
)
echo.

REM MiniNT is intentionally NOT restored here — this is the DISM path.
REM dism-install.cmd runs next (via winpeshl.ini), not setup.exe.
echo [iscsi] %date% %time% - Done, exiting with code 0 >> %ISCSILOG%

endlocal
exit /b 0
