@echo off

REM ============================================================
REM  iscsi-creds.cmd
REM  iSCSI credentials loaded by iscsi-connect.cmd at boot.
REM
REM  After cloning, fill in real values then run:
REM    git update-index --skip-worktree src/bootScripts/winSys32-Scripts/iscsi-creds.cmd
REM  to prevent accidental commits of credentials.
REM
REM  This file is served via iPXE initrd at boot time and lands
REM  at %SYSTEMDRIVE%\Windows\System32\iscsi-creds.cmd in WinPE.
REM ============================================================

REM iSCSI target portal and IQN
set ISCSI_PORTAL=REPLACE_WITH_TARGET_PORTAL_IP
set ISCSI_PORT=3260
set ISCSI_IQN=REPLACE_WITH_TARGET_IQN

REM CHAP: initiator authenticates TO the target
set ISCSI_USER=REPLACE_WITH_CHAP_USERNAME
set ISCSI_PASS=REPLACE_WITH_CHAP_PASSWORD

REM Mutual CHAP secret: target authenticates BACK to the initiator
set ISCSI_CHAP_SECRET=REPLACE_WITH_MUTUAL_CHAP_SECRET
