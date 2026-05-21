@echo off
setlocal
set SCRIPT_DIR=%~dp0..\Scripts
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%\Watch-PdfExportAndPrintNewPdfs.ps1"
