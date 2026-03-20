#!/usr/bin/env bash
# One-shot deploy script for GLM-OCR 401k service on a fresh vast.ai instance.
# Works from any location — WORKDIR is derived from the script's own directory.
#
# Usage:
#   chmod +x deploy.sh && ./deploy.sh

set -euo pipefail

WORKDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV="$WORKDIR/.venv"
LOG_DIR="$WORKDIR/logs"
TMP_DIR="$WORKDIR/tmp"
RUN_DIR="$WORKDIR/run"

VLLM_PORT=18080
API_PORT=18001
VLLM_MODEL="zai-org/GLM-OCR"
VLLM_MAX_MODEL_LEN=32768
VLLM_GPU_MEM=0.85

# ── 1. directories ─────────────────────────────────────────────────────────────
echo "==> Creating directories..."
mkdir -p "$LOG_DIR" "$TMP_DIR" "$RUN_DIR"

# ── 2. python venv ─────────────────────────────────────────────────────────────
if [ ! -f "$VENV/bin/python" ]; then
    echo "==> Creating venv at $VENV..."
    python3 -m venv "$VENV"
fi

source "$VENV/bin/activate"
pip install -q -U pip setuptools wheel

# ── 3. install vllm first (pins its own torch; must come before everything else) ─
echo "==> Installing vllm..."
pip install -q -U "vllm>=0.17.0"

# ── 4. install remaining requirements ─────────────────────────────────────────
echo "==> Installing service requirements..."
pip install -q -U -r "$WORKDIR/requirements.txt"

# ── 5. kill any stale processes ───────────────────────────────────────────────
echo "==> Stopping any existing processes..."
for pidfile in "$RUN_DIR/vllm.pid" "$RUN_DIR/api.pid"; do
    if [ -f "$pidfile" ]; then
        old_pid=$(cat "$pidfile")
        kill "$old_pid" 2>/dev/null || true
        rm -f "$pidfile"
    fi
done
sleep 2

# ── 6. start vLLM ─────────────────────────────────────────────────────────────
echo "==> Starting vLLM on port $VLLM_PORT..."
export CUDA_VISIBLE_DEVICES=0
export PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True
export HF_HOME="$WORKDIR/.cache/huggingface"
export TRANSFORMERS_CACHE="$WORKDIR/.cache/huggingface"

nohup vllm serve "$VLLM_MODEL" \
    --host 0.0.0.0 \
    --port "$VLLM_PORT" \
    --served-model-name glm-ocr \
    --allowed-local-media-path "$TMP_DIR" \
    --max-model-len "$VLLM_MAX_MODEL_LEN" \
    --max-num-seqs 1 \
    --gpu-memory-utilization "$VLLM_GPU_MEM" \
    > "$LOG_DIR/vllm.log" 2>&1 &

VLLM_PID=$!
echo "$VLLM_PID" > "$RUN_DIR/vllm.pid"
echo "    vLLM pid=$VLLM_PID, logs: $LOG_DIR/vllm.log"

# ── 7. wait for vLLM to be ready ──────────────────────────────────────────────
echo "==> Waiting for vLLM to be ready (up to 10 min)..."
MAX_WAIT=600
INTERVAL=10
elapsed=0
while true; do
    if curl -sf "http://127.0.0.1:$VLLM_PORT/v1/models" > /dev/null 2>&1; then
        echo "    vLLM is ready."
        break
    fi
    if ! kill -0 "$VLLM_PID" 2>/dev/null; then
        echo "ERROR: vLLM process died. Check $LOG_DIR/vllm.log"
        tail -40 "$LOG_DIR/vllm.log"
        exit 1
    fi
    if [ "$elapsed" -ge "$MAX_WAIT" ]; then
        echo "ERROR: vLLM did not become ready within ${MAX_WAIT}s. Check $LOG_DIR/vllm.log"
        tail -40 "$LOG_DIR/vllm.log"
        exit 1
    fi
    echo "    ...waiting (${elapsed}s elapsed)"
    sleep "$INTERVAL"
    elapsed=$((elapsed + INTERVAL))
done

# ── 8. start FastAPI ───────────────────────────────────────────────────────────
echo "==> Starting FastAPI on port $API_PORT..."
export GLMOCR_CONFIG_PATH="$WORKDIR/config.selfhosted.yaml"
export GLMOCR_UPLOAD_TMP_DIR="$TMP_DIR"
export GLMOCR_MAX_PDF_SIZE_MB=150

nohup uvicorn app:app \
    --app-dir "$WORKDIR" \
    --host 0.0.0.0 \
    --port "$API_PORT" \
    --workers 1 \
    > "$LOG_DIR/api.log" 2>&1 &

API_PID=$!
echo "$API_PID" > "$RUN_DIR/api.pid"
echo "    API pid=$API_PID, logs: $LOG_DIR/api.log"

# ── 9. wait for API health ─────────────────────────────────────────────────────
echo "==> Waiting for API health check..."
for i in $(seq 1 30); do
    if curl -sf "http://127.0.0.1:$API_PORT/health" > /dev/null 2>&1; then
        echo "    API is ready."
        break
    fi
    if ! kill -0 "$API_PID" 2>/dev/null; then
        echo "ERROR: API process died. Check $LOG_DIR/api.log"
        tail -40 "$LOG_DIR/api.log"
        exit 1
    fi
    sleep 2
done

# ── 10. summary ────────────────────────────────────────────────────────────────
echo ""
echo "=============================="
echo " Service is UP"
echo "=============================="
echo " vLLM:  http://0.0.0.0:$VLLM_PORT  (pid $(cat $RUN_DIR/vllm.pid))"
echo " API:   http://0.0.0.0:$API_PORT   (pid $(cat $RUN_DIR/api.pid))"
echo ""
echo " Health check:"
curl -s "http://127.0.0.1:$API_PORT/health" | python3 -m json.tool 2>/dev/null || \
    curl -s "http://127.0.0.1:$API_PORT/health"
echo ""
echo " Test parse (replace path with your PDF):"
echo "   curl -X POST http://127.0.0.1:$API_PORT/parse-pdf \\"
echo "     -F 'file=@/root/services/glmocr-401k/test.pdf' \\"
echo "     -F 'include_debug=true' \\"
echo "     -F 'response_format=json' | python3 -m json.tool | head -60"
echo ""
echo " Logs:"
echo "   tail -f $LOG_DIR/vllm.log"
echo "   tail -f $LOG_DIR/api.log"
