# Batch OCR: send all PDFs in $InputDir to GLM-OCR API, save XLSX results.
#
# Usage:
#   .\batch_ocr.ps1                          # reads endpoint from glmocr_endpoint.txt
#   .\batch_ocr.ps1 -ApiUrl "http://202.103.208.212:32243"
#   .\batch_ocr.ps1 -InputDir "D:\Work\Riskostat\Corrections\10"

param(
    [string]$ApiUrl   = "",
    [string]$InputDir = "D:\Work\Riskostat\Corrections\10",
    [string]$OutDir   = "",          # leave empty = save XLSX next to each PDF
    [switch]$SkipExisting            # skip files that already have an XLSX
)

function Test-ApiHealth {
    param([string]$Url)

    if ([string]::IsNullOrWhiteSpace($Url)) { return $false }

    try {
        $null = Invoke-RestMethod -Uri "$Url/health" -Method Get -TimeoutSec 15
        return $true
    } catch {
        return $false
    }
}

# resolve ApiUrl from saved endpoint file if not provided
if (-not $ApiUrl) {
    $endpointFile = Join-Path $PSScriptRoot "glmocr_endpoint.txt"
    if (Test-Path $endpointFile) {
        $ApiUrl = (Get-Content $endpointFile -Raw).Trim()
        if (Test-ApiHealth $ApiUrl) {
            Write-Host "Using saved endpoint: $ApiUrl" -ForegroundColor DarkCyan
        } else {
            Write-Host "Saved endpoint is stale or not ready yet, resolving live endpoint from Vast.ai..." -ForegroundColor DarkYellow
            $ApiUrl = ""
        }
    }

    if (-not $ApiUrl) {
        . (Join-Path $PSScriptRoot "vast-glmocr-common.ps1")
        $resolved = Resolve-ApiUrl -TimeoutSec 180 -PollSec 5
        if ($resolved.Success -and $resolved.ApiUrl) {
            $ApiUrl = $resolved.ApiUrl
            Write-Host "Using live endpoint: $ApiUrl" -ForegroundColor DarkCyan
        } else {
            Write-Error "Could not resolve a live GLM-OCR endpoint from Vast.ai. Start or monitor the instance first."
            exit 1
        }
    }
}

$ErrorActionPreference = "Stop"

# ── resolve output dir ────────────────────────────────────────────────────────
if ($OutDir -ne "" -and -not (Test-Path $OutDir)) {
    New-Item -ItemType Directory -Path $OutDir | Out-Null
}

# ── collect PDFs ──────────────────────────────────────────────────────────────
$pdfs = Get-ChildItem -Path $InputDir -Filter "*.pdf" | Sort-Object Name
if ($pdfs.Count -eq 0) {
    Write-Host "No PDF files found in $InputDir" -ForegroundColor Red
    exit 1
}

Write-Host "Found $($pdfs.Count) PDF files in $InputDir"
Write-Host "API: $ApiUrl"
Write-Host ""

$ok = 0; $fail = 0; $skip = 0
$failedFiles = @()

foreach ($pdf in $pdfs) {
    $stem     = [System.IO.Path]::GetFileNameWithoutExtension($pdf.Name)
    $xlsxName = "${stem}_tables.xlsx"
    $xlsxPath = if ($OutDir -ne "") { Join-Path $OutDir $xlsxName } `
                else { Join-Path $pdf.DirectoryName $xlsxName }

    # skip if already done
    if ($SkipExisting -and (Test-Path $xlsxPath)) {
        Write-Host "[$($ok+$fail+$skip+1)/$($pdfs.Count)] SKIP  $($pdf.Name)" -ForegroundColor DarkGray
        $skip++
        continue
    }

    Write-Host "[$($ok+$fail+$skip+1)/$($pdfs.Count)] $($pdf.Name) ..." -NoNewline

    try {
        # curl is available on Windows 10/11 natively
        $result = & curl.exe -s -w "%{http_code}" `
            -X POST "$ApiUrl/parse-pdf" `
            -F "file=@`"$($pdf.FullName)`"" `
            -F "only_investment_tables=true" `
            -F "response_format=xlsx" `
            -o "$xlsxPath" `
            --max-time 600

        $httpCode = $result.Trim()

        if ($httpCode -eq "200" -and (Test-Path $xlsxPath) -and (Get-Item $xlsxPath).Length -gt 0) {
            $sizeKb = [math]::Round((Get-Item $xlsxPath).Length / 1KB, 1)
            Write-Host " OK (${sizeKb} KB)" -ForegroundColor Green
            $ok++
        } else {
            # API returned error — remove empty/error file
            if (Test-Path $xlsxPath) { Remove-Item $xlsxPath -Force }
            Write-Host " FAIL (HTTP $httpCode)" -ForegroundColor Red
            $fail++
            $failedFiles += $pdf.Name
        }
    } catch {
        if (Test-Path $xlsxPath) { Remove-Item $xlsxPath -Force }
        Write-Host " ERROR: $_" -ForegroundColor Red
        $fail++
        $failedFiles += $pdf.Name
    }
}

# ── summary ───────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "=============================="
Write-Host " Done: $ok OK  |  $fail failed  |  $skip skipped"
Write-Host "=============================="

if ($failedFiles.Count -gt 0) {
    Write-Host ""
    Write-Host "Failed files:" -ForegroundColor Red
    $failedFiles | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
}
