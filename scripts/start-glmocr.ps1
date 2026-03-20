$env:HOME = $env:USERPROFILE

# ── настройки ──────────────────────────────────────────────────────────────────
$TemplateHash  = "19b69f2c0532c31079ee277f74df7877"
$SearchQuery   = "gpu_name=A100_PCIE num_gpus=1 rented=False verified=True"
$BidMultiplier = 1.30      # ставим на 30% выше базы
$ApiPort       = 18001      # порт API внутри контейнера

# ── 1. удалить все старые инстансы ─────────────────────────────────────────────
Write-Host "1. Проверка и удаление старых инстансов..." -ForegroundColor Cyan
$currentInstancesJson = vastai show instances --raw
if (-not [string]::IsNullOrWhiteSpace($currentInstancesJson) -and $currentInstancesJson -ne "[]") {
    $currentInstances = $currentInstancesJson | ConvertFrom-Json
    foreach ($inst in @($currentInstances)) {
        Write-Host "  Удаляем инстанс $($inst.id)..." -ForegroundColor Yellow
        vastai destroy instance $inst.id | Out-Null
    }
    Write-Host "  Старые инстансы удалены. Ждем 5 секунд..."
    Start-Sleep -Seconds 5
} else {
    Write-Host "  Старых инстансов не найдено."
}

# ── 2. найти свободную машину ──────────────────────────────────────────────────
Write-Host "`n2. Ищем свободный A100 PCIe..." -ForegroundColor Cyan
$offersJson = vastai search offers $SearchQuery -o dph --raw

if ([string]::IsNullOrWhiteSpace($offersJson) -or $offersJson -eq "[]") {
    Write-Warning "Нет свободных машин. Попробуй позже."
    exit 1
}

$offers = $offersJson | ConvertFrom-Json
$target = @($offers)[0]

# вычислить базовую цену
$basePrice = 0
if ($target.min_bid)   { $basePrice = [double]$target.min_bid }
elseif ($target.dph_total) { $basePrice = [double]$target.dph_total }
elseif ($target.dph)   { $basePrice = [double]$target.dph }

if ($basePrice -eq 0) {
    Write-Error "Не удалось получить цену. Ответ:"
    $target | Format-List
    exit 1
}

$bidPrice    = $basePrice * $BidMultiplier
$bidPriceStr = $bidPrice.ToString("0.000", [System.Globalization.CultureInfo]::InvariantCulture)

Write-Host "  Машина ID: $($target.id)  |  База: `$$basePrice/h  |  Ставка: `$$bidPriceStr/h" -ForegroundColor White

# ── 3. запустить инстанс ───────────────────────────────────────────────────────
Write-Host "`n3. Создаем инстанс..." -ForegroundColor Cyan
$createJson = vastai create instance $target.id `
    --template_hash $TemplateHash `
    --bid_price $bidPriceStr `
    --raw

if ([string]::IsNullOrWhiteSpace($createJson)) {
    Write-Error "CLI не вернул ответ."
    exit 1
}

$createResult = $createJson | ConvertFrom-Json
$contractId   = $createResult.new_contract

if (-not $contractId) {
    Write-Error "Не удалось создать инстанс. Ответ: $createJson"
    exit 1
}

Write-Host "  Инстанс #$contractId создан. Ждем запуска..." -ForegroundColor Cyan

# ── 4. ждать SSH-готовности ────────────────────────────────────────────────────
$ready = $false
while (-not $ready) {
    Start-Sleep -Seconds 15
    Write-Host "." -NoNewline

    $instancesJson = vastai show instances --raw
    $instances     = $instancesJson | ConvertFrom-Json
    $inst          = @($instances) | Where-Object { $_.id -eq $contractId }

    if ($inst) {
        if ($inst.actual_status -eq "running" -and $inst.ssh_host -and $inst.ssh_port) {

            # найти маппинг порта API
            $mappedApiPort = $null
            $portMappings  = $inst.ports
            if ($portMappings) {
                $portObj = $portMappings.PSObject.Properties |
                           Where-Object { $_.Name -like "${ApiPort}/tcp" }
                if ($portObj) {
                    $mappedApiPort = ($portObj.Value | Select-Object -First 1).HostPort
                }
            }

            Write-Host "`n"
            Write-Host "=============================================" -ForegroundColor Green
            Write-Host " ИНСТАНС ГОТОВ  #$contractId" -ForegroundColor Green
            Write-Host "=============================================" -ForegroundColor Green
            Write-Host " SSH:  ssh -p $($inst.ssh_port) root@$($inst.ssh_host)" -ForegroundColor Yellow
            if ($mappedApiPort) {
                Write-Host " API:  http://$($inst.ssh_host):$mappedApiPort/health" -ForegroundColor Yellow
                Write-Host ""
                Write-Host " Batch OCR:" -ForegroundColor White
                Write-Host "   .\batch_ocr.ps1 -ApiUrl `"http://$($inst.ssh_host):$mappedApiPort`"" -ForegroundColor Cyan
            } else {
                Write-Host " API port $ApiPort not yet mapped (check vast.ai UI)" -ForegroundColor DarkYellow
            }
            Write-Host "=============================================" -ForegroundColor Green
            Write-Host ""
            Write-Host " Onstart script (~15 min) ставит зависимости и поднимает сервис."
            Write-Host " Проверяй готовность:"
            if ($mappedApiPort) {
                Write-Host "   curl.exe -s http://$($inst.ssh_host):$mappedApiPort/health" -ForegroundColor Cyan
            }
            $ready = $true

        } elseif ($inst.actual_status -match "error|stopped|dead|exited") {
            Write-Host "`n  Ошибка запуска. Статус: $($inst.actual_status)" -ForegroundColor Red
            break
        }
    }
}
