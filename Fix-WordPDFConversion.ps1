<#
.SYNOPSIS
    Corrige problema de itens sumindo na conversao Word -> PDF (barras de revisao, imagens, desenhos)
    apos upgrade do Windows 11 23H2 -> 25H2.

.DESCRIPTION
    Desativa a aceleracao grafica de hardware no Microsoft Word via registro (equivalente a
    Arquivo > Opcoes > Avancado > Exibir > "Desativar aceleracao grafica de hardware").
    Detecta automaticamente a(s) versao(oes) de Office instalada(s) no perfil do usuario atual.

.NOTES
    - Executa no contexto do USUARIO ATUAL (HKCU). Rode o script logado com o usuario que
      apresenta o problema (nao precisa ser Administrador para esta parte).
    - Se quiser aplicar para TODOS os usuarios da maquina, use a secao opcional de Politica (GPO)
      mais abaixo, que grava em HKLM e requer execucao como Administrador.
#>

[CmdletBinding()]
param(
    [switch]$AplicarParaTodosUsuarios  # usa chave de politica (HKLM) alem da HKCU
)

function Write-Status {
    param([string]$Mensagem, [string]$Cor = "Cyan")
    Write-Host $Mensagem -ForegroundColor $Cor
}

Write-Status "=== Fix Word -> PDF (aceleracao grafica de hardware) ===" "Yellow"

# Versoes de Office/Word conhecidas (chave numerica de versao)
# 16.0 = Office 2016 / 2019 / 2021 / 2024 / Microsoft 365
# 15.0 = Office 2013
$versoesOffice = @("16.0", "15.0")

$algumaAplicada = $false

foreach ($versao in $versoesOffice) {

    $caminhoBase = "HKCU:\Software\Microsoft\Office\$versao\Word"
    $caminhoGraphics = "$caminhoBase\Graphics"

    # Só mexe se o Word dessa versão estiver de fato instalado/configurado no perfil
    if (Test-Path $caminhoBase) {

        if (-not (Test-Path $caminhoGraphics)) {
            New-Item -Path $caminhoGraphics -Force | Out-Null
        }

        # DisableHardwareAcceleration = 1 -> desativa aceleracao grafica de hardware
        New-ItemProperty -Path $caminhoGraphics -Name "DisableHardwareAcceleration" `
            -PropertyType DWord -Value 1 -Force | Out-Null

        Write-Status "OK: Aceleracao grafica desativada para Office $versao ($caminhoGraphics)" "Green"
        $algumaAplicada = $true
    }
}

if (-not $algumaAplicada) {
    Write-Status "Nenhuma instalacao de Office (16.0/15.0) encontrada em HKCU para este usuario." "Red"
}

# ---------------------------------------------------------------------------
# OPCIONAL: aplicar via chave de Politica (Group Policy), valendo para todos
# os usuarios que logarem na maquina. Requer execucao como Administrador.
# ---------------------------------------------------------------------------
if ($AplicarParaTodosUsuarios) {

    if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Status "AVISO: para aplicar a politica global (-AplicarParaTodosUsuarios), rode o PowerShell como Administrador." "Red"
    } else {
        foreach ($versao in $versoesOffice) {
            $caminhoPolicy = "HKLM:\SOFTWARE\Policies\Microsoft\Office\$versao\Word\Options"

            if (-not (Test-Path $caminhoPolicy)) {
                New-Item -Path $caminhoPolicy -Force | Out-Null
            }

            New-ItemProperty -Path $caminhoPolicy -Name "DisableHardwareAcceleration" `
                -PropertyType DWord -Value 1 -Force | Out-Null

            Write-Status "OK (Politica/HKLM): Office $versao -> $caminhoPolicy" "Green"
        }
    }
}

Write-Status "`nConcluido. Feche COMPLETAMENTE o Word (verifique no Gerenciador de Tarefas se nao ha processo WINWORD.EXE residual) e abra novamente antes de testar a conversao." "Yellow"
