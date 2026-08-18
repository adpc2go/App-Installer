@echo off
setlocal enabledelayedexpansion

:: ----------------------------------------
::     ADOBE FIREWALL BLOCK SCRIPT
:: ----------------------------------------

:: 1) Set up counters for final summary
set "existingCount=0"
set "addedCount=0"

:: 2) Define the folders to block (semicolon-separated).
set "foldersToBlock=C:\Program Files\Adobe;C:\Users\%username%\AppData\Local\Adobe;C:\Users\%username%\AppData\LocalLow\Adobe;C:\Program Files (x86)\Common Files\Adobe"

:: 3) Define the log file path (you can change the name or path as needed).
::    %~dp0 = directory of the current script
set "logFile=%~dp0AdobeBlockLog.txt"

:: 4) Initialize the log with a header
(
    echo ======================================================
    echo  Adobe Firewall Block Script - START
    echo  Date: %date%
    echo  Time: %time%
    echo ======================================================
    echo.
) > "%logFile%"

echo ======================================================
echo  Adobe Firewall Block Script
echo  Logging to: "%logFile%"
echo ======================================================
echo.

:: 5) Loop through each folder in the list
for %%F in ("%foldersToBlock:;=" "%") do (
    if exist "%%~F" (
        echo Scanning folder: %%~F
        echo Scanning folder: %%~F >> "%logFile%"
        call :BlockFolder "%%~F"
    ) else (
        echo Folder does not exist: %%~F
        echo Folder does not exist: %%~F >> "%logFile%"
    )
)

:: 6) Print summary to console
echo.
echo ------------------------------------------------------
echo Firewall Rules Summary
echo ------------------------------------------------------
echo Rules already exist: %existingCount%
echo Rules added       : %addedCount%
echo.

:: 7) Append the same summary to log file
(
    echo.
    echo ------------------------------------------------------
    echo Firewall Rules Summary
    echo ------------------------------------------------------
    echo Rules already exist: %existingCount%
    echo Rules added       : %addedCount%
    echo.
    echo ======================================================
    echo  Adobe Firewall Block Script - END
    echo  Date: %date%
    echo  Time: %time%
    echo ======================================================
    echo.
) >> "%logFile%"

echo Done!
pause
exit /b


:: -------------------------------------------------
:: Subroutine: BlockFolder
::   Enumerates all .exe files under the given folder
::   and calls :block_executable for each one.
:: -------------------------------------------------
:BlockFolder
set "targetFolder=%~1"

:: Recursively find all .exe files
for /r "%targetFolder%" %%X in (*.exe) do (
    call :block_executable "%%~fX"
)
exit /b


:: -------------------------------------------------
:: Subroutine: block_executable
::   Checks if a firewall rule already exists
::   for the given .exe path. If not, creates it.
:: -------------------------------------------------
:block_executable
set "exePath=%~1"

:: Create a rule name based on the full path
set "ruleName=Adobe Block %exePath%"

:: Check if this rule already exists
netsh advfirewall firewall show rule name="%ruleName%" >nul 2>&1
if %errorlevel% neq 0 (
    echo [NEW] Blocking: "%exePath%"
    echo [NEW] Blocking: "%exePath%" >> "%logFile%"
    netsh advfirewall firewall add rule ^
        name="%ruleName%" ^
        dir=out ^
        action=block ^
        program="%exePath%" ^
        profile=domain,private,public ^
        enable=yes
    set /a addedCount+=1
) else (
    echo [EXISTING] Already blocked: "%exePath%"
    echo [EXISTING] Already blocked: "%exePath%" >> "%logFile%"
    set /a existingCount+=1
)

exit /b