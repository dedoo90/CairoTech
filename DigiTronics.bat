@echo off
chcp 65001 >nul
title DigiTronics - نظام الإدارة الاحترافي

set "DTDIR=%USERPROFILE%\Documents\DigiTronics"
if not exist "%DTDIR%" mkdir "%DTDIR%"
if not exist "%DTDIR%\Backups" mkdir "%DTDIR%\Backups"
echo [%date% %time%] DigiTronics launched >> "%DTDIR%\launcher_log.txt"

for %%f in ("%USERPROFILE%\Downloads\DigiTronics_Log_*.txt") do (
    if exist "%%f" ( copy "%%f" "%DTDIR%\" >nul 2>&1 & del "%%f" >nul 2>&1 )
)
for %%f in ("%USERPROFILE%\Downloads\DigiTronics_Backup_*.json") do (
    if exist "%%f" ( copy "%%f" "%DTDIR%\Backups\" >nul 2>&1 )
)

set "HTML_FILE="
if exist "%~dp0DigiTronics.html" set "HTML_FILE=%~dp0DigiTronics.html"
if exist "%~dp0DigiTronics_v5.html" set "HTML_FILE=%~dp0DigiTronics_v5.html"

if defined HTML_FILE (
    start "" "%HTML_FILE%"
    timeout /t 2 >nul
) else (
    echo ERROR: DigiTronics.html not found! & pause
)
exit
