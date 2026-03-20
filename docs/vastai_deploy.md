# GLM-OCR 401k Service — Vast.ai Deployment

Self-hosted GLM-OCR pipeline: vLLM serves `zai-org/GLM-OCR`, FastAPI wraps it,
accepts PDF → returns table (JSON or XLSX).

Repo: https://github.com/greenbutton75/GLMOCR

---

## 1. Instance Requirements

| Parameter | Value |
|---|---|
| GPU | A100 40/80 GB PCIe or SXM (recommended; tested on A100 80GB PCIe) |
| CUDA | ≥ 12.1 (required by vLLM 0.17+) |
| Image | **PyTorch** (Vast built-in template) |
| Disk | ≥ 40 GB (model ~4 GB, vLLM env ~12 GB) |
| Ports | expose **18001** (API); 18080 is internal vLLM, not needed externally |

> Current production recommendation: use A100 only. RTX 3090/4090 can help with
> debugging bring-up, but quality and runtime stability were not good enough for
> real OCR batches.

---

## 2. Vast.ai Template Settings

### Docker Options (ports)

```
-p 18001:18001
```

Do NOT expose 18080 — vLLM listens there but only needs to be reachable from localhost.

### Environment Variables

None required.

### Onstart Script

Paste this as the vast.ai **Onstart Script**.
It clones the repo, installs everything, and starts both services automatically.
No manual steps needed after instance boot.

```bash
#!/bin/bash
set -euo pipefail

REPO=https://github.com/greenbutton75/GLMOCR.git
CLONE_DIR=/root/GLMOCR
SERVICE_DIR=$CLONE_DIR/services/glmocr_401k_service

# Clone or update repo
if [ -d "$CLONE_DIR/.git" ]; then
    echo "==> Updating repo..."
    cd $CLONE_DIR && git pull
else
    echo "==> Cloning repo..."
    git clone $REPO $CLONE_DIR
fi

chmod +x $SERVICE_DIR/deploy.sh
$SERVICE_DIR/deploy.sh
```

That's it — the instance is fully ready when `deploy.sh` finishes (~15 min on first boot
due to model download; ~5 min on subsequent boots if disk is preserved).

---

### OCR Quality Notes

Current best-tested defaults in `config.selfhosted.yaml`:

- `page_loader.pdf_dpi: 300`
- `page_loader.image_format: PNG`
- `page_loader.max_tokens: 12288`
- `result_formatter.min_overlap_ratio: 0.7`

These settings were validated on a live A100 instance against a difficult Schedule H PDF (`YUASABATTERYINC_415776.pdf`) and gave the best overall balance.

Important findings from that A/B test:

- `300 DPI + PNG` clearly reduced row/word merging versus `200 DPI + JPEG`.
- Raising `max_tokens` to `16384` did not produce a meaningful improvement over `12288` for the long schedule table.
- Mapping `table` regions globally to the fixed prompt `Table Recognition:` improved some simpler tables, but made the long Schedule H table worse. For this service, the current recommendation is to keep the generic prompt path.

If long schedules still collapse rows, the next step is not arbitrary prompt tuning, but chunked extraction of tall detected table regions or a born-digital PDF text-layer fallback.

## 3. Verify After Boot

Check in vast.ai UI that the instance shows "Running", then from Windows:

```powershell
# Replace IP and PORT with values from vast.ai "IP & Port Info"
curl.exe -s "http://<PublicIP>:<MappedPort>/health"
# Expected: {"status":"ok","config_path":...}
```

Or from SSH:

```bash
curl http://127.0.0.1:18001/health
curl http://127.0.0.1:18080/v1/models
```

---

## 4. Run Batch OCR (Windows)

Script: `D:\Work\ML\GLM-OCR\scripts\batch_ocr.ps1`

```powershell
# Auto-resolve current live endpoint from glmocr_endpoint.txt or Vast.ai
.\batch_ocr.ps1 -InputDir "D:\Work\Riskostat\Corrections\10"

# Skip already-processed files on re-run
.\batch_ocr.ps1 -SkipExisting

# Save XLSX to a separate folder
.\batch_ocr.ps1 -InputDir "D:\Work\Riskostat\Corrections\10" `
  -OutDir "D:\Work\Riskostat\Corrections\10\xlsx_results"
```

---

## 5. Test Single PDF

### Debug JSON

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

### XLSX

```bash
curl -X POST http://127.0.0.1:18001/parse-pdf \
  -F "file=@/path/to/file.pdf" \
  -F "only_investment_tables=true" \
  -F "response_format=xlsx" \
  -o /tmp/tables.xlsx --progress-bar
```

---

## 6. Restart After Outbid (disk preserved)

If vast.ai recovered the instance with existing disk, services were killed — re-run:

```bash
/root/GLMOCR/services/glmocr_401k_service/deploy.sh
```

If disk was wiped (brand new instance): Onstart Script handles everything automatically.

---

## 7. Update Service Files

Push changes from local:

```powershell
cd "D:\Work\ML\GLM-OCR"
git add -A && git commit -m "update" && git push
```

Pull and restart on server:

```bash
cd /root/GLMOCR && git pull
/root/GLMOCR/services/glmocr_401k_service/deploy.sh
```

---

## 8. Manual API Restart Only (vLLM already running)

```bash
kill $(ss -tlnp | grep ':18001' | grep -oP 'pid=\K[0-9]+') 2>/dev/null; sleep 2

source /root/GLMOCR/services/glmocr_401k_service/.venv/bin/activate
export GLMOCR_CONFIG_PATH=/root/GLMOCR/services/glmocr_401k_service/config.selfhosted.yaml
export GLMOCR_UPLOAD_TMP_DIR=/root/GLMOCR/services/glmocr_401k_service/tmp
export GLMOCR_MAX_PDF_SIZE_MB=150

nohup uvicorn app:app \
  --host 0.0.0.0 --port 18001 --workers 1 \
  > /root/GLMOCR/services/glmocr_401k_service/logs/api.log 2>&1 &
echo $! > /root/GLMOCR/services/glmocr_401k_service/run/api.pid
sleep 12 && curl -s http://127.0.0.1:18001/health
```

---

## 9. Logs

```bash
tail -f /root/GLMOCR/services/glmocr_401k_service/logs/vllm.log
tail -f /root/GLMOCR/services/glmocr_401k_service/logs/api.log
watch -n 2 nvidia-smi
```

---

## 10. Known Issues & Fixes (glmocr 0.1.3 bugs)

All fixes already applied in `config.selfhosted.yaml` — this section explains why.

### Port conflicts on vast.ai

Vast.ai occupies ports **8080** and **8001** internally.
- vLLM must use `18080`
- FastAPI must use `18001`

### `LayoutConfig has no attribute id2label`

`PPDocLayoutDetector.__init__` reads `config.id2label`. Field not declared in pydantic schema
→ `AttributeError`. **Fix:** add full `id2label` mapping (from model's HF `config.json`) to
the `layout:` section in YAML.

### `Queue(maxsize=None)` crash

`PipelineConfig.region_maxsize` is a declared field with `default: null`. `getattr(..., 800)`
returns `null` (attribute exists!), not `800`. `Queue(maxsize=None)` → TypeError.
**Fix:** explicitly set `region_maxsize: 800` and `page_maxsize: 100` under `pipeline:`.

### `LayoutDetectionThread: 'NoneType' has no attribute 'items'`

Two `LayoutConfig` fields have `default: null` but are iterated without null checks:
- `threshold_by_class` — fix: `threshold_by_class: {}`
- `label_task_mapping` — if null/empty, ALL regions are skipped (task_type=None → continue).
  Fix: map all PP-DocLayoutV3 labels to task `text` (see config).

### `transformers 5.x` incompatibility warning

`vllm 0.17.1` requires `transformers<5`, but `glmocr[selfhosted]` installs 5.x.
This is a pip warning only — runtime works fine. Install order: vllm first, then rest.

### `Could not import module "app"` on API start

`nohup uvicorn app:app` looks for `app.py` in the process working directory (`cwd`).
When the Onstart Script calls `deploy.sh`, cwd is `/root`, not the service directory.
**Fix:** `--app-dir "$WORKDIR"` in the uvicorn command (already applied in `deploy.sh`).

### `cudaErrorContained` — hardware GPU error

```
torch.AcceleratorError: CUDA error: Invalid access of peer GPU memory over nvlink or a hardware error
```

Bad VRAM or NVLink state left by a previous tenant. Not fixable in software.
**Fix:** destroy the instance, rent a new one. Onstart Script handles full setup automatically.

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



