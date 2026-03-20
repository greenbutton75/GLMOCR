[CmdletBinding()]
param(
    [switch]$ForceRecreate
)

. (Join-Path $PSScriptRoot "vast-glmocr-common.ps1")

Write-Log "=== GLM-OCR start ===" Cyan
Write-Log "Label: $InstanceLabel  |  Disk: ${DiskGb}GB  |  ForceRecreate: $ForceRecreate" White

$instances = Get-MyInstances
$deadInstances = @($instances | Where-Object { Test-TerminalStatus $_.actual_status })
$activeInstances = @($instances | Where-Object { -not (Test-TerminalStatus $_.actual_status) } | Sort-Object id -Descending)
$runningInstances = @($activeInstances | Where-Object { $_.actual_status -eq "running" })

if (-not $ForceRecreate) {
    if ($runningInstances.Count -gt 0) {
        $running = $runningInstances[0]
        Write-Log "Reusing running instance #$($running.id) instead of replacing it." Green
        Show-InstanceInfo $running
        exit 0
    }

    if ($activeInstances.Count -gt 0) {
        $existing = $activeInstances[0]
        Write-Log "Found active instance #$($existing.id) in status '$($existing.actual_status)'. Waiting for it before creating a new one." Cyan
        $waitResult = Wait-InstanceReady -ContractId $existing.id
        if ($waitResult.Success) {
            Show-ReadyBanner -Instance $waitResult.Instance -ApiUrl $waitResult.ApiUrl
            exit 0
        }

        $why = if ($waitResult.Reason) { $waitResult.Reason } else { "unknown" }
        Write-Log "Existing instance #$($existing.id) did not stabilize ($why). It will be removed and replaced." Yellow
        $instanceToRemove = if ($waitResult.Instance) { $waitResult.Instance } else { $existing }
        Remove-Instances @($instanceToRemove)
        Start-Sleep -Seconds 5
    }
}

if ($deadInstances.Count -gt 0) {
    Write-Log "Cleaning up dead GLM-OCR instances..." Cyan
    Remove-Instances $deadInstances
    Start-Sleep -Seconds 5
}

if ($ForceRecreate -and $activeInstances.Count -gt 0) {
    Write-Log "ForceRecreate requested. Destroying existing active GLM-OCR instances first..." Yellow
    Remove-Instances $activeInstances
    Start-Sleep -Seconds 5
}

$result = Start-NewStableInstance
if (-not $result) {
    Write-Error "Failed to acquire a stable GLM-OCR instance after trying multiple offers and bid levels."
    exit 1
}

Show-ReadyBanner -Instance $result.Instance -ApiUrl $result.ApiUrl
