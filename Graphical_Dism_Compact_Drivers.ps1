Add-Type -AssemblyName System.Windows.Forms

# Create a form with labels and text boxes for source and destination paths
$form = New-Object System.Windows.Forms.Form
$form.Text = "Progress"
$form.Width = 400
$form.Height = 200
$form.StartPosition = "CenterScreen"

$sourceLabel = New-Object System.Windows.Forms.Label
$sourceLabel.Text = "Source Folder Path:"
$sourceLabel.Left = 25
$sourceLabel.Top = 30
$sourceLabel.AutoSize = $true
$form.Controls.Add($sourceLabel)

$sourceTextBox = New-Object System.Windows.Forms.TextBox
$sourceTextBox.Left = 150
$sourceTextBox.Top = 30
$sourceTextBox.Width = 200
$form.Controls.Add($sourceTextBox)

$destinationLabel = New-Object System.Windows.Forms.Label
$destinationLabel.Text = "Destination Folder Path:"
$destinationLabel.Left = 25
$destinationLabel.Top = 70
$destinationLabel.AutoSize = $true
$form.Controls.Add($destinationLabel)

$destinationTextBox = New-Object System.Windows.Forms.TextBox
$destinationTextBox.Left = 150
$destinationTextBox.Top = 70
$destinationTextBox.Width = 200
$form.Controls.Add($destinationTextBox)

$submitButton = New-Object System.Windows.Forms.Button
$submitButton.Text = "Start"
$submitButton.Left = 150
$submitButton.Top = 110
$submitButton.Width = 75
$submitButton.Add_Click({
    $source = $sourceTextBox.Text
    $destination = $destinationTextBox.Text
    
    # Build the command
    $command = "dism /Capture-Image /ImageFile:`"$destination\drivers.wim`" /CaptureDir:`"$source`" /Compress:Max /Name:DRIVERS"
    
    # Create a new PowerShell process to display the progress
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo.FileName = "powershell.exe"
    $process.StartInfo.Arguments = "-NoExit -Command $command"
    $process.Start()
    
    # Close the progress form
    $form.Close()
    $form.Dispose()
})

$form.Controls.Add($submitButton)

# Show the form
$form.ShowDialog()
