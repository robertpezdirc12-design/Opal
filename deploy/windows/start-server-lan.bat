@echo off
rem Opal headless server — LAN mode. Phones, tablets and PCs on the HOME
rem network reach the API and paired browser extensions at this machine's
rem address. Auth still applies to every non-health route; do not port-forward
rem to the internet — for remote access use Tailscale or a reverse proxy with
rem TLS (see docs/headless-deploy.md).
cd /d "%~dp0"
set "OPAL_HEADLESS=1"
set "OPAL_MPV_OPTS=ao=null;vo=null"
set "OPAL_WEB_BIND=lan"
echo [opal] LAN server starting on http://0.0.0.0:41595/
echo [opal] home devices: use this machine's address, e.g. http://192.168.2.108:41595/
ipconfig | findstr /C:"IPv4"
opal.exe
