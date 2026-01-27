@echo off
REM ============================================================================
REM Delete Windows Reserved Filename Script
REM ============================================================================
REM
REM PURPOSE:
REM   Deletes files with Windows reserved names (NUL, CON, PRN, AUX, COM1-9, LPT1-9)
REM   that cannot be deleted through normal means.
REM
REM USAGE:
REM   1. Right-click this script and select "Run as administrator"
REM   2. Enter the full path to the file when prompted
REM
REM EXAMPLES OF RESERVED NAMES:
REM   NUL, CON, PRN, AUX, COM1, COM2, COM3, COM4, COM5, COM6, COM7, COM8, COM9,
REM   LPT1, LPT2, LPT3, LPT4, LPT5, LPT6, LPT7, LPT8, LPT9
REM
REM WHY THIS HAPPENS:
REM   These names are reserved DOS device names from the 1980s. Windows still
REM   intercepts these names at the filesystem layer, treating them as devices
REM   rather than files. The \\?\ prefix bypasses this name checking.
REM
REM ============================================================================

setlocal EnableDelayedExpansion

echo.
echo === Delete Windows Reserved Filename ===
echo.

if "%~1"=="" (
    set /p "FILEPATH=Enter full path to file (e.g., C:\path\to\nul): "
) else (
    set "FILEPATH=%~1"
)

if "!FILEPATH!"=="" (
    echo ERROR: No path provided.
    goto :end
)

echo.
echo Attempting to delete: !FILEPATH!
echo Using extended path:  \\?\!FILEPATH!
echo.

del /f /a "\\?\!FILEPATH!" 2>nul

if exist "\\?\!FILEPATH!" (
    echo FAILED: Could not delete the file.
    echo.
    echo Possible reasons:
    echo   - File is in use by another process
    echo   - Insufficient permissions (try running as Administrator)
    echo   - Path is incorrect
) else (
    echo SUCCESS: File deleted.
)

:end
echo.
pause
