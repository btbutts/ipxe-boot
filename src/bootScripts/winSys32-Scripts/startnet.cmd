@echo off

REM ============================================================
REM  startnet.cmd
REM  Called by presetup.cmd. wpeinit is called explicitly in Step 0
REM  below — with a custom winpeshl.ini, winpeshl.exe does NOT call
REM  wpeinit automatically.
REM
REM  IMPORTANT: Do NOT use the pipe operator (|) anywhere in
REM  this file. In WinPE batch files, any pipe causes cmd.exe
REM  to lose its file position and silently skip all subsequent
REM  lines. Use temp files + diskpart /s instead.
REM ============================================================

set _D=%date%
set _D=%_D: =0%
set _D=%_D:/=-%
set NETLOG=%SYSTEMDRIVE%\startnet_%_D%.log

echo [startnet] %date% %time% - Starting >> %NETLOG%

REM ── Step 0: Initialize WinPE ────────────────────────────────────
REM  With a custom winpeshl.ini, winpeshl.exe does NOT call wpeinit
REM  automatically — it must be called explicitly. Without this,
REM  there is no PnP init, no NIC driver binding, and no DHCP.
echo [startnet] Calling wpeinit (PnP + DHCP)... >> %NETLOG%
wpeinit
echo [startnet] wpeinit done (exit code: %errorlevel%) >> %NETLOG%

REM Append OpenSSH to PATH for this process, then write to registry so
REM independently-launched processes (e.g. Ctrl+F10 debug shell) inherit it.
SET PATH=%PATH%;%SYSTEMDRIVE%\Windows\System32\OpenSSH
reg add "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Environment" /v Path /t REG_EXPAND_SZ /d "%PATH%" /f >nul 2>&1
echo [startnet] System PATH updated in registry >> %NETLOG%

REM ── Step 1: SAN policy ──────────────────────────────────────
REM Set BEFORE iSCSI connects so the disk auto-comes-online
REM when msiscsi enumerates it. setup.exe reads this at init time.
echo [startnet] Setting SAN policy=onlineAll >> %NETLOG%
echo san policy=onlineAll > %SYSTEMDRIVE%\__dp_tmp.txt
echo exit >> %SYSTEMDRIVE%\__dp_tmp.txt
diskpart /s %SYSTEMDRIVE%\__dp_tmp.txt >> %NETLOG% 2>&1
del %SYSTEMDRIVE%\__dp_tmp.txt >nul 2>&1
echo [startnet] SAN policy set >> %NETLOG%

REM ── Step 2: Wait for IPv4 ───────────────────────────────────
REM Write ipconfig to a temp file and use findstr on it.
REM Avoids the pipe operator entirely.
echo [startnet] Waiting for network (IPv4)... >> %NETLOG%
<nul set /p "=[startnet] Waiting for IPv4"
set /a net_retries=0
:WAIT_NET
set /a net_retries+=1
ipconfig > %SYSTEMDRIVE%\__net_tmp.txt 2>nul
findstr /i "IPv4" %SYSTEMDRIVE%\__net_tmp.txt >nul 2>&1
if not errorlevel 1 goto NET_READY
del %SYSTEMDRIVE%\__net_tmp.txt >nul 2>&1
if %net_retries% geq 30 goto NET_TIMEOUT
<nul set /p "= ."
ping -n 3 127.0.0.1 >nul 2>&1
goto WAIT_NET

:NET_TIMEOUT
echo.
echo [startnet] Network wait timed out, continuing anyway >> %NETLOG%
goto CALL_ISCSI

:NET_READY
echo.
del %SYSTEMDRIVE%\__net_tmp.txt >nul 2>&1
echo [startnet] Network ready at retry %net_retries% >> %NETLOG%

REM ── Step 3: Connect iSCSI (with retry) ──────────────────────
REM iscsi-connect.cmd can fail if the target portal is not yet
REM reachable (route not established, DHCP still settling, etc.).
REM Retry up to 5 times with ~10s between attempts.
:CALL_ISCSI
if not exist %SYSTEMDRIVE%\Windows\System32\iscsi-connect.cmd (
    echo [startnet] WARNING: iscsi-connect.cmd not found >> %NETLOG%
    goto DONE
)
set /a iscsi_try=0
:ISCSI_TRY
set /a iscsi_try+=1
echo [startnet] iscsi-connect attempt %iscsi_try%/5 >> %NETLOG%
call %SYSTEMDRIVE%\Windows\System32\iscsi-connect.cmd
set /a iscsi_err=%errorlevel%
echo [startnet] exit code: %iscsi_err% >> %NETLOG%
sc query msiscsi >> %NETLOG% 2>&1
if %iscsi_err% equ 0 goto ISCSI_OK
if %iscsi_try% geq 5 goto ISCSI_FAILED
echo [startnet] Attempt %iscsi_try% failed, waiting 10s before retry >> %NETLOG%
ping -n 28 127.0.0.1 >nul 2>&1
goto ISCSI_TRY

:ISCSI_FAILED
echo [startnet] iscsi-connect.cmd failed after 5 attempts >> %NETLOG%
goto AFTER_ISCSI

:ISCSI_OK
echo [startnet] iscsi-connect.cmd succeeded on attempt %iscsi_try% >> %NETLOG%

REM ── Step 4: Rescan disks ────────────────────────────────────
:AFTER_ISCSI
echo [startnet] Waiting for disk enumeration... >> %NETLOG%
ping -n 11 127.0.0.1 >nul 2>&1
echo [startnet] Rescanning disks... >> %NETLOG%
echo rescan > %SYSTEMDRIVE%\__dp_tmp.txt
echo exit >> %SYSTEMDRIVE%\__dp_tmp.txt
diskpart /s %SYSTEMDRIVE%\__dp_tmp.txt >> %NETLOG% 2>&1
del %SYSTEMDRIVE%\__dp_tmp.txt >nul 2>&1
echo [startnet] Rescan done >> %NETLOG%

:DONE
echo [startnet] %date% %time% - Done >> %NETLOG%
