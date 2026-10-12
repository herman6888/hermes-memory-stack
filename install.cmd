@echo off
rem hermes-memory-stack installer - Windows (cmd)
rem All prompts are asked upfront (Phase 0); the rest is unattended.
rem Components are detected first and SKIPPED when present; re-run after fixing issues.
setlocal EnableDelayedExpansion
chcp 65001 >nul
cd /d "%~dp0"
title Hermes Memory Stack Installer (Windows)

set "SHELL=C:\msys64\usr\bin\bash.exe"
set TOTAL=10
set STEP=0

if not exist .env copy .env.example .env >nul
echo ==============================================================
echo   Hermes Memory Stack 安装（Windows 版）
echo   组件自动检测：已安装的跳过；询问集中在开头向导
echo ==============================================================

echo.
echo ==> [1/%TOTAL%] 配置向导
rem ---- winget ----
where winget >nul 2>&1
if errorlevel 1 (echo    ! 未找到 winget，自动安装组件将受限，请按提示手动安装 & set WINGET=no
) else (set WINGET=yes & echo    ^> winget 可用)
rem ---- detection summary ----
for %%c in (git docker node bun) do (
    where %%c >nul 2>&1 && echo    ^> %%c 已安装 || echo    . %%c 未安装（将安装）
)
rem ---- endpoints ----
set NEED_ENDPOINTS=no
findstr /r "^EMBED_BASE_URL=http://[^R] ^CHAT_BASE_URL=http://[^R]" .env >nul 2>&1 || set NEED_ENDPOINTS=yes
if "%NEED_ENDPOINTS%"=="no" echo    ^> 模型端点已配置（.env）
if "%NEED_ENDPOINTS%"=="yes" (
    echo    模型端点未配置（LM Studio / llama.cpp / OpenAI 兼容皆可）
    set /p EBASE="   ? Embedding 端点 Base URL [http://127.0.0.1:1234/v1]: "
    if "!EBASE!"=="" set "EBASE=http://127.0.0.1:1234/v1"
    set /p EMODEL="   ? Embedding 模型名: "
    set /p EDIM="   ? Embedding 维度 [2560]: "
    if "!EDIM!"=="" set "EDIM=2560"
    set /p CBASE="   ? 对话端点 Base URL（留空=同上）: "
    if "!CBASE!"=="" set "CBASE=!EBASE!"
    set /p CMODEL="   ? 对话模型名: "
    >> .env echo EMBED_PROVIDER=lmstudio
    >> .env echo CHAT_PROVIDER=lmstudio
    >> .env echo EMBED_BASE_URL=!EBASE!
    >> .env echo EMBED_MODEL=!EMODEL!
    >> .env echo EMBED_DIM=!EDIM!
    >> .env echo CHAT_BASE_URL=!CBASE!
    >> .env echo CHAT_MODEL=!CMODEL!
    >> .env echo LMSTUDIO_BASE_URL=!EBASE!
    echo    ^> 端点已追加到 .env
)
rem ---- restore ----
set DO_RESTORE=n
set /p DO_RESTORE="   ? 从加密备份仓库恢复数据？[y/N]: "
set /p GKEY="   ? git-crypt 密钥路径 [%%USERPROFILE%%\.ssh\git-crypt-backup.key]: "
if "!GKEY!"=="" set "GKEY=%USERPROFILE%\.ssh\git-crypt-backup.key"
echo    向导完成：恢复=!DO_RESTORE!
set STEP=1

call :step "winget 组件（git、node、bun、uv、python）"
if "%WINGET%"=="no" ( echo    ! 跳过 winget 步骤 ) else (
    where git   >nul 2>&1 || winget install -e --accept-source-agreements --accept-package-agreements Git.Git
    where node  >nul 2>&1 || winget install -e --accept-package-agreements OpenJS.NodeJS.LTS
    where bun   >nul 2>&1 || winget install -e --accept-package-agreements Oven-sh.Bun
    where uv    >nul 2>&1 || winget install -e --accept-package-agreements astral-sh.uv
    where python >nul 2>&1 || winget install -e --accept-package-agreements Python.Python.3.12
)
set STEP=%STEP%
rem refresh PATH in this session
set "PATH=%PATH%;%ProgramFiles%\Git\cmd;%ProgramFiles%\nodejs;%USERPROFILE%\.bun\bin;%USERPROFILE%\.local\bin;%LOCALAPPDATA%\Programs\Python\Python312\Scripts"

call :step "MSYS2（git-crypt + bash 运行 scripts）"
if exist "C:\msys64\usr\bin\bash.exe" ( echo    ~ 跳过：MSYS2 已安装 ) else (
    if "%WINGET%"=="yes" ( winget install -e --accept-package-agreements MSYS2.MSYS2 ) else ( echo    ! 请手动安装 MSYS2 https://www.msys2.org )
)
if exist "C:\msys64\usr\bin\bash.exe" (
    C:\msys64\usr\bin\pacman.exe -S --needed --noconfirm git-crypt rsync zstd jq >nul 2>&1
    echo    ^> git-crypt/rsync/zstd/jq 就绪
)

call :step "Docker Desktop"
where docker >nul 2>&1 && ( echo    ~ 跳过：docker 已安装 & goto :docker_done )
if "%WINGET%"=="yes" (
    echo    安装 Docker Desktop（含 WSL2 后端，需要管理员确认）…
    winget install -e --accept-package-agreements --accept-eula Docker.DockerDesktop
) else ( echo    ! 请手动安装 Docker Desktop：https://www.docker.com/products/docker-desktop/ )
:docker_done
rem wait for daemon (max 120s)
set /a T=0
:docker_wait
docker info >nul 2>&1 && ( echo    ^> docker daemon 运行中 & goto :docker_ok )
set /a T+=5
if %T% LSS 120 ( timeout /t 5 /nobreak >nul & goto :docker_wait )
echo    x 中止：docker daemon 未运行——启动 Docker Desktop 后重跑本脚本
exit /b 1
:docker_ok

call :step "Postgres 容器（pgvector）"
docker ps --format "{{.Names}}" | findstr /x "%POSTGRES_CONTAINER%" >nul 2>&1
if not errorlevel 1 ( echo    ~ 跳过：容器已存在 & goto :pg_done )
docker compose up -d postgres || ( echo    x 中止：compose 启动失败 & exit /b 1 )
:pg_done

call :step "OpenViking 容器"
docker ps -a --format "{{.Names}}" | findstr /x "openviking" >nul 2>&1
if not errorlevel 1 ( echo    ~ 跳过：容器已存在 & goto :ov_done )
docker compose up -d openviking || echo    ! 启动失败——检查 .env 端点：docker compose logs openviking
:ov_done

call :step "gbrain CLI（源码构建）"
where gbrain >nul 2>&1 && ( echo    ~ 跳过：已安装 & goto :gb_done )
if not exist "%USERPROFILE%\Projects\gbrain-upstream" git clone https://github.com/garrytan/gbrain "%USERPROFILE%\Projects\gbrain-upstream" || ( echo    x 中止：gbrain clone 失败 & exit /b 1 )
pushd "%USERPROFILE%\Projects\gbrain-upstream"
bun install && bun run build
if exist bin\gbrain.exe (
    mkdir "%USERPROFILE%\.local\bin" 2>nul
    copy /y bin\gbrain.exe "%USERPROFILE%\.local\bin\" >nul
    setx PATH "%PATH%;%USERPROFILE%\.local\bin" >nul
    echo    ^> gbrain 已安装到 ~/.local/bin/gbrain.exe
) else ( echo    ! gbrain 构建产物缺失，见 README )
popd
:gb_done

call :step "应用配置（configure.sh via MSYS2 bash）"
if exist "%USERPROFILE%\.gbrain\config.json" ( echo    ~ 跳过：gbrain 已配置（重跑 configure.sh 可更新） ) else (
    if exist "%SHELL%" ( "%SHELL%" -lc "cd ~/hermes-memory-stack 2>/dev/null || cd '$(cygpath -u '%CD%')'; bash configure.sh" ) else ( echo    ! 缺 MSYS2 bash，请在 Git Bash 手动跑 bash configure.sh )
)

call :step "数据恢复（可选）"
if /i not "!DO_RESTORE!"=="y" ( echo    ~ 跳过：未选择恢复（重跑脚本选 y 即可） & goto :rs_done )
if exist "%SHELL%" ( "%SHELL%" -lc "cd '$(cygpath -u '%CD%')'; bash scripts/restore.sh" ) else ( echo    ! 缺 bash，无法自动恢复 )
:rs_done

call :step "定时任务（任务计划程序）"
schtasks /query /tn HermesBrainDaily >nul 2>&1
if not errorlevel 1 ( echo    ~ 跳过：任务已存在 ) else (
    if exist "%SHELL%" (
        schtasks /create /f /tn HermesBrainDaily /sc daily /st 04:04 ^
          /tr "\"%SHELL%\" -lc \"cd '%CD%' ^&^& bash scripts/gbrain-daily.sh\""
        schtasks /create /f /tn HermesBrainBackup /sc weekly /d SUN /st 22:30 ^
          /tr "\"%SHELL%\" -lc \"cd '%CD%' ^&^& bash scripts/backup-daily.sh\""
        echo    ^> HermesBrainDaily（每日04:04）/ HermesBrainBackup（周日22:30）
    ) else ( echo    ! 缺 bash，定时任务请手动配置 )
)

call :step "Hermes Agent"
where hermes >nul 2>&1 && ( echo    ^> hermes 已安装 & goto :hn_done )
echo    Windows 推荐在 WSL2（Ubuntu）内安装 Hermes Agent：
echo      wsl --install -d ubuntu  然后在其内执行：
echo      curl -fsSL https://hermes-agent.nousresearch.com/install.sh ^| bash
:hn_done

echo.
echo ==============================================================
echo   完成 %STEP%/%TOTAL%。~ = 已存在被跳过。
echo   验证：
echo     docker exec %POSTGRES_CONTAINER% pg_isready -U postgres
echo     gbrain stats
echo     curl -s -o nul -w "%%{http_code}\n" localhost:1933/health   (401 即正常)
echo     schtasks /query /tn HermesBrainDaily
echo ==============================================================
endlocal
exit /b 0

:step
set /a STEP+=1
echo.
echo ==^> [%STEP%/%TOTAL%] %~1
exit /b 0
