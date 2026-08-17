@echo off
REM ============================================================
REM  Iniciar Gerenciador Remoto de Software
REM  Execute este arquivo como Administrador
REM  (botao direito > Executar como administrador)
REM ============================================================

setlocal
set SCRIPT_DIR=%~dp0
set SCRIPT_PATH=%SCRIPT_DIR%RemoteSoftwareManager.ps1

if not exist "%SCRIPT_PATH%" (
    echo Nao foi possivel encontrar RemoteSoftwareManager.ps1 na mesma pasta deste .bat.
    echo Certifique-se de que os dois arquivos estao juntos.
    pause
    exit /b 1
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%SCRIPT_PATH%"

endlocal
