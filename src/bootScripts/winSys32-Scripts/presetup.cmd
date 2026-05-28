@echo off

REM ============================================================
REM  presetup.cmd
REM  Called by winpeshl.exe (via winpeshl.ini) before setup.exe.
REM  winpeshl.exe has already called wpeinit.exe by this point,
REM  so PnP and driver init are done. We just need iSCSI up
REM  before handing off to the Windows installer.
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
echo [presetup] iSCSI pre-setup complete. setup.exe will be launched by winpeshl.exe.
echo [presetup] Done >> %PRELOG%
