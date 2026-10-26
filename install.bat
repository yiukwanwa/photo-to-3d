@echo off
chcp 65001 >nul
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0sketchup\photo_to_3d\install.ps1" -AddToSketchUp
echo.
pause
