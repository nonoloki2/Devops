# ler nome e porta KMS local (executar como administrador se necessário)
$base = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SoftwareProtectionPlatform'
$name = Get-ItemProperty -Path $base -ErrorAction SilentlyContinue
if ($name) {
    [PSCustomObject]@{
        KeyManagementServiceName = $name.KeyManagementServiceName
        KeyManagementServicePort = $name.KeyManagementServicePort
    }
} else {
    Write-Output "Registry Key not found on this system!"
}