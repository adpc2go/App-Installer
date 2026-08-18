@echo off
if not exist "%~dp0payload.dat" (echo MISSING PAYLOAD & exit /b 9009)
mkdir "%LocalAppData%\SfxProbeDebris" 2>nul
echo halfwritten > "%LocalAppData%\SfxProbeDebris\engine.dll"
exit /b 1603
