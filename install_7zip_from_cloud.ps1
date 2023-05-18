$source = "https://www.7-zip.org/a/7z2201-x64.exe"
$DownloadPath = "\\ivanti-epm\Packages\7Zip"

Start-BitsTransfer -Source $source -Destination $DownloadPath
Start-Process -FilePath "\\ivanti-epm\Packages\7Zip\7z2201-x64.exe" -ArgumentList "/S" -Wait

