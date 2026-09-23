@echo off
cd /d "%~dp0"
echo Tiger Desktop Pet - debug launcher
echo All output, including script parse errors, is saved to TigerPet_launch.log
echo The tiger window stays open while this console waits. Close the tiger to see the log.
echo.
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0TigerPet.ps1" > "%~dp0TigerPet_launch.log" 2>&1
set RC=%ERRORLEVEL%
echo ---------- TigerPet_launch.log ----------
type "%~dp0TigerPet_launch.log"
echo -----------------------------------------
echo Process exit code: %RC%
pause
