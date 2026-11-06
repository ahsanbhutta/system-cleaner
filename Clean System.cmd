@echo off
rem ==========================================================================
rem  System Cleaner - double-click launcher
rem  Runs the cleaner in interactive mode (report -> confirm -> clean).
rem  For options, open a terminal and run SystemCleaner.ps1 with flags:
rem    -Report   dry run only        -Yes   no prompts
rem    -NoProjects / -NoBrowsers    -RecycleBin / -ComponentCleanup
rem ==========================================================================
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0SystemCleaner.ps1" %*
