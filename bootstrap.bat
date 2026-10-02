@echo off
chcp 65001 >nul
setlocal
REM ===================================================================
REM  bootstrap.bat — Windows 本机一键部署到 VPS
REM  双击运行：填 IP、root 密码，回车即可。脚本会自动装 paramiko、
REM  把 node-deploy 推上去执行，并把链接拉回 links\ 目录。
REM ===================================================================

cd /d "%~dp0"

echo.
echo   node-deploy  -  Windows 一键部署
echo   --------------------------------
echo.

set /p HOST=目标 IP :
if "%HOST%"=="" ( echo 未输入 IP & pause & exit /b 1 )

set /p SSHPASS=root 密码 :
if "%SSHPASS%"=="" ( echo 未输入密码 & pause & exit /b 1 )

set /p PROFILE=部署内容 [all/vless/hy2/socks5/tune] (默认 all) :
if "%PROFILE%"=="" set PROFILE=all

set /p PORT=VLESS 端口 (默认 443) :
if "%PORT%"=="" set PORT=443

set /p SNI=伪装域名 (默认 www.cloudflare.com) :
if "%SNI%"=="" set SNI=www.cloudflare.com

set /p ENG=核心 [xray/singbox] (默认 xray) :
if "%ENG%"=="" set ENG=xray

set PY=
where py >nul 2>nul && set PY=py
if "%PY%"=="" ( where python >nul 2>nul && set PY=python )
if "%PY%"=="" ( echo 未找到 Python，请先安装 https://www.python.org/downloads/ & pause & exit /b 1 )

echo.
echo   [*] 检查 paramiko ...
%PY% -c "import paramiko" >nul 2>nul || (
  echo   [*] 安装 paramiko ...
  %PY% -m pip install --quiet paramiko
)

echo.
echo   [*] 部署到 %HOST% ...
%PY% tools\deploy_remote.py --host root:%SSHPASS%@%HOST% --profile %PROFILE% --engine %ENG% --port %PORT% --sni %SNI% --yes

echo.
echo   [*] 完成。链接已保存到 links\
pause
