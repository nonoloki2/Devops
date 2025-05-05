### Listar aplicativos instalados
$INSTALLED = Get-ItemProperty HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\* | Select-Object DisplayName, UninstallString
$INSTALLED += Get-ItemProperty HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\* | Select-Object DisplayName, UninstallString
$INSTALLED | Where-Object { $_.DisplayName -ne $null } | Sort-Object -Property DisplayName -Unique | Format-Table -AutoSize

### Definir o aplicativo a ser desinstalado
$SEARCH = 'Java 8 Update 441'  # Substitua pelo nome exato do software
$RESULT = $INSTALLED | Where-Object { $_.DisplayName -match $SEARCH }

### Executar a desinstalação
if ($RESULT) {
    if ($RESULT.UninstallString -match "MsiExec.exe") {
        # Extrair o GUID corretamente e substituir o comando de instalação (/I) por remoção (/X)
        if ($RESULT.UninstallString -match "{.*}") {
            $MSI_GUID = $matches[0]
            $ARGS = "/X $MSI_GUID /quiet /norestart"
            Start-Process msiexec.exe -ArgumentList $ARGS -Wait
            if ($?) { exit 0 } else { exit 1 }
        } else {
            exit 1  # Falha ao extrair o GUID do MSI
        }
    } else {
        # Para desinstalação de EXE
        $UNINSTALL_COMMAND = ($RESULT.UninstallString -split ' ')[0] -replace '"', ''
        $UNINSTALL_ARGS = ($RESULT.UninstallString -replace [regex]::Escape($UNINSTALL_COMMAND), '').Trim() + ' /silent /norestart'

        if (Test-Path $UNINSTALL_COMMAND) {
            Start-Process -FilePath $UNINSTALL_COMMAND -ArgumentList $UNINSTALL_ARGS -Wait
            if ($?) { exit 0 } else { exit 1 }
        } else {
            exit 1  # Arquivo de desinstalação não encontrado
        }
    }
} else {
    exit 1  # Nenhuma aplicação correspondente encontrada
}