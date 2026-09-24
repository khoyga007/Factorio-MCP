@echo off
rem Launch Factorio with ONLY base + the bridge mod (repo copy via junction), for
rem playtests on a vanilla save. Your normal mod set in APPDATA is not touched.
if "%FACTORIO_EXE%"=="" (
  echo Set FACTORIO_EXE to the full path of factorio.exe first.
  pause
  exit /b 1
)
if not exist "%~dp0.vanilla-mods\factorio-ai-bridge_0.1.0" mklink /J "%~dp0.vanilla-mods\factorio-ai-bridge_0.1.0" "%~dp0factorio-ai-bridge_0.1.0"
start "" "%FACTORIO_EXE%" --mod-directory "%~dp0.vanilla-mods" --enable-lua-udp 34198
