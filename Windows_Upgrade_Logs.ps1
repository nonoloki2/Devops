$hostname = $env:COMPUTERNAME
$saveLocation = Read-Host "Enter the location to save the zip file"

# Create a new zip file with the machine hostname
$zipFileName = "$hostname.zip"
$zipFilePath = Join-Path -Path $saveLocation -ChildPath $zipFileName
$zip = [System.IO.Compression.ZipFile]::CreateFromDirectory("C:\$WINDOWS.~BT\Sources\Panther\", $zipFilePath)

Write-Host "Log files have been zipped and saved to: $zipFilePath"
