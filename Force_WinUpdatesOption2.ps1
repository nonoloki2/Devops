Install-PackageProvider NuGet -Force

If(-not(Get-InstalledModule PSWindowsUpdate -ErrorAction silentlycontinue))
{
Set-PSRepository PSGallery -InstallationPolicy Trusted
Install-Module PSWindowsUpdate -Confirm:$False -Force

}

Install-WindowsUpdate -MicrosoftUpdate -NotCategory "Drivers","FeaturePacks" -AcceptAll -IgnoreReboot -Verbose