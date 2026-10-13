@echo off
rem hermes-memory-stack installer - Windows (cmd)
rem All prompts are asked upfront (Phase 0); the rest is unattended.
rem Components are detected first and SKIPPED when present; re-run after fixing issues.
rem NOTE: keep this file ASCII-only. cmd.exe mis-parses batch files whose
rem line starts contain multi-byte UTF-8 characters (pushd becomes "ushd").
setlocal EnableDelayedExpansion
cd /d "%~dp0"
title Hermes Memory Stack Installer (Windows)

set "SHELL=C:\msys64\usr\bin\bash.exe"
set TOTAL=10
set STEP=0

if not exist .env copy .env.example .env >nul
echo ==============================================================
echo   Hermes Memory Stack installer (Windows)
echo   Components are detected and SKIPPED when present.
echo ==============================================================

echo.
echo ==^> [1/%TOTAL%] Configuration wizard
rem ---- winget ----
where winget >nul 2>&1
if errorlevel 1 (echo    ! winget not found; auto-install limited, follow manual hints & set WINGET=no
) else (set WINGET=yes & echo    ^> winget available)
rem ---- detection summary ----
for %%c in (git docker node bun) do (
    where %%c >nul 2>&1 && echo    ^> %%c installed || echo    . %%c missing (will install)
)
rem ---- endpoints ----
set NEED_ENDPOINTS=no
findstr /r "^EMBED_BASE_URL=http://[^R] ^CHAT_BASE_URL=http://[^R]" .env >nul 2>&1 || set NEED_ENDPOINTS=yes
if "%NEED_ENDPOINTS%"=="no" echo    ^> model endpoints already configured (.env)
if "%NEED_ENDPOINTS%"=="yes" (
    echo    Model endpoints not configured (LM Studio / llama.cpp / OpenAI-compatible)
    set /p EBASE="   ? Embedding endpoint Base URL [http://127.0.0.1:1234/v1]: "
    if "!EBASE!"=="" set "EBASE=http://127.0.0.1:1234/v1"
    set /p EMODEL="   ? Embedding model name: "
    set /p EDIM="   ? Embedding dimensions [2560]: "
    if "!EDIM!"=="" set "EDIM=2560"
    set /p CBASE="   ? Chat endpoint Base URL (empty = same as above): "
    if "!CBASE!"=="" set "CBASE=!EBASE!"
    set /p CMODEL="   ? Chat model name: "
    >> .env echo EMBED_PROVIDER=lmstudio
    >> .env echo CHAT_PROVIDER=lmstudio
    >> .env echo EMBED_BASE_URL=!EBASE!
    >> .env echo EMBED_MODEL=!EMODEL!
    >> .env echo EMBED_DIM=!EDIM!
    >> .env echo CHAT_BASE_URL=!CBASE!
    >> .env echo CHAT_MODEL=!CMODEL!
    >> .env echo LMSTUDIO_BASE_URL=!EBASE!
    echo    ^> endpoints appended to .env
)
rem ---- restore ----
set DO_RESTORE=n
set /p DO_RESTORE="   ? Restore data from encrypted backup repo? [y/N]: "
set /p GKEY="   ? git-crypt key path [%USERPROFILE%\.ssh\git-crypt-backup.key]: "
if "!GKEY!"=="" set "GKEY=%USERPROFILE%\.ssh\git-crypt-backup.key"
echo    Wizard done: restore=!DO_RESTORE!
set STEP=1

call :step "winget packages (git, node, bun, uv, python)"
if "%WINGET%"=="no" ( echo    ! skip winget step ) else (
    where git   >nul 2>&1 || winget install -e --source winget --accept-source-agreements --accept-package-agreements Git.Git
    where node  >nul 2>&1 || winget install -e --source winget --accept-package-agreements OpenJS.NodeJS.LTS
    where bun   >nul 2>&1 || winget install -e --source winget --accept-package-agreements Oven-sh.Bun
    where uv    >nul 2>&1 || winget install -e --source winget --accept-package-agreements astral-sh.uv
    where python >nul 2>&1 || winget install -e --source winget --accept-package-agreements Python.Python.3.12
)
set STEP=%STEP%
rem refresh PATH in this session
set "PATH=%PATH%;%ProgramFiles%\Git\cmd;%ProgramFiles%\nodejs;%USERPROFILE%\.bun\bin;%USERPROFILE%\.local\bin;%LOCALAPPDATA%\Programs\Python\Python312\Scripts"

call :step "MSYS2 (git-crypt + bash for scripts)"
if exist "C:\msys64\usr\bin\bash.exe" ( echo    ~ skip: MSYS2 already installed ) else (
    if "%WINGET%"=="yes" ( winget install -e --source winget --accept-package-agreements MSYS2.MSYS2 ) else ( echo    ! install MSYS2 manually: https://www.msys2.org )
)
if exist "C:\msys64\usr\bin\bash.exe" (
    C:\msys64\usr\bin\pacman.exe -S --needed --noconfirm git-crypt rsync zstd jq >nul 2>&1
    echo    ^> git-crypt/rsync/zstd/jq ready
)

call :step "Docker Desktop"
where docker >nul 2>&1 && ( echo    ~ skip: docker already installed & goto :docker_done )
if "%WINGET%"=="yes" (
    echo    Installing Docker Desktop ^(WSL2 backend, admin consent required^)...
    winget install -e --source winget --accept-package-agreements --accept-eula Docker.DockerDesktop
) else ( echo    ! install Docker Desktop manually: https://www.docker.com/products/docker-desktop/ )
:docker_done
rem wait for daemon (max 120s)
set /a T=0
:docker_wait
docker info >nul 2>&1 && ( echo    ^> docker daemon running & goto :docker_ok )
set /a T+=5
if %T% LSS 120 ( timeout /t 5 /nobreak >nul & goto :docker_wait )
echo    x ABORT: docker daemon not running - start Docker Desktop and re-run this script
exit /b 1
:docker_ok

call :step "Postgres container (pgvector)"
docker ps --format "{{.Names}}" | findstr /x "brain-postgres" >nul 2>&1
if not errorlevel 1 ( echo    ~ skip: container exists & goto :pg_done )
docker compose up -d postgres || ( echo    x ABORT: compose failed & exit /b 1 )
:pg_done

call :step "OpenViking container"
docker ps -a --format "{{.Names}}" | findstr /x "openviking" >nul 2>&1
if not errorlevel 1 ( echo    ~ skip: container exists & goto :ov_done )
docker compose up -d openviking || echo    ! start failed - check .env endpoints: docker compose logs openviking
:ov_done

call :step "gbrain CLI (build from source)"
where gbrain >nul 2>&1 && ( echo    ~ skip: installed & goto :gb_done )
if not exist "%USERPROFILE%\Projects\gbrain-upstream" git clone https://github.com/garrytan/gbrain "%USERPROFILE%\Projects\gbrain-upstream" || ( echo    x ABORT: gbrain clone failed & exit /b 1 )
pushd "%USERPROFILE%\Projects\gbrain-upstream"
bun install && bun run build
if exist bin\gbrain.exe (
    mkdir "%USERPROFILE%\.local\bin" 2>nul
    copy /y bin\gbrain.exe "%USERPROFILE%\.local\bin\" >nul
    setx PATH "%PATH%;%USERPROFILE%\.local\bin" >nul
    echo    ^> gbrain installed to ~/.local/bin/gbrain.exe
) else ( echo    ! gbrain build output missing, see README )
popd
:gb_done

call :step "Apply config (configure.sh via MSYS2 bash)"
if exist "%USERPROFILE%\.gbrain\config.json" ( echo    ~ skip: gbrain already configured (re-run configure.sh to update) ) else (
    if exist "%SHELL%" ( "%SHELL%" -lc "cd ~/hermes-memory-stack 2>/dev/null || cd '$(cygpath -u '%CD%')'; bash configure.sh" ) else ( echo    ! no MSYS2 bash; run bash configure.sh in Git Bash manually )
)

call :step "Data restore (optional)"
if /i not "!DO_RESTORE!"=="y" ( echo    ~ skip: restore not selected (re-run and answer y) & goto :rs_done )
if exist "%SHELL%" ( "%SHELL%" -lc "cd '$(cygpath -u '%CD%')'; bash scripts/restore.sh" ) else ( echo    ! no bash, cannot auto-restore )
:rs_done

call :step "Scheduled tasks (Task Scheduler)"
schtasks /query /tn HermesBrainDaily >nul 2>&1
if not errorlevel 1 ( echo    ~ skip: tasks exist ) else (
    if exist "%SHELL%" (
        schtasks /create /f /tn HermesBrainDaily /sc daily /st 04:04 /tr "\"%SHELL%\" -lc \"cd '%CD%' && bash scripts/gbrain-daily.sh\""
        schtasks /create /f /tn HermesBrainBackup /sc weekly /d SUN /st 22:30 /tr "\"%SHELL%\" -lc \"cd '%CD%' && bash scripts/backup-daily.sh\""
        echo    ^> HermesBrainDaily (daily 04:04) / HermesBrainBackup (Sun 22:30)
    ) else ( echo    ! no bash; configure scheduled tasks manually )
)

call :step "Hermes Agent"
where hermes >nul 2>&1 && ( echo    ^> hermes installed & goto :hn_done )
echo    On Windows, Hermes Agent is recommended inside WSL2 (Ubuntu):
echo      wsl --install -d ubuntu   then inside it:
echo      curl -fsSL https://hermes-agent.nousresearch.com/install.sh ^| bash
:hn_done

echo.
echo ==============================================================
echo   Done %STEP%/%TOTAL%. ~ = skipped (already present).
echo   Verify:
echo     docker exec brain-postgres pg_isready -U postgres
echo     gbrain stats
echo     curl -s -o nul -w "%%{http_code}\n" localhost:1933/health   (401 = OK)
echo     schtasks /query /tn HermesBrainDaily
echo ==============================================================
endlocal
exit /b 0

:step
set /a STEP+=1
echo.
echo ==^> [%STEP%/%TOTAL%] %~1
exit /b 0
