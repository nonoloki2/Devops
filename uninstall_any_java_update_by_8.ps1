### Listar aplicativos instalados
$INSTALLED = Get-ItemProperty HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\* | Select-Object DisplayName, UninstallString
$INSTALLED += Get-ItemProperty HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\* | Select-Object DisplayName, UninstallString
$INSTALLED | Where-Object { $_.DisplayName -ne $null } | Sort-Object -Property DisplayName -Unique | Format-Table -AutoSize

### Buscar qualquer versão do Java 8
$SEARCH = "Java 8"  # Agora ele captura qualquer versão do Java 8 automaticamente
$RESULTS = $INSTALLED | Where-Object { $_.DisplayName -match $SEARCH }

### Executar a desinstalação para todas as versões encontradas
if ($RESULTS) {
    foreach ($RESULT in $RESULTS) {
        Write-Host "Desinstalando: $($RESULT.DisplayName)"

        if ($RESULT.UninstallString -match "MsiExec.exe") {
            # Extrair o GUID corretamente
            if ($RESULT.UninstallString -match "{.*}") {
                $MSI_GUID = $matches[0]
                $ARGS = "/X $MSI_GUID /quiet /norestart"
                Start-Process msiexec.exe -ArgumentList $ARGS -Wait
                if ($?) { Write-Host "Desinstalação concluída." } else { Write-Host "Erro ao desinstalar!" }
            } else {
                Write-Host "Falha ao identificar GUID para MSI."
            }
        } else {
            # Para desinstalação de EXE
            $UNINSTALL_COMMAND = ($RESULT.UninstallString -split ' ')[0] -replace '"', ''
            $UNINSTALL_ARGS = ($RESULT.UninstallString -replace [regex]::Escape($UNINSTALL_COMMAND), '').Trim() + ' /silent /norestart'

            if (Test-Path $UNINSTALL_COMMAND) {
                Start-Process -FilePath $UNINSTALL_COMMAND -ArgumentList $UNINSTALL_ARGS -Wait
                if ($?) { Write-Host "Desinstalação concluída." } else { Write-Host "Erro ao desinstalar!" }
            } else {
                Write-Host "Arquivo de desinstalação não encontrado."
            }
        }
    }
    exit 0  # Saída com sucesso após remover todas as versões
} else {
    exit 1  # Nenhuma versão do Java 8 encontrada
}