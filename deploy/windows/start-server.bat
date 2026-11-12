@echo off
rem Opal headless server — loopback (safe default). Devices on the home
rem network cannot reach this; use start-server-lan.bat to share.
cd /d "%~dp0"
set "OPAL_HEADLESS=1"
set "OPAL_MPV_OPTS=ao=null;vo=null"
echo [opal] headless server starting on http://127.0.0.1:41595/
opal.exe
