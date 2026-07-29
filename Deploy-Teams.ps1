<#
.SYNOPSIS
    Copia o instalador New Teams (MSIX) para uma máquina remota, remove qualquer
    instalação anterior do Teams (clássico ou novo) e instala a nova versão
    para TODOS os usuários da máquina.

.DESCRIPTION
    Fluxo:
      1. Testa conectividade WinRM com o host de destino.
      2. Copia MSTeams-x64.msix (mesma pasta do script, ou -SourcePath customizado)
         para C:\Temp no host remoto.
      3. No host remoto, tenta remover TODAS as formas conhecidas de instalação
         do Teams:
           a) Teams "clássico" (per-user, Update.exe) - todos os perfis
           b) Teams Machine-Wide Installer (MSI, instalação por máquina)
           c) New Teams (MSIX) - pacote AppX por usuário
           d) New Teams (MSIX) - pacote Provisionado (fica pré-instalado p/ novos usuários)
      4. Instala o novo MSIX como pacote provisionado (para todos os usuários,
         atuais e futuros).

.PARAMETER ComputerName
    Hostname ou IP da máquina de destino. Obrigatório.

.PARAMETER SourcePath
    Caminho local do MSTeams-x64.msix. Se omitido, assume que está na mesma
    pasta deste script.

.PARAMETER Credential
    Credencial com direitos administrativos na máquina remota. Se omitido,
    usa a sessão atual (precisa ter permissão administrativa no destino).

.EXAMPLE
    .\Deploy-Teams.ps1 -ComputerName PC01

.EXAMPLE
    .\Deploy-Teams.ps1 -ComputerName PC01 -SourcePath "C:\Instaladores\MSTeams-x64.msix" -Credential (Get-Credential)

.NOTES
    - Requer WinRM habilitado no host de destino (Enable-PSRemoting) e
      execução com privilégios administrativos.
    - O MSIX do New Teams normalmente não exige arquivo de licença separado
      para instalação via Add-AppxProvisionedPackage, mas isso pode variar
      conforme a build baixada da Microsoft. Se o comando de instalação
      falhar pedindo license, você precisará também do .xml de licença
      correspondente.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ComputerName,

    [Parameter(Mandatory = $false)]
    [string]$SourcePath = (Join-Path $PSScriptRoot "MSTeams-x64.msix"),

    [Parameter(Mandatory = $false)]
    [pscredential]$Credential
)

$ErrorActionPreference = "Stop"

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "[$ts][$Level] $Message"
}

# ------------------------------------------------------------------
# 0. Validações iniciais
# ------------------------------------------------------------------
if (-not (Test-Path -LiteralPath $SourcePath)) {
    throw "Arquivo de origem não encontrado: $SourcePath"
}

Write-Log "Testando conectividade WinRM com '$ComputerName'..."
$psParams = @{ ComputerName = $ComputerName }
if ($Credential) { $psParams["Credential"] = $Credential }

try {
    Test-WSMan @psParams | Out-Null
    Write-Log "WinRM OK."
}
catch {
    throw "Não foi possível conectar via WinRM em '$ComputerName'. Verifique se o WinRM está habilitado e se a máquina está acessível. Erro: $($_.Exception.Message)"
}

# ------------------------------------------------------------------
# 1. Copiar o instalador para C:\Temp no host remoto
# ------------------------------------------------------------------
$destShare = "\\$ComputerName\C$\Temp"
$fileName  = Split-Path -Leaf $SourcePath
$destFile  = Join-Path $destShare $fileName

Write-Log "Copiando '$SourcePath' para '$destShare'..."

try {
    if ($Credential) {
        # Se precisar autenticar no compartilhamento admin com outra credencial,
        # mapeia temporariamente uma unidade de rede.
        New-PSDrive -Name TeamsDeploy -PSProvider FileSystem -Root "\\$ComputerName\C$" -Credential $Credential -ErrorAction Stop | Out-Null
        $remoteTemp = "TeamsDeploy:\Temp"
        if (-not (Test-Path $remoteTemp)) {
            New-Item -Path $remoteTemp -ItemType Directory -Force | Out-Null
        }
        Copy-Item -Path $SourcePath -Destination $remoteTemp -Force
        Remove-PSDrive -Name TeamsDeploy -Force
    }
    else {
        if (-not (Test-Path $destShare)) {
            New-Item -Path $destShare -ItemType Directory -Force | Out-Null
        }
        Copy-Item -Path $SourcePath -Destination $destShare -Force
    }
    Write-Log "Cópia concluída: $destFile"
}
catch {
    throw "Falha ao copiar o arquivo para o host remoto. Erro: $($_.Exception.Message)"
}

# ------------------------------------------------------------------
# 2. Bloco remoto: desinstalar versões antigas + instalar a nova
# ------------------------------------------------------------------
$scriptBlock = {
    param($MsixPathRemote)

    $ErrorActionPreference = "Continue"

    function Write-RLog {
        param([string]$Message)
        $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        Write-Output "[$ts][REMOTO] $Message"
    }

    # ================================================================
    # 2a. Remover Teams "clássico" (per-user, instalação antiga baseada
    #     em Update.exe / Squirrel) para TODOS os perfis de usuário
    # ================================================================
    Write-RLog "Verificando instalações do Teams clássico (per-user)..."

    $userProfiles = Get-ChildItem "C:\Users" -Directory -ErrorAction SilentlyContinue

    foreach ($profile in $userProfiles) {
        $teamsPath  = Join-Path $profile.FullName "AppData\Local\Microsoft\Teams"
        $updateExe  = Join-Path $teamsPath "Update.exe"

        if (Test-Path $updateExe) {
            Write-RLog "Encontrado Teams clássico para o usuário '$($profile.Name)'. Desinstalando..."
            try {
                Start-Process -FilePath $updateExe -ArgumentList "--uninstall", "-s" -Wait -NoNewWindow
                Write-RLog "Desinstalação (Update.exe --uninstall -s) concluída para '$($profile.Name)'."
            }
            catch {
                Write-RLog "Falha ao desinstalar Teams clássico para '$($profile.Name)': $($_.Exception.Message)"
            }

            # Limpeza residual de pastas, caso o uninstall não remova tudo
            Start-Sleep -Seconds 2
            Remove-Item -Path $teamsPath -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    # ================================================================
    # 2b. Remover "Teams Machine-Wide Installer" (MSI, instalado por
    #     máquina, geralmente empurrado via GPO/Intune/SCCM antigamente)
    # ================================================================
    Write-RLog "Verificando 'Teams Machine-Wide Installer' (MSI)..."

    $machineWide = Get-Package -Name "Teams Machine-Wide Installer" -ErrorAction SilentlyContinue
    if (-not $machineWide) {
        # Fallback via registro, caso Get-Package não encontre
        $uninstallKeys = @(
            "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
            "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
        )
        $machineWideReg = Get-ItemProperty $uninstallKeys -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -like "Teams Machine-Wide Installer*" }

        foreach ($item in $machineWideReg) {
            Write-RLog "Encontrado via registro: $($item.DisplayName) ($($item.PSChildName))"
            try {
                Start-Process "msiexec.exe" -ArgumentList "/x $($item.PSChildName) /qn /norestart" -Wait
                Write-RLog "MSI removido: $($item.PSChildName)"
            }
            catch {
                Write-RLog "Falha ao remover MSI $($item.PSChildName): $($_.Exception.Message)"
            }
        }
    }
    else {
        foreach ($pkg in $machineWide) {
            Write-RLog "Removendo pacote MSI: $($pkg.Name)"
            try {
                $pkg | Uninstall-Package -Force -ErrorAction Stop
                Write-RLog "Removido com sucesso: $($pkg.Name)"
            }
            catch {
                Write-RLog "Falha ao remover via Uninstall-Package, tentando msiexec direto..."
                try {
                    $productCode = $pkg.FastPackageReference
                    Start-Process "msiexec.exe" -ArgumentList "/x $productCode /qn /norestart" -Wait
                }
                catch {
                    Write-RLog "Falha também via msiexec: $($_.Exception.Message)"
                }
            }
        }
    }

    # ================================================================
    # 2c. Remover New Teams (MSIX) - pacote instalado por usuário
    # ================================================================
    Write-RLog "Verificando New Teams (MSIX) instalado por usuário..."

    try {
        $appxPkgs = Get-AppxPackage -Name "MSTeams" -AllUsers -ErrorAction SilentlyContinue
        if ($appxPkgs) {
            foreach ($pkg in $appxPkgs) {
                Write-RLog "Removendo AppxPackage '$($pkg.PackageFullName)' do usuário associado..."
                try {
                    Remove-AppxPackage -Package $pkg.PackageFullName -AllUsers -ErrorAction Stop
                    Write-RLog "Removido: $($pkg.PackageFullName)"
                }
                catch {
                    Write-RLog "Falha ao remover $($pkg.PackageFullName): $($_.Exception.Message)"
                }
            }
        }
        else {
            Write-RLog "Nenhum New Teams (MSIX) por usuário encontrado."
        }
    }
    catch {
        Write-RLog "Erro ao consultar AppxPackage: $($_.Exception.Message)"
    }

    # ================================================================
    # 2d. Remover New Teams (MSIX) - pacote PROVISIONADO
    #     (fica disponível/pré-instalado para novos perfis de usuário)
    # ================================================================
    Write-RLog "Verificando New Teams (MSIX) provisionado..."

    try {
        $provisioned = Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -like "*MSTeams*" -or $_.DisplayName -like "*Teams*" }

        foreach ($prov in $provisioned) {
            Write-RLog "Removendo pacote provisionado '$($prov.PackageName)'..."
            try {
                Remove-AppxProvisionedPackage -Online -PackageName $prov.PackageName -ErrorAction Stop | Out-Null
                Write-RLog "Removido pacote provisionado: $($prov.PackageName)"
            }
            catch {
                Write-RLog "Falha ao remover pacote provisionado $($prov.PackageName): $($_.Exception.Message)"
            }
        }

        if (-not $provisioned) {
            Write-RLog "Nenhum pacote provisionado do Teams encontrado."
        }
    }
    catch {
        Write-RLog "Erro ao consultar pacotes provisionados: $($_.Exception.Message)"
    }

    # ================================================================
    # 2e. (Opcional/robusto) Se existir o teamsbootstrapper.exe na
    #     mesma pasta do MSIX, usar ele para desinstalar via -x é o
    #     método oficial recomendado pela Microsoft para o New Teams.
    #     Deixe o .exe ao lado do .msix em C:\Temp se quiser usar.
    # ================================================================
    $bootstrapper = Join-Path (Split-Path $MsixPathRemote -Parent) "teamsbootstrapper.exe"
    if (Test-Path $bootstrapper) {
        Write-RLog "Encontrado teamsbootstrapper.exe. Executando desinstalação oficial (-x)..."
        try {
            Start-Process -FilePath $bootstrapper -ArgumentList "-x" -Wait -NoNewWindow
            Write-RLog "teamsbootstrapper.exe -x concluído."
        }
        catch {
            Write-RLog "Falha ao executar teamsbootstrapper.exe -x: $($_.Exception.Message)"
        }
    }

    # ================================================================
    # 3. Instalar o novo MSIX para TODOS os usuários (provisionado)
    # ================================================================
    Write-RLog "Instalando novo pacote MSIX para todos os usuários: $MsixPathRemote"

    if (-not (Test-Path $MsixPathRemote)) {
        Write-RLog "ERRO: arquivo MSIX não encontrado em '$MsixPathRemote'. Abortando instalação."
        return
    }

    try {
        # Preferencial: se existir o bootstrapper, ele é o método
        # oficial (instala + registra corretamente por máquina).
        if (Test-Path $bootstrapper) {
            Write-RLog "Instalando via teamsbootstrapper.exe -p ..."
            Start-Process -FilePath $bootstrapper -ArgumentList "-p" -Wait -NoNewWindow
            Write-RLog "Instalação via bootstrapper concluída."
        }
        else {
            # Alternativa: DISM / Add-AppxProvisionedPackage instala o
            # pacote para todos os usuários (atuais e futuros).
            Write-RLog "Instalando via Add-AppxProvisionedPackage (DISM)..."
            Add-AppxProvisionedPackage -Online -PackagePath $MsixPathRemote -SkipLicense -ErrorAction Stop | Out-Null
            Write-RLog "Add-AppxProvisionedPackage concluído com sucesso."
        }
    }
    catch {
        Write-RLog "Falha na instalação: $($_.Exception.Message)"
        Write-RLog "Se o erro mencionar 'license', você precisa do arquivo de licença (.xml) correspondente ao MSIX e usar Add-AppxProvisionedPackage -PackagePath <msix> -LicensePath <licenca.xml> ao invés de -SkipLicense."
    }

    Write-RLog "Processo finalizado."
}

Write-Log "Executando bloco remoto em '$ComputerName'..."
try {
    $invokeParams = @{
        ComputerName = $ComputerName
        ScriptBlock  = $scriptBlock
        ArgumentList = $destFile
    }
    if ($Credential) { $invokeParams["Credential"] = $Credential }

    Invoke-Command @invokeParams
}
catch {
    throw "Falha ao executar o bloco remoto em '$ComputerName'. Erro: $($_.Exception.Message)"
}

Write-Log "Script concluído."
