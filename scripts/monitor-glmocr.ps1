. (Join-Path $PSScriptRoot "vast-glmocr-common.ps1")

Write-Log "=== GLM-OCR Monitor started (Ctrl+C to stop) ===" Cyan
Write-Log "Label: $InstanceLabel  |  Disk: ${DiskGb}GB  |  Healthy interval: ${HealthyCheckIntervalSec}s" White

$lastKnownId = $null

while ($true) {
    $instances = Get-MyInstances
    $deadInstances = @($instances | Where-Object { Test-TerminalStatus $_.actual_status })
    $activeInstances = @($instances | Where-Object { -not (Test-TerminalStatus $_.actual_status) } | Sort-Object id -Descending)
    $runningInstances = @($activeInstances | Where-Object { $_.actual_status -eq "running" })
    $sleepSec = $HealthyCheckIntervalSec

    if ($deadInstances.Count -gt 0) {
        Write-Log "Cleaning up dead instances..." Yellow
        Remove-Instances $deadInstances
    }

    if ($runningInstances.Count -gt 0) {
        $running = $runningInstances[0]
        $currentUrl = Get-PublicApiUrl $running
        $savedUrl = if (Test-Path $EndpointFile) { (Get-Content $EndpointFile -Raw).Trim() } else { "" }

        if ($running.id -ne $lastKnownId) {
            Write-Log "Instance #$($running.id) is running." Green
            Show-InstanceInfo $running
            $lastKnownId = $running.id
        } elseif ($currentUrl -and $currentUrl -ne $savedUrl) {
            Write-Log "Endpoint changed for instance #$($running.id)." DarkCyan
            Show-InstanceInfo $running
        } else {
            Write-Log "Instance #$($running.id) OK. Endpoint: $savedUrl" DarkGreen
        }

    } elseif ($activeInstances.Count -gt 0) {
        $active = $activeInstances[0]
        Write-Log "Active instance #$($active.id) is still starting ($($active.actual_status)). Waiting before creating another one." DarkYellow
        $sleepSec = $RecoveryCheckIntervalSec

    } else {
        Write-Log "No active GLM-OCR instances found. Starting recovery..." Yellow
        $result = Start-NewStableInstance

        if ($result) {
            Write-Log "Recovered with instance #$($result.Instance.id)." Green
            Show-InstanceInfo $result.Instance
            $lastKnownId = $result.Instance.id
            $sleepSec = $HealthyCheckIntervalSec
        } else {
            Write-Log "Recovery attempt failed. Will retry soon." Red
            $sleepSec = $RecoveryCheckIntervalSec
        }
    }

    Write-Log "Next check in ${sleepSec}s..." DarkGray
    Start-Sleep -Seconds $sleepSec
}
