$Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization"

New-Item -Path $Path -Force | Out-Null

New-ItemProperty `
    -Path $Path `
    -Name "DODownloadMode" `
    -PropertyType DWord `
    -Value 1 `
    -Force | Out-Null

Restart-Service DoSvc -Force
Restart-Service CcmExec -Force