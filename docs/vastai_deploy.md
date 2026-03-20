# GLM-OCR 401k Service — Vast.ai Deployment

Self-hosted GLM-OCR pipeline: vLLM serves `zai-org/GLM-OCR`, FastAPI wraps it,
accepts PDF → returns table (JSON or XLSX).

---

## 1. Instance Requirements

| Parameter | Value |
|---|---|
| GPU | A100 40/80 GB PCIe or SXM (tested on A100 80GB PCIe) |
| CUDA | ≥ 12.1 (required by vLLM 0.17+) |
| Image | **PyTorch** (Vast built-in template) |
| Disk | ≥ 40 GB (model ~4 GB, vLLM env ~12 GB) |
| Ports | expose **18001** (API); 18080 is internal vLLM, not needed externally |

> RTX 3090/4090 (24 GB) also works — reduce `--gpu-memory-utilization` to `0.80`
> and `--max-model-len` to `16384`.

---

## 2. Vast.ai Template Settings

### Docker Options (ports)

```
-p 18001:18001
```

Do NOT expose 18080 — vLLM listens there but only needs to be reachable from localhost.

### Environment Variables

None required — everything is configured via the startup script and YAML config.

### Onstart Script

Paste as the vast.ai "Onstart Script". It runs once when the instance boots,
installs vLLM (the slow part, ~10 min), and creates the directory structure.
After SSH becomes available you finish setup manually with `deploy.sh`.

```bash
#!/bin/bash
set -euo pipefail

WORKDIR=/root/services/glmocr-401k
VENV=$WORKDIR/.venv

mkdir -p $WORKDIR/{logs,tmp,run}
cd $WORKDIR

python3 -m venv $VENV
source $VENV/bin/activate
pip install -q -U pip setuptools==75.8.0 wheel

# vLLM must be installed first — it pins its own torch version.
# Installing other packages before vLLM causes torch conflicts.
pip install -q -U "vllm>=0.17.0"

echo "==> vLLM installed. SSH in and run deploy.sh to finish."
```

---

## 3. Files to Copy After SSH

After the instance is running (onstart finishes), copy the service files from your local machine.

All source files live in `D:\Work\ML\GLM-OCR\services\glmocr_401k_service\`.

```powershell
$IP   = "<INSTANCE_IP>"
$PORT = "<SSH_PORT>"

# Create dir (in case onstart hasn't finished yet)
ssh -p $PORT root@$IP "mkdir -p /root/services/glmocr-401k"

# Copy service files
scp -P $PORT `
  "D:\Work\ML\GLM-OCR\services\glmocr_401k_service\app.py" `
  "D:\Work\ML\GLM-OCR\services\glmocr_401k_service\config.selfhosted.yaml" `
  "D:\Work\ML\GLM-OCR\services\glmocr_401k_service\requirements.txt" `
  "D:\Work\ML\GLM-OCR\services\glmocr_401k_service\deploy.sh" `
  "root@${IP}:/root/services/glmocr-401k/"
```

---

## 4. Deploy

SSH in and run:

```bash
cd /root/services/glmocr-401k
chmod +x deploy.sh
./deploy.sh
```

`deploy.sh` does:
1. Creates `logs/`, `tmp/`, `run/` dirs
2. Creates/reuses `.venv`
3. `pip install vllm` (skipped fast if onstart already did it)
4. `pip install -r requirements.txt` (remaining packages)
5. Starts vLLM on port **18080** (background, waits up to 10 min for readiness)
6. Starts FastAPI on port **18001** (background, waits for `/health`)
7. Prints summary

vLLM parameters used on a free A100 80 GB:

```
--max-model-len 32768
--max-num-seqs 1
--gpu-memory-utilization 0.85
```

---

## 5. Health Checks

```bash
curl http://127.0.0.1:18001/health
curl http://127.0.0.1:18080/v1/models
```

From Windows (after instance is running with port 18001 exposed):

```
http://<PublicIP>:<MappedPort>/health
```

---

## 6. Test Parsing

### Debug JSON (see all tables + region counts)

```bash
curl -X POST http://127.0.0.1:18001/parse-pdf \
  -F "file=@/path/to/file.pdf" \
  -F "only_investment_tables=false" \
  -F "include_debug=true" \
  -F "response_format=json" \
  -o /tmp/out.json --progress-bar

python3 -c "
import json
d = json.load(open('/tmp/out.json'))
print('page_count:', d.get('page_count'))
print('all_tables_count:', d.get('all_tables_count'))
print('investment_tables_count:', d.get('investment_tables_count'))
print('region_counts:', d.get('region_counts'))
for i, t in enumerate(d.get('tables', [])):
    print(f'  table[{i}]: rows={len(t[\"rows\"])}, reason={t[\"detection_reason\"]}, headers={t[\"headers\"][:4]}')
"
```

### XLSX (investment tables only)

```bash
curl -X POST http://127.0.0.1:18001/parse-pdf \
  -F "file=@/path/to/file.pdf" \
  -F "only_investment_tables=true" \
  -F "response_format=xlsx" \
  -o /tmp/tables.xlsx --progress-bar
```

Download to Windows:

```powershell
scp -P $PORT root@$IP:/tmp/tables.xlsx "D:\Work\ML\GLM-OCR\"
```

---

## 7. Restart After Outbid

Just create a new instance from the same template. After SSH:

```bash
cd /root/services/glmocr-401k
./deploy.sh
```

(Re-copy files from local first if the new instance has a clean disk.)

---

## 8. Manual Service Restart (without deploy.sh)

If vLLM is already running and you only need to restart the API:

```bash
kill $(ss -tlnp | grep ':18001' | grep -oP 'pid=\K[0-9]+') 2>/dev/null; sleep 2

source /root/services/glmocr-401k/.venv/bin/activate
export GLMOCR_CONFIG_PATH=/root/services/glmocr-401k/config.selfhosted.yaml
export GLMOCR_UPLOAD_TMP_DIR=/root/services/glmocr-401k/tmp
export GLMOCR_MAX_PDF_SIZE_MB=150

nohup uvicorn app:app \
  --host 0.0.0.0 --port 18001 --workers 1 \
  > /root/services/glmocr-401k/logs/api.log 2>&1 &
echo $! > /root/services/glmocr-401k/run/api.pid
sleep 12 && curl -s http://127.0.0.1:18001/health
```

---

## 9. Logs

```bash
tail -f /root/services/glmocr-401k/logs/vllm.log
tail -f /root/services/glmocr-401k/logs/api.log
```

GPU usage:

```bash
watch -n 2 nvidia-smi
```

---

## 10. Known Issues & Fixes

These are bugs in `glmocr 0.1.3` that require explicit values in `config.selfhosted.yaml`.
All fixes are already applied in the checked-in config — this section explains why.

### Port conflicts on vast.ai

Vast.ai reserves ports **8080** and **8001** internally.
- vLLM must use `18080`
- FastAPI must use `18001`

### `LayoutConfig has no attribute id2label`

`PPDocLayoutDetector.__init__` reads `config.id2label`. This field is not declared in
`LayoutConfig` pydantic schema, so accessing it raises `AttributeError`.
**Fix:** add full `id2label` mapping (from model's `config.json`) to the `layout:` section.

### `PipelineConfig.region_maxsize` is `null`, causes `Queue(maxsize=None)` crash

`region_maxsize` IS a declared field of `PipelineConfig` with `default: null`.
`getattr(config, "region_maxsize", 800)` returns `null` (attribute exists!), not `800`.
`queue.Queue(maxsize=None)` → `TypeError: '>' not supported between NoneType and int`.
**Fix:** explicitly set `region_maxsize: 800` and `page_maxsize: 100` in the `pipeline:` section.

### `LayoutDetectionThread: 'NoneType' object has no attribute 'items'`

Two fields in `LayoutConfig` have `default: null` but are used without null checks:
- `threshold_by_class` — iterated with `.items()` in `_apply_per_class_threshold`
- `label_task_mapping` — iterated with `.items()` to assign OCR task per region type.
  If empty/null, **all regions are skipped** (task_type stays None → `continue`).

**Fix:** set `threshold_by_class: {}` and provide full `label_task_mapping` with all
PP-DocLayoutV3 label names mapped to task `text`.

### `transformers 5.x` incompatibility warning

`vllm 0.17.1` declares `requires transformers<5`. Installing `glmocr[selfhosted]` afterwards
upgrades transformers to 5.x. This produces a pip warning but **does not break runtime**.
Install order: vllm first, then everything else.

---

## 11. API Reference

| Endpoint | Method | Description |
|---|---|---|
| `/health` | GET | Health check |
| `/parse-pdf` | POST | Parse PDF, return tables |

### `/parse-pdf` form fields

| Field | Type | Default | Description |
|---|---|---|---|
| `file` | file | required | PDF file |
| `only_investment_tables` | bool | `true` | Filter to 401k/investment tables only |
| `include_markdown` | bool | `false` | Include raw markdown in response |
| `include_debug` | bool | `false` | Include region_counts, candidate_regions |
| `response_format` | string | `json` | `json` or `xlsx` |
