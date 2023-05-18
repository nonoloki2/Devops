### List the installed applications.

$INSTALLED = Get-ItemProperty HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\* |  Select-Object DisplayName, UninstallString
$INSTALLED += Get-ItemProperty HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\* | Select-Object DisplayName, UninstallString
$INSTALLED | ?{ $_.DisplayName -ne $null } | sort-object -Property DisplayName -Unique | Format-Table -AutoSize

### Search for the Google Chrome application.

$SEARCH = 'chrome$'
$RESULT =$INSTALLED | ?{ $_.DisplayName -ne $null } | Where-Object {$_.DisplayName -match $search } 
$RESULT

### Uninstall Google Chrome

if ($RESULT.uninstallstring -like "msiexec*") {
$ARGS=(($RESULT.UninstallString -split ' ')[1] -replace '/I','/X ') + ' /q'
Start-Process msiexec.exe -ArgumentList $ARGS -Wait
} else {
$UNINSTALL_COMMAND=(($RESULT.UninstallString -split '\"')[1])
$UNINSTALL_ARGS=(($RESULT.UninstallString -split '\"')[2]) + ' --force-uninstall'
Start-Process $UNINSTALL_COMMAND -ArgumentList $UNINSTALL_ARGS -Wait
}