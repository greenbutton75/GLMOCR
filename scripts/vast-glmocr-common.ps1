$env:HOME = $env:USERPROFILE

$VastCliRoot = Join-Path $PSScriptRoot '.vastai-cli'
$env:XDG_CONFIG_HOME = Join-Path $VastCliRoot 'config'
$env:XDG_CACHE_HOME  = Join-Path $VastCliRoot 'cache'

foreach ($dir in @($VastCliRoot, $env:XDG_CONFIG_HOME, $env:XDG_CACHE_HOME, (Join-Path $env:XDG_CONFIG_HOME 'vastai'))) {
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
}

$vastApiKeyTarget = Join-Path (Join-Path $env:XDG_CONFIG_HOME 'vastai') 'vast_api_key'
$vastApiKeyCandidates = @(
    (Join-Path $env:USERPROFILE '.vast_api_key'),
    (Join-Path $env:USERPROFILE '.config\vastai\vast_api_key'),
    (Join-Path $env:APPDATA 'vastai\vast_api_key')
)

if (-not (Test-Path $vastApiKeyTarget)) {
    $sourceApiKey = $vastApiKeyCandidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
    if ($sourceApiKey) {
        Copy-Item -LiteralPath $sourceApiKey -Destination $vastApiKeyTarget -Force
    }
}
$env:HOME = $env:USERPROFILE

$TemplateHash            = "19b69f2c0532c31079ee277f74df7877"
$InstanceLabel           = "glmocr-401k"
$ApiPort                 = 18001
$DiskGb                  = 50
$MinReliability          = 0.95
$ReadyTimeoutSec         = 900
$StableWindowSec         = 120
$PollIntervalSec         = 15
$HealthyCheckIntervalSec = 300
$RecoveryCheckIntervalSec = 60
$MaxBidPrice             = 0.50
$BidMultipliers          = @(1.15, 1.30, 1.50, 1.75)
$BidFloors               = @(0.22, 0.26, 0.32, 0.40)
$EndpointFile            = Join-Path $PSScriptRoot "glmocr_endpoint.txt"

$SearchQueries = @(
    @{
        Name  = "A100 PCIe primary"
        Query = "gpu_name=A100_PCIE num_gpus=1 verified=True rentable=True disk_space>=50"
    },
    @{
        Name  = "A100 SXM4 primary"
        Query = "gpu_name=A100_SXM4 num_gpus=1 verified=True rentable=True disk_space>=50"
    },
    @{
        Name  = "A100 PCIe fallback"
        Query = "gpu_name=A100_PCIE num_gpus=1 verified=True rentable=True disk_space>=50 geolocation notin [CN,VN]"
    },
    @{
        Name  = "A100 SXM4 fallback"
        Query = "gpu_name=A100_SXM4 num_gpus=1 verified=True rentable=True disk_space>=50 geolocation notin [CN,VN]"
    }
)

function Write-Log {
    param(
        [string]$Msg,
        [string]$Color = "White"
    )

    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "[$ts] $Msg" -ForegroundColor $Color
}

function ConvertTo-ObjectArray {
    param($RawJson)

    if ($null -eq $RawJson) { return @() }

    $jsonText = if ($RawJson -is [array]) { $RawJson -join "`n" } else { "$RawJson" }
    if ([string]::IsNullOrWhiteSpace($jsonText)) { return @() }
    if ($jsonText.Trim() -eq "[]") { return @() }

    try {
        $parsed = $jsonText | ConvertFrom-Json
        return @($parsed)
    } catch {
        Write-Log "Failed to parse Vast.ai JSON response: $($_.Exception.Message)" Red
        return @()
    }
}

function Get-MyInstances {
    $json = vastai show instances --raw
    $instances = ConvertTo-ObjectArray $json
    if ($instances.Count -eq 0) { return @() }

    return @($instances) | Where-Object { $_.label -eq $InstanceLabel }
}

function Get-InstanceById {
    param([int]$Id)

    return @(Get-MyInstances | Where-Object { $_.id -eq $Id } | Select-Object -First 1)
}

function Test-TerminalStatus {
    param([string]$Status)

    return ($Status -match "error|stopped|dead|exited|inactive")
}

function Get-PublicApiUrl {
    param($Instance)

    if (-not $Instance) { return $null }
    if (-not $Instance.ports) { return $null }

    $portEntry = $Instance.ports.PSObject.Properties |
        Where-Object { $_.Name -eq "$ApiPort/tcp" } |
        Select-Object -First 1

    if (-not $portEntry) { return $null }

    $hostPort = (@($portEntry.Value))[0].HostPort
    if (-not $hostPort) { return $null }

    return "http://$($Instance.public_ipaddr):$hostPort"
}

function Save-EndpointFile {
    param([string]$Url)

    if ([string]::IsNullOrWhiteSpace($Url)) { return }
    $Url | Set-Content -Path $EndpointFile -Encoding UTF8
}

function Clear-EndpointFile {
    if (Test-Path $EndpointFile) {
        Remove-Item -LiteralPath $EndpointFile -Force
    }
}

function Resolve-ApiUrl {
    param(
        [int]$TimeoutSec = 0,
        [int]$PollSec = 10
    )

    $deadline = (Get-Date).AddSeconds([Math]::Max($TimeoutSec, 0))

    do {
        $instances = @(Get-MyInstances | Sort-Object id -Descending)
        $running = @($instances | Where-Object { $_.actual_status -eq "running" })

        foreach ($instance in $running) {
            $url = Get-PublicApiUrl $instance
            if ($url) {
                Save-EndpointFile $url
                return [pscustomobject]@{
                    Success  = $true
                    ApiUrl   = $url
                    Instance = $instance
                }
            }
        }

        if ($TimeoutSec -le 0 -or (Get-Date) -ge $deadline) {
            break
        }

        if ($running.Count -gt 0) {
            Write-Log "Running instance found, waiting for API port mapping..." DarkYellow
        } elseif ($instances.Count -gt 0) {
            Write-Log "GLM-OCR instance exists, waiting for running state..." DarkYellow
        } else {
            Write-Log "No GLM-OCR instances found while resolving endpoint." DarkYellow
        }

        Start-Sleep -Seconds $PollSec
    } while ((Get-Date) -lt $deadline)

    return [pscustomobject]@{
        Success  = $false
        ApiUrl   = $null
        Instance = $null
    }
}

function Get-OfferBasePrice {
    param($Offer)

    if ($null -ne $Offer.min_bid -and "$($Offer.min_bid)".Trim() -ne "") {
        return [double]$Offer.min_bid
    }
    if ($null -ne $Offer.dph_total -and "$($Offer.dph_total)".Trim() -ne "") {
        return [double]$Offer.dph_total
    }
    if ($null -ne $Offer.dph -and "$($Offer.dph)".Trim() -ne "") {
        return [double]$Offer.dph
    }

    return 0.0
}

function Get-OfferTotalPrice {
    param($Offer)

    if ($null -ne $Offer.dph_total -and "$($Offer.dph_total)".Trim() -ne "") {
        return [double]$Offer.dph_total
    }
    if ($null -ne $Offer.dph -and "$($Offer.dph)".Trim() -ne "") {
        return [double]$Offer.dph
    }

    return (Get-OfferBasePrice $Offer)
}

function Get-OfferReliability {
    param($Offer)

    if ($null -ne $Offer.reliability -and "$($Offer.reliability)".Trim() -ne "") {
        return [double]$Offer.reliability
    }
    if ($null -ne $Offer.reliability2 -and "$($Offer.reliability2)".Trim() -ne "") {
        return [double]$Offer.reliability2
    }

    return 0.0
}

function Get-EstimatedDiskHourly {
    param($Offer)

    if ($null -eq $Offer.storage_cost -or "$($Offer.storage_cost)".Trim() -eq "") {
        return 0.0
    }

    $monthly = [double]$Offer.storage_cost * $DiskGb
    return $monthly / 30.0 / 24.0
}

function Get-OfferStabilityScore {
    param($Offer)

    $score = 0.0
    $score += (Get-OfferReliability $Offer) * 1000.0

    if ($Offer.rented -eq $false) { $score += 120.0 }
    if ($Offer.rented -eq $true)  { $score -= 20.0 }
    if ($Offer.verified)          { $score += 40.0 }
    if ($Offer.datacenter)        { $score += 30.0 }
    if ($Offer.static_ip)         { $score += 10.0 }

    $score -= (Get-OfferBasePrice $Offer) * 220.0
    $score -= (Get-OfferTotalPrice $Offer) * 60.0
    $score -= (Get-EstimatedDiskHourly $Offer) * 80.0

    return [math]::Round($score, 3)
}

function Show-OfferSummary {
    param($Offer)

    $basePrice  = Get-OfferBasePrice $Offer
    $totalPrice = Get-OfferTotalPrice $Offer
    $reliabPct  = [math]::Round((Get-OfferReliability $Offer) * 100.0, 2)
    $diskHourly = [math]::Round((Get-EstimatedDiskHourly $Offer), 3)
    $stability  = Get-OfferStabilityScore $Offer
    $rentedText = if ($Offer.rented -eq $true) { "rented" } elseif ($Offer.rented -eq $false) { "free" } else { "unknown" }

    Write-Log ("  Candidate #{0} {1}  min_bid=${2}/h total=${3}/h disk~${4}/h reliability={5}% {6} score={7}" -f `
        $Offer.id,
        $Offer.gpu_name,
        $basePrice.ToString("0.000", [System.Globalization.CultureInfo]::InvariantCulture),
        $totalPrice.ToString("0.000", [System.Globalization.CultureInfo]::InvariantCulture),
        $diskHourly.ToString("0.000", [System.Globalization.CultureInfo]::InvariantCulture),
        $reliabPct,
        $rentedText,
        $stability) DarkGray
}

function Find-OfferCandidates {
    param([int]$MaxCandidates = 5)

    foreach ($queryDef in $SearchQueries) {
        Write-Log "Searching offers: $($queryDef.Name)" Cyan
        Write-Log "  Query: $($queryDef.Query)" DarkGray

        $rawOffers = vastai search offers $queryDef.Query --type bid --raw
        $offers = ConvertTo-ObjectArray $rawOffers

        if ($offers.Count -eq 0) {
            Write-Log "  No offers returned." DarkYellow
            continue
        }

        $filtered = @($offers) | Where-Object {
            (Get-OfferBasePrice $_) -gt 0 -and
            (Get-OfferReliability $_) -ge $MinReliability -and
            ($null -eq $_.disk_space -or [double]$_.disk_space -ge $DiskGb)
        }

        if ($filtered.Count -eq 0) {
            Write-Log "  Offers were returned, but none passed reliability/disk filters." DarkYellow
            continue
        }

        $ranked = @($filtered | Sort-Object `
            @{ Expression = { Get-OfferStabilityScore $_ }; Descending = $true }, `
            @{ Expression = { Get-OfferBasePrice $_ }; Descending = $false }, `
            @{ Expression = { Get-OfferTotalPrice $_ }; Descending = $false })

        $candidates = @($ranked | Select-Object -First $MaxCandidates)
        foreach ($candidate in $candidates) {
            Show-OfferSummary $candidate
        }

        if ($candidates.Count -gt 0) {
            return $candidates
        }
    }

    return @()
}

function Get-BidLadder {
    param($Offer)

    $basePrice = Get-OfferBasePrice $Offer
    $ladder = New-Object System.Collections.Generic.List[double]

    for ($i = 0; $i -lt $BidFloors.Count; $i++) {
        $multiplier = $BidMultipliers[[Math]::Min($i, $BidMultipliers.Count - 1)]
        $floor      = $BidFloors[$i]
        $bid        = [math]::Round([math]::Max(($basePrice * $multiplier), $floor), 3)

        if ($bid -le $MaxBidPrice -and -not $ladder.Contains($bid)) {
            $ladder.Add($bid)
        }
    }

    return @($ladder)
}

function Remove-Instances {
    param($Instances)

    $removedAny = $false
    foreach ($instance in @($Instances)) {
        Write-Log "Destroying instance #$($instance.id) [$($instance.actual_status)]..." Yellow
        vastai destroy instance $instance.id | Out-Null
        $removedAny = $true
    }

    if ($removedAny) {
        Clear-EndpointFile
    }
}

function New-InstanceFromOffer {
    param(
        $Offer,
        [double]$BidPrice
    )

    $bidPriceStr = $BidPrice.ToString("0.000", [System.Globalization.CultureInfo]::InvariantCulture)
    $diskHourly  = [math]::Round((Get-EstimatedDiskHourly $Offer), 3)

    Write-Log ("Creating from offer #{0} ({1}) with bid=${2}/h and disk={3}GB (~${4}/h storage)" -f `
        $Offer.id,
        $Offer.gpu_name,
        $bidPriceStr,
        $DiskGb,
        $diskHourly.ToString("0.000", [System.Globalization.CultureInfo]::InvariantCulture)) White

    $createJson = vastai create instance $Offer.id `
        --template_hash $TemplateHash `
        --disk $DiskGb `
        --bid_price $bidPriceStr `
        --label $InstanceLabel `
        --cancel-unavail `
        --raw

    if ([string]::IsNullOrWhiteSpace($createJson)) {
        return [pscustomobject]@{
            Success = $false
            Reason  = "empty-response"
        }
    }

    try {
        $result = $createJson | ConvertFrom-Json
    } catch {
        return [pscustomobject]@{
            Success = $false
            Reason  = "invalid-json"
            Raw     = $createJson
        }
    }
    $contractId = $result.new_contract

    if (-not $contractId) {
        return [pscustomobject]@{
            Success = $false
            Reason  = "create-failed"
            Raw     = $createJson
        }
    }

    return [pscustomobject]@{
        Success    = $true
        ContractId = [int]$contractId
        Raw        = $createJson
    }
}

function Wait-InstanceReady {
    param(
        [int]$ContractId,
        [int]$TimeoutSec = $ReadyTimeoutSec,
        [int]$StabilitySec = $StableWindowSec
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $stableSince = $null
    $lastStatus = $null
    $lastUrl = $null

    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds $PollIntervalSec

        $instance = Get-InstanceById -Id $ContractId | Select-Object -First 1
        if (-not $instance) {
            Write-Log "Instance #$ContractId not visible yet." DarkGray
            continue
        }

        if ($instance.actual_status -ne $lastStatus) {
            Write-Log "Instance #$ContractId status: $($instance.actual_status)" DarkGray
            $lastStatus = $instance.actual_status
        }

        if (Test-TerminalStatus $instance.actual_status) {
            return [pscustomobject]@{
                Success  = $false
                Reason   = "terminal-$($instance.actual_status)"
                Instance = $instance
            }
        }

        $publicApiUrl = Get-PublicApiUrl $instance

        if ($instance.actual_status -eq "running" -and $publicApiUrl) {
            if (-not $stableSince) {
                $stableSince = Get-Date
                Write-Log "Instance #$ContractId is running and port mapping is ready: $publicApiUrl" Green
                Write-Log "Waiting ${StabilitySec}s to ensure it does not get outbid immediately..." Cyan
            } elseif ($publicApiUrl -ne $lastUrl) {
                Write-Log "Instance #$ContractId port mapping changed to $publicApiUrl" DarkCyan
            }

            $aliveSec = [int]((Get-Date) - $stableSince).TotalSeconds
            $lastUrl = $publicApiUrl

            if ($aliveSec -ge $StabilitySec) {
                Save-EndpointFile $publicApiUrl
                return [pscustomobject]@{
                    Success  = $true
                    Instance = $instance
                    ApiUrl   = $publicApiUrl
                }
            }

            continue
        }

        $stableSince = $null
        if ($instance.actual_status -eq "running") {
            Write-Log "Instance #$ContractId is running, waiting for port $ApiPort mapping..." DarkYellow
        }
    }

    return [pscustomobject]@{
        Success  = $false
        Reason   = "timeout"
        Instance = (Get-InstanceById -Id $ContractId | Select-Object -First 1)
    }
}

function Show-InstanceInfo {
    param($Instance)

    if (-not $Instance) { return }

    $url = Get-PublicApiUrl $Instance
    Write-Log "  SSH: ssh -p $($Instance.ssh_port) root@$($Instance.ssh_host)" Green

    if ($url) {
        Save-EndpointFile $url
        Write-Log "  API: $url/health" Green
        Write-Log "  Endpoint saved to: $EndpointFile" DarkCyan
        Write-Log "  Run: .\batch_ocr.ps1" Cyan
    } else {
        Write-Log "  Port $ApiPort not yet mapped." DarkYellow
    }
}

function Show-ReadyBanner {
    param(
        $Instance,
        [string]$ApiUrl
    )

    Write-Host ""
    Write-Host "=============================================" -ForegroundColor Green
    Write-Host "  INSTANCE READY  #$($Instance.id)  ($($Instance.gpu_name))" -ForegroundColor Green
    Write-Host "=============================================" -ForegroundColor Green
    Write-Host "  SSH:  ssh -p $($Instance.ssh_port) root@$($Instance.ssh_host)" -ForegroundColor Yellow
    Write-Host "  API:  $ApiUrl/health" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  Endpoint saved to: $EndpointFile" -ForegroundColor DarkCyan
    Write-Host ""
    Write-Host "  Service deploys automatically (~15 min). Poll:" -ForegroundColor White
    Write-Host "    curl.exe -s $ApiUrl/health" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Batch OCR (once health returns ok):" -ForegroundColor White
    Write-Host "    .\batch_ocr.ps1" -ForegroundColor Cyan
    Write-Host "=============================================" -ForegroundColor Green
}

function Start-NewStableInstance {
    param([int]$MaxCandidates = 5)

    $candidates = Find-OfferCandidates -MaxCandidates $MaxCandidates
    if ($candidates.Count -eq 0) {
        Write-Log "No suitable offers found." Yellow
        return $null
    }

    foreach ($offer in $candidates) {
        $bidLadder = Get-BidLadder $offer
        if ($bidLadder.Count -eq 0) {
            Write-Log "Offer #$($offer.id) has no acceptable bid ladder under the max bid cap." DarkYellow
            continue
        }

        foreach ($bid in $bidLadder) {
            $created = New-InstanceFromOffer -Offer $offer -BidPrice $bid
            if (-not $created.Success) {
                $why = if ($created.Reason) { $created.Reason } else { "unknown" }
                Write-Log ("Create failed for offer #{0} at bid {1}: {2}" -f $offer.id, $bid, $why) Yellow
                if ($created.Raw) {
                    Write-Log "  Response: $($created.Raw)" DarkGray
                }
                continue
            }

            $waitResult = Wait-InstanceReady -ContractId $created.ContractId
            if ($waitResult.Success) {
                return $waitResult
            }

            $why = if ($waitResult.Reason) { $waitResult.Reason } else { "unknown" }
            Write-Log "Instance #$($created.ContractId) did not stabilize ($why)." Yellow

            $failedInstance = if ($waitResult.Instance) {
                $waitResult.Instance
            } else {
                Get-InstanceById -Id $created.ContractId | Select-Object -First 1
            }

            if ($failedInstance) {
                Remove-Instances @($failedInstance)
                Start-Sleep -Seconds 5
            }
        }
    }

    return $null
}





