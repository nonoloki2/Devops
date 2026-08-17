<#
.SYNOPSIS
    Gerenciador Remoto de Software - GUI em PowerShell (Windows Forms)

.DESCRIPTION
    Conecta remotamente (WinRM/Invoke-Command) a uma maquina Windows, lista os
    programas instalados (equivalente ao "Programas e Recursos" do Painel de
    Controle) e permite:
        - Desinstalar
        - Reparar (MSI)
        - Instalar/Atualizar para a ultima versao via winget
        - Reinstalar (desinstala + baixa e instala a versao mais recente)
        - Instalar um pacote a partir de um instalador local (pasta "source"),
          copiando-o para a maquina remota e executando de forma silenciosa
          com os parametros que voce definir

.REQUISITOS NA MAQUINA REMOTA
    - WinRM habilitado:  Enable-PSRemoting -Force
    - Usuario com privilegios administrativos no computador remoto
    - Winget instalado (necessario apenas para instalar/atualizar/reinstalar)
    - PowerShell 5.1 ou superior

.OBSERVACOES IMPORTANTES
    - "Reparar" so funciona de forma confiavel para pacotes MSI (msiexec /f).
      Para instaladores EXE proprietarios, o reparo depende do proprio
      instalador suportar esse parametro; nesses casos o script tenta acionar
      novamente o instalador silenciosamente.
    - "Instalar ultima versao" usa o winget, que mantem um catalogo de
      instaladores atualizados. Nao existe forma generica de "adivinhar" a URL
      de download mais recente de qualquer software sem usar um gerenciador
      de pacotes como o winget.
    - Executar winget remotamente via Invoke-Command pode exigir que o
      winget esteja configurado para rodar no contexto de servico
      (dependendo da build do Windows). Se winget nao responder remotamente,
      considere usar PowerShell Remoting com "-ComputerName" a partir de uma
      sessao interativa (RDP) como alternativa.
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ---------------------------------------------------------------------------
# ESTADO GLOBAL
# ---------------------------------------------------------------------------
$script:Session = $null
$script:ComputerName = $null

# ---------------------------------------------------------------------------
# FUNCOES DE APOIO (executadas remotamente via Invoke-Command)
# ---------------------------------------------------------------------------

function Get-InstalledSoftwareRemote {
    param($Session)

    Invoke-Command -Session $Session -ScriptBlock {
        $paths = @(
            'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
        )

        Get-ItemProperty -Path $paths -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -and -not $_.SystemComponent } |
            Select-Object `
                @{N='Nome';E={$_.DisplayName}},
                @{N='Versao';E={$_.DisplayVersion}},
                @{N='Publisher';E={$_.Publisher}},
                @{N='DataInstalacao';E={$_.InstallDate}},
                @{N='UninstallString';E={$_.UninstallString}},
                @{N='QuietUninstallString';E={$_.QuietUninstallString}},
                @{N='PSChildName';E={$_.PSChildName}} |
            Sort-Object Nome
    }
}

function Invoke-RemoteUninstall {
    param($Session, $Item)

    Invoke-Command -Session $Session -ArgumentList $Item -ScriptBlock {
        param($it)

        $cmd = if ($it.QuietUninstallString) { $it.QuietUninstallString } else { $it.UninstallString }
        if (-not $cmd) { return "SEM_STRING_DESINSTALACAO" }

        try {
            if ($cmd -match 'msiexec') {
                # Extrai o GUID do produto, se existir
                if ($it.PSChildName -match '^\{.*\}$') {
                    Start-Process msiexec.exe -ArgumentList "/x $($it.PSChildName) /qn /norestart" -Wait
                } else {
                    Start-Process cmd.exe -ArgumentList "/c $cmd /qn /norestart" -Wait
                }
            } else {
                # Instaladores EXE genericos: tenta modo silencioso comum
                Start-Process cmd.exe -ArgumentList "/c $cmd /S /silent /verysilent" -Wait
            }
            return "OK"
        } catch {
            return "ERRO: $($_.Exception.Message)"
        }
    }
}

function Invoke-RemoteRepair {
    param($Session, $Item)

    Invoke-Command -Session $Session -ArgumentList $Item -ScriptBlock {
        param($it)

        if ($it.PSChildName -match '^\{.*\}$') {
            try {
                Start-Process msiexec.exe -ArgumentList "/fa $($it.PSChildName) /qn /norestart" -Wait
                return "OK"
            } catch {
                return "ERRO: $($_.Exception.Message)"
            }
        } else {
            return "NAO_SUPORTADO: reparo automatico so disponivel para pacotes MSI"
        }
    }
}

function Invoke-RemoteInstallFromFile {
    param($Session, $LocalPath, $Args)

    $fileName = Split-Path $LocalPath -Leaf
    $remoteTempDir = "C:\Windows\Temp\RemoteSoftwareManager"
    $remotePath = Join-Path $remoteTempDir $fileName

    try {
        # Cria a pasta temporaria remota, se nao existir
        Invoke-Command -Session $Session -ArgumentList $remoteTempDir -ScriptBlock {
            param($dir)
            if (-not (Test-Path $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
        }

        # Copia o instalador do disco local para a maquina remota atraves da sessao
        Copy-Item -Path $LocalPath -Destination $remotePath -ToSession $Session -Force

        # Executa o instalador remotamente, de forma silenciosa, com os args informados
        $resultado = Invoke-Command -Session $Session -ArgumentList $remotePath, $Args -ScriptBlock {
            param($path, $installArgs)
            try {
                if ([string]::IsNullOrWhiteSpace($installArgs)) {
                    $proc = Start-Process -FilePath $path -Wait -PassThru
                } else {
                    $proc = Start-Process -FilePath $path -ArgumentList $installArgs -Wait -PassThru
                }
                return "OK (ExitCode: $($proc.ExitCode))"
            } catch {
                return "ERRO: $($_.Exception.Message)"
            }
        }

        return $resultado
    } catch {
        return "ERRO_COPIA: $($_.Exception.Message)"
    }
}

function Invoke-RemoteWingetAction {
    param($Session, $NomePrograma, $Acao)  # Acao: 'install' ou 'upgrade'

    Invoke-Command -Session $Session -ArgumentList $NomePrograma, $Acao -ScriptBlock {
        param($nome, $acao)

        if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
            return "WINGET_NAO_ENCONTRADO"
        }

        # Procura o ID exato no winget pelo nome do software
        $busca = winget search --name "$nome" --accept-source-agreements | Out-String
        if (-not $busca) { return "NAO_ENCONTRADO_NO_WINGET" }

        try {
            $resultado = winget $acao --name "$nome" --accept-package-agreements --accept-source-agreements --silent 2>&1 | Out-String
            return "OK`n$resultado"
        } catch {
            return "ERRO: $($_.Exception.Message)"
        }
    }
}

# ---------------------------------------------------------------------------
# INTERFACE GRAFICA
# ---------------------------------------------------------------------------

$form = New-Object System.Windows.Forms.Form
$form.Text = "Gerenciador Remoto de Software"
$form.Size = New-Object System.Drawing.Size(1050, 760)
$form.StartPosition = "CenterScreen"
$form.MinimumSize = $form.Size

# --- Painel de conexao ---
$lblComputer = New-Object System.Windows.Forms.Label
$lblComputer.Text = "Computador remoto:"
$lblComputer.Location = New-Object System.Drawing.Point(10, 15)
$lblComputer.AutoSize = $true

$txtComputer = New-Object System.Windows.Forms.TextBox
$txtComputer.Location = New-Object System.Drawing.Point(140, 12)
$txtComputer.Size = New-Object System.Drawing.Size(200, 20)

$btnConnect = New-Object System.Windows.Forms.Button
$btnConnect.Text = "Conectar"
$btnConnect.Location = New-Object System.Drawing.Point(350, 10)
$btnConnect.Size = New-Object System.Drawing.Size(90, 25)

$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Text = "Status: desconectado"
$lblStatus.Location = New-Object System.Drawing.Point(460, 15)
$lblStatus.AutoSize = $true
$lblStatus.ForeColor = [System.Drawing.Color]::Red

$btnRefresh = New-Object System.Windows.Forms.Button
$btnRefresh.Text = "Atualizar lista"
$btnRefresh.Location = New-Object System.Drawing.Point(900, 10)
$btnRefresh.Size = New-Object System.Drawing.Size(120, 25)
$btnRefresh.Enabled = $false

$form.Controls.AddRange(@($lblComputer, $txtComputer, $btnConnect, $lblStatus, $btnRefresh))

# --- Grid de programas ---
$grid = New-Object System.Windows.Forms.DataGridView
$grid.Location = New-Object System.Drawing.Point(10, 50)
$grid.Size = New-Object System.Drawing.Size(1010, 400)
$grid.Anchor = "Top,Bottom,Left,Right"
$grid.ReadOnly = $true
$grid.SelectionMode = "FullRowSelect"
$grid.MultiSelect = $false
$grid.AutoSizeColumnsMode = "Fill"
$grid.AllowUserToAddRows = $false
$form.Controls.Add($grid)

# --- Botoes de acao ---
$btnUninstall = New-Object System.Windows.Forms.Button
$btnUninstall.Text = "Desinstalar"
$btnUninstall.Location = New-Object System.Drawing.Point(10, 460)
$btnUninstall.Size = New-Object System.Drawing.Size(130, 30)
$btnUninstall.Anchor = "Top,Left"
$btnUninstall.Enabled = $false

$btnRepair = New-Object System.Windows.Forms.Button
$btnRepair.Text = "Reparar"
$btnRepair.Location = New-Object System.Drawing.Point(150, 460)
$btnRepair.Size = New-Object System.Drawing.Size(130, 30)
$btnRepair.Anchor = "Top,Left"
$btnRepair.Enabled = $false

$btnInstallLatest = New-Object System.Windows.Forms.Button
$btnInstallLatest.Text = "Instalar/Atualizar ultima versao"
$btnInstallLatest.Location = New-Object System.Drawing.Point(290, 460)
$btnInstallLatest.Size = New-Object System.Drawing.Size(220, 30)
$btnInstallLatest.Anchor = "Top,Left"
$btnInstallLatest.Enabled = $false

$btnReinstall = New-Object System.Windows.Forms.Button
$btnReinstall.Text = "Reinstalar (desinstalar + baixar novamente)"
$btnReinstall.Location = New-Object System.Drawing.Point(520, 460)
$btnReinstall.Size = New-Object System.Drawing.Size(280, 30)
$btnReinstall.Anchor = "Top,Left"
$btnReinstall.Enabled = $false

$form.Controls.AddRange(@($btnUninstall, $btnRepair, $btnInstallLatest, $btnReinstall))

# --- Separador visual ---
$lblSourceGroup = New-Object System.Windows.Forms.Label
$lblSourceGroup.Text = "Instalar pacote a partir de instalador local (pasta source):"
$lblSourceGroup.Location = New-Object System.Drawing.Point(10, 505)
$lblSourceGroup.AutoSize = $true
$lblSourceGroup.Font = New-Object System.Drawing.Font($lblSourceGroup.Font, [System.Drawing.FontStyle]::Bold)
$form.Controls.Add($lblSourceGroup)

# --- Linha: selecionar arquivo instalador local ---
$lblSourceFile = New-Object System.Windows.Forms.Label
$lblSourceFile.Text = "Instalador:"
$lblSourceFile.Location = New-Object System.Drawing.Point(10, 535)
$lblSourceFile.AutoSize = $true

$txtSourceFile = New-Object System.Windows.Forms.TextBox
$txtSourceFile.Location = New-Object System.Drawing.Point(90, 532)
$txtSourceFile.Size = New-Object System.Drawing.Size(700, 20)
$txtSourceFile.ReadOnly = $true

$btnBrowse = New-Object System.Windows.Forms.Button
$btnBrowse.Text = "Procurar..."
$btnBrowse.Location = New-Object System.Drawing.Point(800, 530)
$btnBrowse.Size = New-Object System.Drawing.Size(100, 25)

$form.Controls.AddRange(@($lblSourceFile, $txtSourceFile, $btnBrowse))

# --- Linha: argumentos silenciosos + botao instalar ---
$lblSilentArgs = New-Object System.Windows.Forms.Label
$lblSilentArgs.Text = "Args silenciosos:"
$lblSilentArgs.Location = New-Object System.Drawing.Point(10, 568)
$lblSilentArgs.AutoSize = $true

$txtSilentArgs = New-Object System.Windows.Forms.TextBox
$txtSilentArgs.Location = New-Object System.Drawing.Point(120, 565)
$txtSilentArgs.Size = New-Object System.Drawing.Size(500, 20)
$txtSilentArgs.Text = ""
# Sugestoes comuns (o usuario edita livremente): MSI -> /qn /norestart
#   InstallShield -> /s /v"/qn"   |  Inno Setup -> /VERYSILENT /NORESTART
#   NSIS -> /S

$btnInstallFromSource = New-Object System.Windows.Forms.Button
$btnInstallFromSource.Text = "Instalar remotamente"
$btnInstallFromSource.Location = New-Object System.Drawing.Point(630, 563)
$btnInstallFromSource.Size = New-Object System.Drawing.Size(170, 27)
$btnInstallFromSource.Enabled = $false

$form.Controls.AddRange(@($lblSilentArgs, $txtSilentArgs, $btnInstallFromSource))

# --- Log ---
$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Location = New-Object System.Drawing.Point(10, 600)
$txtLog.Size = New-Object System.Drawing.Size(1010, 90)
$txtLog.Anchor = "Bottom,Left,Right"
$txtLog.Multiline = $true
$txtLog.ScrollBars = "Vertical"
$txtLog.ReadOnly = $true
$form.Controls.Add($txtLog)

function Write-Log {
    param([string]$Msg)
    $timestamp = Get-Date -Format "HH:mm:ss"
    $txtLog.AppendText("[$timestamp] $Msg`r`n")
}

# ---------------------------------------------------------------------------
# EVENTOS
# ---------------------------------------------------------------------------

$btnConnect.Add_Click({
    $computer = $txtComputer.Text.Trim()
    if (-not $computer) {
        [System.Windows.Forms.MessageBox]::Show("Informe o nome ou IP do computador remoto.", "Atencao") | Out-Null
        return
    }

    $cred = Get-Credential -Message "Credenciais de administrador para $computer"
    if (-not $cred) { return }

    try {
        Write-Log "Conectando a $computer..."
        if ($script:Session) { Remove-PSSession $script:Session -ErrorAction SilentlyContinue }

        $script:Session = New-PSSession -ComputerName $computer -Credential $cred -ErrorAction Stop
        $script:ComputerName = $computer

        $lblStatus.Text = "Status: conectado a $computer"
        $lblStatus.ForeColor = [System.Drawing.Color]::Green
        $btnRefresh.Enabled = $true
        $btnUninstall.Enabled = $true
        $btnRepair.Enabled = $true
        $btnInstallLatest.Enabled = $true
        $btnReinstall.Enabled = $true
        $btnInstallFromSource.Enabled = $true

        Write-Log "Conectado com sucesso."
        $btnRefresh.PerformClick()
    } catch {
        $lblStatus.Text = "Status: falha na conexao"
        $lblStatus.ForeColor = [System.Drawing.Color]::Red
        Write-Log "ERRO ao conectar: $($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show("Falha ao conectar: $($_.Exception.Message)", "Erro") | Out-Null
    }
})

$btnRefresh.Add_Click({
    if (-not $script:Session) { return }
    Write-Log "Buscando programas instalados..."
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    try {
        $lista = Get-InstalledSoftwareRemote -Session $script:Session
        $grid.DataSource = [System.Collections.ArrayList]$lista
        Write-Log "Encontrados $($lista.Count) programas."
    } catch {
        Write-Log "ERRO ao listar programas: $($_.Exception.Message)"
    } finally {
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
    }
})

function Get-SelectedItem {
    if ($grid.SelectedRows.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("Selecione um programa na lista.", "Atencao") | Out-Null
        return $null
    }
    return $grid.SelectedRows[0].DataBoundItem
}

$btnUninstall.Add_Click({
    $item = Get-SelectedItem
    if (-not $item) { return }

    $confirm = [System.Windows.Forms.MessageBox]::Show(
        "Desinstalar '$($item.Nome)' de $script:ComputerName?",
        "Confirmar", "YesNo", "Warning")
    if ($confirm -ne "Yes") { return }

    Write-Log "Desinstalando '$($item.Nome)'..."
    $resultado = Invoke-RemoteUninstall -Session $script:Session -Item $item
    Write-Log "Resultado: $resultado"
    $btnRefresh.PerformClick()
})

$btnRepair.Add_Click({
    $item = Get-SelectedItem
    if (-not $item) { return }

    Write-Log "Reparando '$($item.Nome)'..."
    $resultado = Invoke-RemoteRepair -Session $script:Session -Item $item
    Write-Log "Resultado: $resultado"
})

$btnInstallLatest.Add_Click({
    $item = Get-SelectedItem
    if (-not $item) { return }

    Write-Log "Instalando/atualizando '$($item.Nome)' via winget..."
    $resultado = Invoke-RemoteWingetAction -Session $script:Session -NomePrograma $item.Nome -Acao "upgrade"
    Write-Log "Resultado: $resultado"
    $btnRefresh.PerformClick()
})

$btnReinstall.Add_Click({
    $item = Get-SelectedItem
    if (-not $item) { return }

    $confirm = [System.Windows.Forms.MessageBox]::Show(
        "Isso vai desinstalar '$($item.Nome)' e baixar/instalar a versao mais recente novamente. Continuar?",
        "Confirmar reinstalacao", "YesNo", "Warning")
    if ($confirm -ne "Yes") { return }

    Write-Log "Desinstalando '$($item.Nome)' para reinstalar..."
    $resUninstall = Invoke-RemoteUninstall -Session $script:Session -Item $item
    Write-Log "Desinstalacao: $resUninstall"

    Write-Log "Baixando e instalando a versao mais recente via winget..."
    $resInstall = Invoke-RemoteWingetAction -Session $script:Session -NomePrograma $item.Nome -Acao "install"
    Write-Log "Instalacao: $resInstall"

    $btnRefresh.PerformClick()
})

$btnBrowse.Add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Title = "Selecione o instalador (pasta source)"
    $dlg.Filter = "Instaladores (*.exe;*.msi)|*.exe;*.msi|Todos os arquivos (*.*)|*.*"
    if ($dlg.ShowDialog() -eq "OK") {
        $txtSourceFile.Text = $dlg.FileName

        # Sugere um template de argumentos com base na extensao (o usuario pode editar)
        if ($dlg.FileName -match '\.msi$') {
            $txtSilentArgs.Text = "/qn /norestart"
        } elseif ([string]::IsNullOrWhiteSpace($txtSilentArgs.Text)) {
            $txtSilentArgs.Text = "/S"
        }
    }
})

$btnInstallFromSource.Add_Click({
    if (-not $script:Session) { return }

    $localPath = $txtSourceFile.Text.Trim()
    if (-not $localPath -or -not (Test-Path $localPath)) {
        [System.Windows.Forms.MessageBox]::Show("Selecione um instalador valido primeiro.", "Atencao") | Out-Null
        return
    }

    $installArgs = $txtSilentArgs.Text

    $confirm = [System.Windows.Forms.MessageBox]::Show(
        "Copiar e instalar`n$localPath`nem $script:ComputerName com os argumentos:`n'$installArgs' ?",
        "Confirmar instalacao remota", "YesNo", "Warning")
    if ($confirm -ne "Yes") { return }

    Write-Log "Copiando '$localPath' para $script:ComputerName..."
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    $btnInstallFromSource.Enabled = $false
    try {
        $resultado = Invoke-RemoteInstallFromFile -Session $script:Session -LocalPath $localPath -Args $installArgs
        Write-Log "Instalacao: $resultado"
    } finally {
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
        $btnInstallFromSource.Enabled = $true
    }

    $btnRefresh.PerformClick()
})

$form.Add_FormClosing({
    if ($script:Session) {
        Remove-PSSession $script:Session -ErrorAction SilentlyContinue
    }
})

# ---------------------------------------------------------------------------
[void]$form.ShowDialog()
