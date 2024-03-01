# O script PowerShell fornecido automatiza a gestão de dispositivos utilizando o Microsoft Graph Device Management. Ele faz o seguinte:
# 
#     Instala módulos do Microsoft Graph necessários para o gerenciamento de dispositivos.
#     Importa o módulo Microsoft.Graph.DeviceManagement.Actions.
#     Conecta ao Microsoft Graph com escopos específicos relacionados ao gerenciamento de dispositivos.
#     Obtém todos os dispositivos gerenciados e executa uma operação de sincronização em cada dispositivo.
#     Exibe uma mensagem no console para cada dispositivo sincronizado.
#     Desconecta da sessão do Graph.


# Instala os módulos do Microsoft Graph para gerenciamento de dispositivos, forçando a instalação e permitindo sobreposição de comandos.
Install-Module -Name Microsoft.Graph.DeviceManagement.Actions -Force -AllowClobber
Install-Module -Name Microsoft.Graph.DeviceManagement -Force -AllowClobber
 
# Importa o módulo SDK para ações de gerenciamento de dispositivos.
Import-Module -Name Microsoft.Graph.DeviceManagement.Actions
 
# Conecta ao Microsoft Graph utilizando escopos específicos para operações de leitura e escrita em dispositivos gerenciados.
Connect-MgGraph -Scopes "DeviceManagementManagedDevices.PrivilegedOperations.All", "DeviceManagementManagedDevices.ReadWrite.All","DeviceManagementManagedDevices.Read.All"
 
# Obtém todos os dispositivos gerenciados e armazena na variável $Devices.
$Devices = Get-MgDeviceManagementManagedDevice -All

# Verifica se a lista de dispositivos não está vazia antes de prosseguir.
if ($Devices -ne $null) {
    # Itera sobre cada dispositivo obtido.
    Foreach ($Device in $Devices) {
        # Executa uma operação de sincronização no dispositivo atual.
        Sync-MgDeviceManagementManagedDevice -ManagedDeviceId $Device.Id
 
        # Exibe uma mensagem de status no console.
        Write-Host "Sending Sync request to Device with Device name $($Device.DeviceName)" -ForegroundColor Yellow
    }
} else {
    Write-Host "No devices found." -ForegroundColor Red
}
  
# Desconecta da sessão do Microsoft Graph.
Disconnect-MgGraph
