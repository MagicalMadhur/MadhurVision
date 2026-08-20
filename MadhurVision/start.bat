@echo off
title Madhur Vision Launcher
:menu
cls
echo ========================================================
echo               MADHUR VISION - LAUNCHER
echo ========================================================
echo.
echo Please select how you want to run the application:
echo.
echo [1] Desktop Mode + Local Webcam (Default)
echo [2] VR Mode (Split Screen) + Local Webcam
echo [3] Desktop Mode + iPhone Camera (WebRTC)
echo [4] VR Mode (Split Screen) + iPhone Camera (WebRTC)
echo [5] Run Gesture Calibration
echo [6] Exit
echo.
set /p choice="Enter your choice (1-6): "

if "%choice%"=="1" goto run_desktop_local
if "%choice%"=="2" goto run_vr_local
if "%choice%"=="3" goto run_desktop_webrtc
if "%choice%"=="4" goto run_vr_webrtc
if "%choice%"=="5" goto run_calibrate
if "%choice%"=="6" goto eof

goto menu

:run_desktop_local
cls
echo Starting Desktop Mode with Local Webcam...
echo Press ESC to quit when running.
echo.
python main.py
pause
goto menu

:run_vr_local
cls
echo Starting VR Mode with Local Webcam...
echo Press ESC to quit when running.
echo.
python main.py --mode vr
pause
goto menu

:run_desktop_webrtc
cls
echo Starting Desktop Mode with iPhone Camera...
echo Look for the URL in the console below to open on your iPhone!
echo Press ESC to quit when running.
echo.
python main.py --camera webrtc
pause
goto menu

:run_vr_webrtc
cls
echo Starting VR Mode with iPhone Camera...
echo Look for the URL in the console below to open on your iPhone!
echo Press ESC to quit when running.
echo.
python main.py --mode vr --camera webrtc
pause
goto menu

:run_calibrate
cls
echo Starting Gesture Calibration Tool...
echo.
python main.py --calibrate
pause
goto menu

:eof
exit
