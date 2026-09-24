@echo off
rem Launch Factorio with the UDP port the bridge mod listens on.
rem Set FACTORIO_EXE to your factorio.exe, e.g.
rem   set FACTORIO_EXE=C:\Program Files\Factorio\bin\x64\factorio.exe
if "%FACTORIO_EXE%"=="" (
  echo Set FACTORIO_EXE to the full path of factorio.exe first.
  exit /b 1
)
start "" "%FACTORIO_EXE%" --enable-lua-udp 34198
