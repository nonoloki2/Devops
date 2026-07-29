<#
.SYNOPSIS
    Habilita o WinRM (Windows Remote Management) nas máquinas, para implantação via SCCM
    (como Script, Pacote/Programa ou Aplicação/Baseline).

.DESCRIPTION
    - Inicia e configura o serviço WinRM para inicialização automática
    - Habilita o PS Remoting (Enable-PSRemoting)
    - Cria/valida o listener HTTP (porta 5985)
    - Ajusta o firewall do Windows para permitir WinRM (Domain/Private)
    - Registra log local para auditoria/troubleshooting
    - Retorna código de saída (0 = sucesso, != 0 = falha) para o SCCM avaliar
    - Idempotente: pode ser executado múltiplas vezes sem causar erro

.NOTES
    Executar como SYSTEM (contexto padrão do SCCM) ou com privilégios administrativos.
    Compatível com Windows 10/11 e Windows Server 2012 R2+.
#>

[CmdletBinding()]
param(
    [switch]$HabilitarHTTPS  # Opcional: cria listener HTTPS (requer certificado já instalado)
)

# ------------------------------------------------------------------
# Configuração de log
# ------------------------------------------------------------------
$LogDir  = "$env:ProgramData\SCCM_Scripts\WinRM"
$LogFile = Join-Path $LogDir "Habilitar-WinRM_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

if (-not (Test-Path $LogDir)) {
    New-Item -Path $LogDir -ItemType Directory -Force | Out-Null
}

function Write-Log {
    param([string]$Mensagem, [string]$Nivel = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $linha = "[$timestamp] [$Nivel] $Mensagem"
    Write-Output $linha
    Add-Content -Path $LogFile -Value $linha
}

$ExitCode = 0

try {
    Write-Log "===== Iniciando habilitação do WinRM ====="
    Write-Log "Host: $env:COMPUTERNAME | Usuário de execução: $env:USERNAME"

    # ------------------------------------------------------------------
    # 1. Verificar/definir o tipo de inicialização do serviço WinRM
    # ------------------------------------------------------------------
    Write-Log "Configurando serviço WinRM para inicialização automática..."
    Set-Service -Name WinRM -StartupType Automatic -ErrorAction Stop

    $servico = Get-Service -Name WinRM
    if ($servico.Status -ne 'Running') {
        Write-Log "Iniciando serviço WinRM..."
        Start-Service -Name WinRM -ErrorAction Stop
    } else {
        Write-Log "Serviço WinRM já está em execução."
    }

    # ------------------------------------------------------------------
    # 2. Habilitar o PS Remoting (configura listener, firewall, LocalAccountTokenFilterPolicy)
    # ------------------------------------------------------------------
    Write-Log "Executando Enable-PSRemoting..."
    Enable-PSRemoting -Force -SkipNetworkProfileCheck -ErrorAction Stop
    Write-Log "Enable-PSRemoting concluído com sucesso."

    # ------------------------------------------------------------------
    # 3. Garantir que o listener HTTP (5985) está configurado
    # ------------------------------------------------------------------
    $listenerHTTP = winrm enumerate winrm/config/Listener 2>$null | Select-String "Transport = HTTP"
    if (-not $listenerHTTP) {
        Write-Log "Listener HTTP não encontrado. Criando..."
        winrm quickconfig -quiet | Out-Null
    } else {
        Write-Log "Listener HTTP já configurado."
    }

    # ------------------------------------------------------------------
    # 4. Regras de Firewall (Domínio e Privado). Ajuste conforme sua política.
    # ------------------------------------------------------------------
    Write-Log "Validando regras de firewall para WinRM..."
    $regras = Get-NetFirewallRule -DisplayName "Windows Remote Management*" -ErrorAction SilentlyContinue

    if ($regras) {
        Enable-NetFirewallRule -DisplayName "Windows Remote Management*" -ErrorAction SilentlyContinue
        Write-Log "Regras de firewall do WinRM habilitadas."
    } else {
        Write-Log "Regras de firewall padrão do WinRM não encontradas (podem já ter sido criadas pelo Enable-PSRemoting)." "WARN"
    }

    # ------------------------------------------------------------------
    # 5. (Opcional) Listener HTTPS
    # ------------------------------------------------------------------
    if ($HabilitarHTTPS) {
        Write-Log "Parâmetro -HabilitarHTTPS informado. Verificando listener HTTPS..."
        $listenerHTTPS = winrm enumerate winrm/config/Listener 2>$null | Select-String "Transport = HTTPS"

        if (-not $listenerHTTPS) {
            $cert = Get-ChildItem -Path Cert:\LocalMachine\My |
                    Where-Object { $_.Subject -match $env:COMPUTERNAME } |
                    Sort-Object NotAfter -Descending |
                    Select-Object -First 1

            if ($cert) {
                $thumbprint = $cert.Thumbprint
                Write-Log "Certificado encontrado (Thumbprint: $thumbprint). Criando listener HTTPS..."
                winrm create winrm/config/Listener?Address=*+Transport=HTTPS "@{Hostname=`"$env:COMPUTERNAME`";CertificateThumbprint=`"$thumbprint`"}" | Out-Null
                New-NetFirewallRule -DisplayName "Windows Remote Management (HTTPS-In)" `
                    -Direction Inbound -Protocol TCP -LocalPort 5986 -Action Allow -ErrorAction SilentlyContinue | Out-Null
                Write-Log "Listener HTTPS criado com sucesso."
            } else {
                Write-Log "Nenhum certificado adequado encontrado em Cert:\LocalMachine\My. Listener HTTPS não configurado." "WARN"
            }
        } else {
            Write-Log "Listener HTTPS já configurado."
        }
    }

    # ------------------------------------------------------------------
    # 6. Validação final
    # ------------------------------------------------------------------
    $servicoFinal = Get-Service -Name WinRM
    if ($servicoFinal.Status -eq 'Running') {
        Write-Log "Validação final: serviço WinRM em execução. Configuração concluída com sucesso."
    } else {
        throw "Serviço WinRM não está em execução após a configuração."
    }

    Write-Log "===== Habilitação do WinRM concluída com sucesso ====="
}
catch {
    Write-Log "ERRO: $($_.Exception.Message)" "ERROR"
    $ExitCode = 1
}
finally {
    Write-Log "Código de saída: $ExitCode"
}

exit $ExitCode
