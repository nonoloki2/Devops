$INSTALLED = Get-ItemProperty HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\* |
             Select-Object DisplayName, UninstallString
$INSTALLED += Get-ItemProperty HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\* |
              Select-Object DisplayName, UninstallString
$INSTALLED | Where-Object { $_.DisplayName -ne $null } |
    Sort-Object -Property DisplayName -Unique |
    Format-Table -AutoSize

$SEARCH = 'lightshot*'
$RESULT = $INSTALLED | Where-Object { $_.DisplayName -like $SEARCH }
$silent = "/verysilent"
if ($RESULT) {
    $RESULT | Format-Table -AutoSize
    $UninstallString = $RESULT.UninstallString
    Write-Host "Uninstalling: $($RESULT.DisplayName)"
    Start-Process -FilePath $UninstallString -ArgumentList $silent -Wait
} else {
    Write-Host "Application not found: $SEARCH"
}
