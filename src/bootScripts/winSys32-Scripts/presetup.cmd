@echo off

REM ============================================================
REM  presetup.cmd
REM  Called by winpeshl.exe (via winpeshl.ini) to set up iSCSI before
REM  the installer launches. startnet.cmd calls wpeinit explicitly —
REM  with a custom winpeshl.ini, winpeshl.exe does NOT call wpeinit.
REM ============================================================

set _D=%date%
set _D=%_D: =0%
set _D=%_D:/=-%
set PRELOG=%SYSTEMDRIVE%\presetup_%_D%.log

echo [presetup] %date% %time% - Starting >> %PRELOG%
echo [presetup] Running iSCSI pre-setup...
echo [presetup] Calling startnet.cmd >> %PRELOG%
call %SYSTEMDRIVE%\Windows\System32\startnet.cmd
echo [presetup] %date% %time% - startnet.cmd returned, errorlevel=%errorlevel% >> %PRELOG%
echo [presetup] iSCSI pre-setup complete. Windows installation will be launched by winpeshl.exe.
echo [presetup] Done >> %PRELOG%
