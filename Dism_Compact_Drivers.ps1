# Prompt for source and destination folders
$source = Read-Host "Enter the source folder path:"
$destination = Read-Host "Enter the destination folder path:"

# Build the command
$command = "dism /Capture-Image /ImageFile:`"$destination\drivers.wim`" /CaptureDir:`"$source`" /Compress:Max /Name:DRIVERS"

# Execute the command
Invoke-Expression -Command $command
