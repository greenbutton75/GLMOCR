# GLM-OCR Vast.ai Auto-Start & Monitor

## Overview

Three scripts manage the Vast.ai lifecycle for GLM-OCR:

- `scripts/vast-glmocr-common.ps1` — shared search, bid, wait, endpoint, and cleanup logic
- `scripts/start-glmocr.ps1` — one-shot startup; reuses a healthy instance by default
- `scripts/monitor-glmocr.ps1` — continuous monitor; recovers automatically after outbid/failure

The current strategy is optimized for robust A100 acquisition, not for the absolute cheapest offer.

## Key Parameters

| Parameter | Value | Notes |
|---|---|---|
| `$TemplateHash` | `19b69f2c0532c31079ee277f74df7877` | Vast.ai template "OCR PyTorch (Vast)" |
| `$InstanceLabel` | `glmocr-401k` | Used to identify only our GLM-OCR instances |
| `$DiskGb` | `50` | Default GLM-OCR disk size; still avoids relying on CLI default disk |
| `$MinReliability` | `0.95` | Local reliability floor after candidate search |
| `$BidFloors` | `0.22, 0.26, 0.32, 0.40` | First level is aligned with the stable manual interruptible price |
| `$BidMultipliers` | `1.15, 1.30, 1.50, 1.75` | Multiplier ladder applied to the offer's `min_bid` |
| `$MaxBidPrice` | `0.50` | Hard safety cap for GPU bid |
| `$ApiPort` | `18001` | FastAPI port |
| `$StableWindowSec` | `120` | Instance must survive 2 minutes after `running + port mapped` |
| `$HealthyCheckIntervalSec` | `300` | Monitor cadence when healthy |
| `$RecoveryCheckIntervalSec` | `60` | Faster retry cadence during recovery |

## Search Queries (priority order)

```
A100_PCIE  num_gpus=1 verified=True rentable=True disk_space>=50
A100_SXM4  num_gpus=1 verified=True rentable=True disk_space>=50
A100_PCIE  num_gpus=1 verified=True rentable=True disk_space>=50 geolocation notin [CN,VN]
A100_SXM4  num_gpus=1 verified=True rentable=True disk_space>=50 geolocation notin [CN,VN]
```

Important details:

- Search is done with `--type bid`, so ranking is based on interruptible offers, not on-demand pricing.
- The script ranks several candidates per query, instead of blindly taking the first cheapest row.
- Unrented offers are preferred over already-rented ones to reduce the chance of immediate outbid.
- Higher reliability, verified hosts, datacenter/static IP, and lower storage-adjusted cost increase the internal score after broader A100 candidate discovery.

## Endpoint File

Both scripts write `scripts/glmocr_endpoint.txt` with the full API base URL, for example:

```text
http://202.103.208.212:32243
```

`batch_ocr.ps1` reads this file automatically if `-ApiUrl` is not passed.
If the file is missing or stale, `batch_ocr.ps1` now falls back to Vast.ai live instance lookup and refreshes the saved endpoint automatically.

## Usage

```powershell
# Start or reuse an instance
.\start-glmocr.ps1

# Force replacement of an existing healthy instance
.\start-glmocr.ps1 -ForceRecreate

# Continuous monitor (run in a separate terminal, leave running)
.\monitor-glmocr.ps1

# Batch OCR after service is ready
.\batch_ocr.ps1
.\batch_ocr.ps1 -InputDir "D:\Work\Riskostat\Corrections\10" -SkipExisting
```

## Current Startup Flow

### `start-glmocr.ps1`

1. Reads existing instances filtered by `label == glmocr-401k`
2. Reuses a running instance instead of destroying it
3. If an instance is still booting, waits for it before creating a duplicate
4. Cleans up dead instances
5. Searches several ranked interruptible offers
6. Tries a bid ladder per offer (`0.22` -> `0.26` -> `0.32` -> `0.40`, or higher if `min_bid * multiplier` requires it)
7. Treats success only after the instance stays alive for 120 seconds with mapped API port

### `monitor-glmocr.ps1`

1. Filters instances by label, not by template fields
2. Removes dead/exited instances
3. Keeps a healthy/running instance untouched
4. Waits if an instance is still starting
5. Starts recovery only when there is no active instance at all
6. Retries recovery every 60 seconds until a stable instance is back

## Why This Is More Robust

### 1. No more destroy-first behavior

Previously, `start-glmocr.ps1` always destroyed old GLM-OCR instances before searching for a new one. That meant a healthy long-running instance could be lost before the replacement was proven stable.

Now the default behavior is:

- reuse a healthy running instance
- wait for an already-starting instance
- only replace when you explicitly pass `-ForceRecreate`

### 2. Explicit disk size

Vast CLI `create instance` defaults to `--disk 10`, while GLM-OCR needs more space than that and the scripts now request `50 GB` by default.

The scripts now pass:

```powershell
--disk 50
```

This keeps price expectations closer to the manual working instance and removes hidden dependence on CLI defaults.

### 3. Search is now aligned with interruptible bidding

Previously the script searched offers without explicitly requesting bid/interruptible pricing and then created a spot instance with `--bid_price`.

Now search uses:

```powershell
vastai search offers ... --type bid --raw
```

This makes the selected offers and the later bid decision part of the same pricing mode.

### 4. Offer choice is based on stability signals

Previously the script effectively chose "the first cheapest offer".

Now the candidate ranking prefers:

- `rented=False` when available
- higher `reliability`
- `verified=True`
- datacenter/static IP hosts
- lower total and storage-adjusted cost

### 5. Bid ladder instead of one fixed multiplier

Previously there was a single `BidMultiplier = 2.50`.

Now each offer is tried with a ladder:

```text
max(min_bid * 1.15, 0.22)
max(min_bid * 1.30, 0.26)
max(min_bid * 1.50, 0.32)
max(min_bid * 1.75, 0.40)
```

That means:

- cheap offers start close to the manual working price level
- hotter offers can still be retried at a higher bid
- the script keeps a hard guardrail via `$MaxBidPrice = 0.50`

### 6. "Ready" now means "survived warmup"

Previously the script considered the job successful as soon as the instance became `running` and the port mapping appeared.

Now an instance must also survive for 120 seconds after that point. If it gets outbid immediately, the script destroys it and tries the next bid/offer automatically.

## Instance Info Reference

When an instance is running, `vastai show instances --raw` exposes the fields used by these scripts:

```json
"ports": {
  "18001/tcp": [{"HostIp": "0.0.0.0", "HostPort": "32243"}],
  "22/tcp":    [{"HostIp": "0.0.0.0", "HostPort": "32528"}]
},
"public_ipaddr": "202.103.208.212",
"ssh_host": "ssh3.vast.ai",
"ssh_port": 17330,
"label": "glmocr-401k"
```

- SSH: `ssh -p <ssh_port> root@<ssh_host>`
- API: `http://<public_ipaddr>:<ports["18001/tcp"][0].HostPort>`

## Notes

- A manually created instance that you want these scripts to manage should use the same label: `glmocr-401k`.
- If you want the scripts to become even more aggressive, the safest next knob to tune is `$BidFloors`, not the search price cap.


