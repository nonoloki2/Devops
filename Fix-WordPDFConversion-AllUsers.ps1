<#
.SYNOPSIS
    Corrige problema de itens sumindo na conversao Word -> PDF (barras de revisao, imagens, desenhos)
    apos upgrade do Windows 11 23H2 -> 25H2, para TODOS os usuarios da maquina.

.DESCRIPTION
    Desativa a aceleracao grafica de hardware no Microsoft Word (DisableHardwareAcceleration = 1),
    aplicando em DUAS camadas para garantir cobertura total:

      1) HKLM (Politica/GPO)  -> vale para qualquer usuario, mesmo que nunca tenha aberto o Word.
      2) HKCU de CADA perfil de usuario na maquina:
           - Usuarios com sessao ativa (hive ja carregado em HKEY_USERS)
           - Usuarios deslogados (carrega o NTUSER.DAT temporariamente, aplica, descarrega)

    Isso cobre tanto apps que respeitam a politica quanto os que só olham a chave de usuario,
    e funciona mesmo executado via sessao remota de PowerShell.

.NOTES
    - PRECISA ser executado como Administrador (local ou via sessao remota com credencial admin).
    - Perfis "de sistema" (Default, Public, All Users, systemprofile, LocalService, NetworkService)
      sao ignorados automaticamente.
#>

[CmdletBinding()]
param()

function Write-Status {
    param([string]$Mensagem, [string]$Cor = "Cyan")
    Write-Host $Mensagem -ForegroundColor $Cor
}

# --- 0. Checagem de privilegio de administrador ---------------------------
$ehAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $ehAdmin) {
    Write-Status "ERRO: este script precisa ser executado como Administrador. Abortando." "Red"
    return
}

Write-Status "=== Fix Word -> PDF (todos os usuarios) ===" "Yellow"

$versoesOffice = @("16.0", "15.0")  # 16.0 = 2016/2019/2021/2024/365 | 15.0 = 2013

# ---------------------------------------------------------------------------
# 1) Politica (HKLM) - cobre qualquer usuario, mesmo sem perfil criado ainda
# ---------------------------------------------------------------------------
Write-Status "`n--- Aplicando politica (HKLM) ---" "Cyan"

foreach ($versao in $versoesOffice) {
    $caminhoPolicy = "HKLM:\SOFTWARE\Policies\Microsoft\Office\$versao\Word\Options"
    if (-not (Test-Path $caminhoPolicy)) {
        New-Item -Path $caminhoPolicy -Force | Out-Null
    }
    New-ItemProperty -Path $caminhoPolicy -Name "DisableHardwareAcceleration" `
        -PropertyType DWord -Value 1 -Force | Out-Null
    Write-Status "OK (Politica): Office $versao -> $caminhoPolicy" "Green"
}

# ---------------------------------------------------------------------------
# 2) HKCU de cada perfil de usuario da maquina
# ---------------------------------------------------------------------------
Write-Status "`n--- Aplicando em cada perfil de usuario (HKCU) ---" "Cyan"

# Perfis a ignorar (contas de sistema / templates)
$perfisIgnorar = @(
    "S-1-5-18", "S-1-5-19", "S-1-5-20"  # SYSTEM, LocalService, NetworkService
)
$nomesPastaIgnorar = @("Default", "Default User", "Public", "All Users")

# Le a lista oficial de perfis do registro (mais confiavel que so listar C:\Users)
$chaveProfileList = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList"
$perfis = Get-ChildItem $chaveProfileList | Where-Object {
    $_.PSChildName -notin $perfisIgnorar -and $_.PSChildName -notmatch "_Classes$"
}

$totalAplicados = 0
$totalIgnorados = 0

foreach ($perfil in $perfis) {

    $sid = $perfil.PSChildName
    $propriedades = Get-ItemProperty -Path $perfil.PSPath -ErrorAction SilentlyContinue
    $caminhoPerfil = $propriedades.ProfileImagePath

    if (-not $caminhoPerfil -or ($nomesPastaIgnorar | Where-Object { $caminhoPerfil -like "*\$_" })) {
        continue
    }

    $ntuserDat = Join-Path $caminhoPerfil "NTUSER.DAT"
    if (-not (Test-Path $ntuserDat)) {
        Write-Status "IGNORADO (sem NTUSER.DAT): $caminhoPerfil" "DarkGray"
        $totalIgnorados++
        continue
    }

    $hiveJaCarregada = Test-Path "Registry::HKEY_USERS\$sid"
    $hiveCarregadaAgora = $false

    try {
        if (-not $hiveJaCarregada) {
            # Usuario deslogado: carrega o hive temporariamente
            $resultado = reg.exe load "HKU\$sid" "$ntuserDat" 2>&1
            if ($LASTEXITCODE -ne 0) {
                Write-Status "FALHOU ao carregar hive de $caminhoPerfil : $resultado" "Red"
                $totalIgnorados++
                continue
            }
            $hiveCarregadaAgora = $true
        }

        foreach ($versao in $versoesOffice) {
            $caminhoBase = "Registry::HKEY_USERS\$sid\Software\Microsoft\Office\$versao\Word"
            $caminhoGraphics = "$caminhoBase\Graphics"

            if (-not (Test-Path $caminhoBase)) {
                New-Item -Path $caminhoBase -Force | Out-Null
            }
            if (-not (Test-Path $caminhoGraphics)) {
                New-Item -Path $caminhoGraphics -Force | Out-Null
            }

            New-ItemProperty -Path $caminhoGraphics -Name "DisableHardwareAcceleration" `
                -PropertyType DWord -Value 1 -Force | Out-Null
        }

        Write-Status "OK: $caminhoPerfil (SID $sid)" "Green"
        $totalAplicados++
    }
    catch {
        Write-Status "ERRO em $caminhoPerfil : $_" "Red"
        $totalIgnorados++
    }
    finally {
        if ($hiveCarregadaAgora) {
            # Precisa liberar handles do PowerShell antes de descarregar o hive
            [gc]::Collect()
            [gc]::WaitForPendingFinalizers()
            Start-Sleep -Milliseconds 500
            $resultado = reg.exe unload "HKU\$sid" 2>&1
            if ($LASTEXITCODE -ne 0) {
                Write-Status "AVISO: nao foi possivel descarregar hive de $caminhoPerfil automaticamente ($resultado). Pode ficar travado ate reiniciar." "Red"
            }
        }
    }
}

Write-Status "`n=== Resumo ===" "Yellow"
Write-Status "Perfis de usuario corrigidos: $totalAplicados" "Green"
if ($totalIgnorados -gt 0) {
    Write-Status "Perfis ignorados/com falha: $totalIgnorados" "Red"
}
Write-Status "`nConcluido. Usuarios com sessao ativa devem fechar COMPLETAMENTE o Word (confira no Gerenciador de Tarefas se nao ha WINWORD.EXE residual) e abrir novamente antes de testar a conversao." "Yellow"
