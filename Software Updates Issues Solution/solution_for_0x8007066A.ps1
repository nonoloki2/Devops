#requires -RunAsAdministrator

$ErrorActionPreference = 'Stop'

Write-Host "=== SCCM Software Update Policy Reset ===" -ForegroundColor Cyan

try {
    Write-Host "[1/5] Parando serviço CCMExec..." -ForegroundColor Yellow
    Stop-Service -Name CcmExec -Force -ErrorAction Stop

    $RegistryPol = "C:\Windows\System32\GroupPolicy\Machine\Registry.pol"

    Write-Host "[2/5] Removendo Registry.pol..." -ForegroundColor Yellow

    if (Test-Path -LiteralPath $RegistryPol) {
        Remove-Item -LiteralPath $RegistryPol -Force -ErrorAction Stop
        Write-Host "Registry.pol removido." -ForegroundColor Green
    }
    else {
        Write-Host "Registry.pol não existe. Continuando..." -ForegroundColor DarkYellow
    }

    Write-Host "[3/5] Iniciando serviço CCMExec..." -ForegroundColor Yellow
    Start-Service -Name CcmExec -ErrorAction Stop

    Write-Host "[4/5] Aguardando cliente SCCM inicializar..." -ForegroundColor Yellow
    Start-Sleep -Seconds 10

    Write-Host "[5/5] Forçando ciclos de Software Updates..." -ForegroundColor Yellow

    $Cycles = @(
        # Machine Policy Retrieval & Evaluation
        "{00000000-0000-0000-0000-000000000021}",

        # Software Updates Scan Cycle
        "{00000000-0000-0000-0000-000000000113}",

        # Software Updates Deployment Evaluation Cycle
        "{00000000-0000-0000-0000-000000000108}"
    )

    foreach ($ScheduleId in $Cycles) {

        Invoke-CimMethod `
            -Namespace "root\ccm" `
            -ClassName "SMS_Client" `
            -MethodName "TriggerSchedule" `
            -Arguments @{ sScheduleID = $ScheduleId } `
            -ErrorAction Stop | Out-Null

        Write-Host "Executado: $ScheduleId" -ForegroundColor Green

        Start-Sleep -Seconds 3
    }

    Write-Host ""
    Write-Host "Concluído." -ForegroundColor Green
    Write-Host "O cliente SCCM foi reiniciado e a busca/avaliação de updates foi disparada." -ForegroundColor Green
}
catch {

    Write-Host ""
    Write-Host "ERRO: $($_.Exception.Message)" -ForegroundColor Red

    # Garante que o CCMExec não fique parado caso algo falhe no meio.
    try {
        if ((Get-Service CcmExec -ErrorAction SilentlyContinue).Status -ne 'Running') {
            Start-Service CcmExec -ErrorAction SilentlyContinue
        }
    }
    catch {}

    exit 1
}