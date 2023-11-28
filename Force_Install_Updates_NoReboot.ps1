# Install PSWindowsUpdate module (if not already installed)
if (-not (Get-Module -Name PSWindowsUpdate -ListAvailable)) {
    Install-Module -Name PSWindowsUpdate -Force -AllowClobber
}

 

# Import PSWindowsUpdate module
Import-Module PSWindowsUpdate

 

# Force check for updates
(New-Object -ComObject Microsoft.Update.AutoUpdate).DetectNow()

 

# Get a list of pending updates
$updates = Get-WUList

 

# Install pending updates without rebooting
$updatesToInstall = $updates | Where-Object { $_.IsInstalled -eq $false }
$session = New-WUSession -Confirm:$false
Install-WUUpdates -Session $session -Updates $updatesToInstall

 

# Close the update session
$session.Dispose()