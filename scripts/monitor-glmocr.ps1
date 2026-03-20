$env:HOME = $env:USERPROFILE

# ── настройки ──────────────────────────────────────────────────────────────────
$TemplateHash    = "19b69f2c0532c31079ee277f74df7877"
$SearchQuery     = "gpu_name=A100_PCIE num_gpus=1 rented=False verified=True"
$BidMultiplier   = 1.30
$ApiPort         = 18001
$CheckIntervalSec = 300     # проверять каждые 5 минут

# ── helpers ────────────────────────────────────────────────────────────────────
function Write-Log {
    param([string]$Msg, [string]$Color = "White")
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "[$ts] $Msg" -ForegroundColor $Color
}

function Get-MyInstances {
    $json = vastai show instances --raw
    if ([string]::IsNullOrWhiteSpace($json) -or $json -eq "[]") { return @() }
    return @($json | ConvertFrom-Json)
}

function Start-NewInstance {
    Write-Log "Ищем свободный A100 PCIe..." Cyan
    $offersJson = vastai search offers $SearchQuery -o dph --raw

    if ([string]::IsNullOrWhiteSpace($offersJson) -or $offersJson -eq "[]") {
        Write-Log "Нет свободных машин. Попробуем через $CheckIntervalSec сек." Yellow
        return $null
    }

    $target = @($offersJson | ConvertFrom-Json)[0]

    $basePrice = 0
    if ($target.min_bid)       { $basePrice = [double]$target.min_bid }
    elseif ($target.dph_total) { $basePrice = [double]$target.dph_total }
    elseif ($target.dph)       { $basePrice = [double]$target.dph }

    if ($basePrice -eq 0) {
        Write-Log "Не удалось получить цену для offer $($target.id). Пропуск." Red
        return $null
    }

    $bidPrice    = $basePrice * $BidMultiplier
    $bidPriceStr = $bidPrice.ToString("0.000", [System.Globalization.CultureInfo]::InvariantCulture)
    Write-Log "  Offer $($target.id)  база=$basePrice  ставка=$bidPriceStr" White

    $createJson = vastai create instance $target.id `
        --template_hash $TemplateHash `
        --bid_price $bidPriceStr `
        --raw

    if ([string]::IsNullOrWhiteSpace($createJson)) {
        Write-Log "CLI не вернул ответ при создании инстанса." Red
        return $null
    }

    $result     = $createJson | ConvertFrom-Json
    $contractId = $result.new_contract

    if (-not $contractId) {
        Write-Log "Не удалось создать инстанс. Ответ: $createJson" Red
        return $null
    }

    Write-Log "Инстанс #$contractId создан." Green
    return $contractId
}

function Show-InstanceInfo {
    param($inst)
    $mappedApiPort = $null
    if ($inst.ports) {
        $portObj = $inst.ports.PSObject.Properties |
                   Where-Object { $_.Name -like "${ApiPort}/tcp" }
        if ($portObj) {
            $mappedApiPort = ($portObj.Value | Select-Object -First 1).HostPort
        }
    }
    Write-Log "  SSH:  ssh -p $($inst.ssh_port) root@$($inst.ssh_host)" Green
    if ($mappedApiPort) {
        Write-Log "  API:  http://$($inst.ssh_host):$mappedApiPort/health" Green
        Write-Log "  Batch: .\batch_ocr.ps1 -ApiUrl http://$($inst.ssh_host):$mappedApiPort" Cyan
    }
}

# ── main loop ──────────────────────────────────────────────────────────────────
Write-Log "=== GLM-OCR Monitor запущен (Ctrl+C для остановки) ===" Cyan
Write-Log "Template: $TemplateHash  |  Interval: ${CheckIntervalSec}s" White

$lastKnownId = $null

while ($true) {
    $instances = Get-MyInstances

    if ($instances.Count -eq 0) {
        Write-Log "Нет инстансов. Создаем новый..." Yellow
        $newId = Start-NewInstance
        if ($newId) { $lastKnownId = $newId }

    } else {
        $running = $instances | Where-Object { $_.actual_status -eq "running" }
        $dead    = $instances | Where-Object { $_.actual_status -match "stopped|paused|inactive|exited|error|dead" }

        # удалить мертвые
        foreach ($d in @($dead)) {
            Write-Log "Инстанс #$($d.id) статус=$($d.actual_status) — удаляем." Yellow
            vastai destroy instance $d.id | Out-Null
        }

        if ($running.Count -gt 0) {
            $r = @($running)[0]
            if ($r.id -ne $lastKnownId) {
                Write-Log "Инстанс #$($r.id) running." Green
                Show-InstanceInfo $r
                $lastKnownId = $r.id
            } else {
                Write-Log "Инстанс #$($r.id) OK (running)." DarkGreen
            }
        } else {
            Write-Log "Нет running инстансов. Создаем новый..." Yellow
            Start-Sleep -Seconds 3
            $newId = Start-NewInstance
            if ($newId) { $lastKnownId = $newId }
        }
    }

    Write-Log "Следующая проверка через $CheckIntervalSec сек..." DarkGray
    Start-Sleep -Seconds $CheckIntervalSec
}
