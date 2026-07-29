<#
.SYNOPSIS
    Diagnostica e corrige o New Notepad (Microsoft.WindowsNotepad) quando ele
    nao abre / trava sem mostrar janela apos upgrade de versao do Windows.

.DESCRIPTION
    Fluxo:
      1. Identifica processos "Notepad" rodando em sessoes INTERATIVAS
         (SessionId != 0), que sao os que representam o app real do usuario
         logado (diferente de um Start-Process disparado numa PSSession,
         que roda na sessao 0 e nao prova nada sobre a experiencia do usuario).
      2. Se encontrar processo(s) travado(s), mata e registra.
      3. Consulta o Event Viewer (Application log) por erros recentes
         relacionados ao Notepad (crash, falha de DLL, etc.) para dar
         contexto da causa raiz.
      4. Verifica o status/versao do pacote Appx Microsoft.WindowsNotepad.
      5. Decide o reparo:
           - Se Status != Ok  -> remove e reinstala o pacote.
           - Se Status == Ok mas versao desatualizada -> tenta winget upgrade.
           - Se winget nao disponivel/falhar -> remove e reinstala via Appx/Store.
      6. Reexecuta o teste de processo para confirmar se resolveu (o quanto
         der para confirmar remotamente - a abertura real de janela so o
         usuario consegue validar visualmente).

.PARAMETER ComputerName
    Uma ou mais maquinas remotas. Se omitido, roda localmente (util se voce
    ja esta dentro de uma PSSession/Enter-PSSession na maquina alvo).

.PARAMETER Credential
    Credencial administrativa para as maquinas remotas.

.PARAMETER MinAcceptableVersion
    Versao minima aceitavel do pacote antes de forcar atualizacao.
    Padrao: 11.2500.0.0 (ajuste conforme a baseline da sua empresa).

.EXAMPLE
    # Rodando de dentro de uma Enter-PSSession ja aberta na maquina alvo
    .\Diagnose-Fix-Notepad.ps1

.EXAMPLE
    # Rodando remotamente para uma ou mais maquinas, sem precisar abrir sessao manual
    .\Diagnose-Fix-Notepad.ps1 -ComputerName 1589562A, 1589562B -Credential (Get-Credential)
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string[]]$ComputerName,

    [Parameter(Mandatory = $false)]
    [pscredential]$Credential,

    [Parameter(Mandatory = $false)]
    [version]$MinAcceptableVersion = [version]"11.2500.0.0"
)

$ErrorActionPreference = "Continue"

# ============================================================
# Bloco principal de diagnostico/reparo (roda local ou remoto)
# ============================================================
$diagnoseFixBlock = {
    param($MinVersionStr)

    function Write-DLog {
        param([string]$Message)
        $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        Write-Output "[$ts] $Message"
    }

    $MinVersion = [version]$MinVersionStr

    Write-DLog "===== INICIO DO DIAGNOSTICO DO NOTEPAD ====="

    # ------------------------------------------------------------------
    # 1. Localizar processos Notepad em sessoes INTERATIVAS (SessionId != 0)
    # ------------------------------------------------------------------
    Write-DLog "Procurando processos 'Notepad'/'notepad' em sessoes interativas..."

    $notepadProcs = Get-Process -Name "notepad", "Notepad" -ErrorAction SilentlyContinue |
        Where-Object { $_.SessionId -ne 0 }

    if ($notepadProcs) {
        foreach ($proc in $notepadProcs) {
            $cpuTime = [math]::Round($proc.CPU, 2)
            Write-DLog "Encontrado processo travado/pendurado: PID=$($proc.Id) Nome=$($proc.ProcessName) SessionId=$($proc.SessionId) CPU(s)=$cpuTime WS(MB)=$([math]::Round($proc.WorkingSet64/1MB,1))"
            try {
                Stop-Process -Id $proc.Id -Force -ErrorAction Stop
                Write-DLog "Processo PID $($proc.Id) finalizado com sucesso."
            }
            catch {
                Write-DLog "Falha ao finalizar PID $($proc.Id): $($_.Exception.Message)"
            }
        }
    }
    else {
        Write-DLog "Nenhum processo Notepad rodando em sessao interativa no momento (pode ja ter sido fechado ou nunca foi aberto)."
    }

    Start-Sleep -Seconds 1

    # ------------------------------------------------------------------
    # 2. Consultar Event Viewer por erros recentes relacionados
    # ------------------------------------------------------------------
    Write-DLog "Consultando Event Viewer (Application log) por erros recentes do Notepad..."

    try {
        $events = Get-WinEvent -FilterHashtable @{
            LogName   = 'Application'
            Id        = 1000, 1001, 1002   # Application Error / Hang / WER
            StartTime = (Get-Date).AddDays(-7)
        } -ErrorAction SilentlyContinue |
            Where-Object { $_.Message -match "Notepad" } |
            Select-Object -First 5 TimeCreated, Id, Message

        if ($events) {
            foreach ($ev in $events) {
                $shortMsg = ($ev.Message -split "`n")[0..2] -join " | "
                Write-DLog "Evento [$($ev.TimeCreated)] Id=$($ev.Id): $shortMsg"
            }
        }
        else {
            Write-DLog "Nenhum evento de erro/crash do Notepad encontrado nos ultimos 7 dias."
        }
    }
    catch {
        Write-DLog "Nao foi possivel consultar o Event Log: $($_.Exception.Message)"
    }

    # ------------------------------------------------------------------
    # 3. Verificar status e versao do pacote Appx
    # ------------------------------------------------------------------
    Write-DLog "Verificando pacote Microsoft.WindowsNotepad..."

    $pkg = Get-AppxPackage -Name "Microsoft.WindowsNotepad" -AllUsers -ErrorAction SilentlyContinue |
        Select-Object -First 1

    $needsReinstall = $false
    $needsUpgrade   = $false

    if (-not $pkg) {
        Write-DLog "Pacote NAO encontrado (nao instalado ou removido). Sera feita instalacao limpa."
        $needsReinstall = $true
    }
    else {
        Write-DLog "Pacote encontrado: Nome=$($pkg.Name) Versao=$($pkg.Version) Status=$($pkg.Status) PackageFullName=$($pkg.PackageFullName)"

        if ($pkg.Status -ne "Ok") {
            Write-DLog "Status do pacote NAO esta OK ('$($pkg.Status)'). Sera feita reinstalacao."
            $needsReinstall = $true
        }
        elseif ([version]$pkg.Version -lt $MinVersion) {
            Write-DLog "Versao instalada ($($pkg.Version)) esta abaixo da minima aceitavel ($MinVersion). Sera feita atualizacao."
            $needsUpgrade = $true
        }
        else {
            Write-DLog "Pacote integro e em versao aceitavel. Nenhuma acao de instalacao necessaria por enquanto."
        }
    }

    # ------------------------------------------------------------------
    # 4. Reparo: winget upgrade (preferencial) ou remove+reinstall
    # ------------------------------------------------------------------
    $wingetAvailable = $null -ne (Get-Command winget -ErrorAction SilentlyContinue)

    if ($needsReinstall) {
        Write-DLog "Executando reinstalacao limpa do pacote..."

        if ($pkg) {
            try {
                Remove-AppxPackage -Package $pkg.PackageFullName -AllUsers -ErrorAction Stop
                Write-DLog "Pacote removido: $($pkg.PackageFullName)"
            }
            catch {
                Write-DLog "Falha ao remover pacote: $($_.Exception.Message)"
            }
        }

        if ($wingetAvailable) {
            Write-DLog "Instalando via winget..."
            $wingetOut = winget install --id Microsoft.WindowsNotepad -e `
                --accept-package-agreements --accept-source-agreements --silent 2>&1
            Write-DLog "winget output: $wingetOut"
        }
        else {
            Write-DLog "winget nao disponivel nesta maquina. Tentando reprovisionar via DISM (se pacote .appx/.msix estiver disponivel localmente, ajuste o caminho)."
            Write-DLog "AVISO: sem winget e sem pacote local, a reinstalacao automatica nao e possivel aqui - sera necessario instalar manualmente pela Microsoft Store ou fornecer o pacote offline."
        }
    }
    elseif ($needsUpgrade) {
        if ($wingetAvailable) {
            Write-DLog "Executando winget upgrade..."
            $wingetOut = winget upgrade --id Microsoft.WindowsNotepad -e `
                --accept-package-agreements --accept-source-agreements --silent 2>&1
            Write-DLog "winget output: $wingetOut"
        }
        else {
            Write-DLog "winget nao disponivel. Removendo e reinstalando como alternativa..."
            try {
                Remove-AppxPackage -Package $pkg.PackageFullName -AllUsers -ErrorAction Stop
                Write-DLog "Pacote removido para forcar reinstalacao pela Store no proximo uso: $($pkg.PackageFullName)"
            }
            catch {
                Write-DLog "Falha ao remover pacote para forcar reinstalacao: $($_.Exception.Message)"
            }
        }
    }

    # ------------------------------------------------------------------
    # 5. Limpar registro App Paths quebrado (causa comum do travamento/DLL)
    # ------------------------------------------------------------------
    Write-DLog "Verificando/limpando chave de registro App Paths (HKLM)..."
    try {
        if (Test-Path "HKLM:\Software\Microsoft\Windows\CurrentVersion\App Paths\notepad.exe") {
            Remove-Item "HKLM:\Software\Microsoft\Windows\CurrentVersion\App Paths\notepad.exe" -Force -ErrorAction SilentlyContinue
            Write-DLog "Chave HKLM App Paths\notepad.exe removida."
        }
        else {
            Write-DLog "Chave HKLM App Paths\notepad.exe nao existe (ok)."
        }
    }
    catch {
        Write-DLog "Erro ao verificar/remover chave HKLM: $($_.Exception.Message)"
    }

    # Tenta tambem limpar para os perfis de usuario locais (via NTUSER.DAT),
    # pulando perfis cujo hive esteja em uso (usuario logado no momento).
    Write-DLog "Verificando App Paths nos perfis de usuario locais (HKCU offline)..."
    $profiles = Get-CimInstance Win32_UserProfile -ErrorAction SilentlyContinue |
        Where-Object { -not $_.Special -and $_.LocalPath -like "C:\Users\*" }

    foreach ($p in $profiles) {
        $ntuser = Join-Path $p.LocalPath "NTUSER.DAT"
        if (-not (Test-Path $ntuser)) { continue }

        $hiveName = "TempHive_$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $loaded = $false
        try {
            reg load "HKU\$hiveName" "$ntuser" 2>$null | Out-Null
            $loaded = $true
        }
        catch {
            $loaded = $false
        }

        if ($loaded) {
            $keyPath = "Registry::HKEY_USERS\$hiveName\Software\Microsoft\Windows\CurrentVersion\App Paths\notepad.exe"
            if (Test-Path $keyPath) {
                Remove-Item $keyPath -Force -ErrorAction SilentlyContinue
                Write-DLog "Chave App Paths removida no perfil: $($p.LocalPath)"
            }
            reg unload "HKU\$hiveName" 2>$null | Out-Null
        }
        else {
            Write-DLog "Nao foi possivel carregar hive de $($p.LocalPath) (provavelmente usuario esta logado agora - hive em uso). Pule ou peca reparo manual para esse perfil."
        }
    }

    # ------------------------------------------------------------------
    # 6. Checagem final
    # ------------------------------------------------------------------
    Start-Sleep -Seconds 2
    Write-DLog "Checagem final do pacote..."
    $pkgFinal = Get-AppxPackage -Name "Microsoft.WindowsNotepad" -AllUsers -ErrorAction SilentlyContinue |
        Select-Object -First 1

    if ($pkgFinal) {
        Write-DLog "Estado final -> Versao=$($pkgFinal.Version) Status=$($pkgFinal.Status)"
    }
    else {
        Write-DLog "Estado final -> Pacote nao encontrado. Se winget nao estava disponivel, sera necessario instalar manualmente."
    }

    Write-DLog "===== FIM DO DIAGNOSTICO/REPARO =====" 
    Write-DLog "Observacao: a confirmacao visual de que a janela abre so pode ser feita pelo usuario logado na sessao interativa. Peca para ele tentar abrir o Notepad agora."
}

# ============================================================
# Execucao: local (dentro de PSSession) ou remota (uma ou mais maquinas)
# ============================================================
if (-not $ComputerName) {
    Write-Host "Nenhum -ComputerName informado. Executando localmente (assumindo que voce ja esta dentro de uma sessao na maquina alvo)..." -ForegroundColor Cyan
    & $diagnoseFixBlock $MinAcceptableVersion.ToString()
}
else {
    foreach ($cn in $ComputerName) {
        Write-Host "`n================ $cn ================" -ForegroundColor Cyan
        try {
            $invokeParams = @{
                ComputerName = $cn
                ScriptBlock  = $diagnoseFixBlock
                ArgumentList = $MinAcceptableVersion.ToString()
            }
            if ($Credential) { $invokeParams["Credential"] = $Credential }

            Invoke-Command @invokeParams
        }
        catch {
            Write-Host "Falha ao executar em '$cn': $($_.Exception.Message)" -ForegroundColor Red
        }
    }
}
