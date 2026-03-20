# GLM-OCR 401k PDF Service

Этот каталог содержит тонкую API-обертку вокруг self-hosted GLM-OCR:

- на вход принимает PDF,
- прогоняет его через GLM-OCR SDK,
- извлекает найденные markdown-таблицы,
- отфильтровывает таблицы, похожие на investment holdings / 401k positions,
- возвращает JSON или XLSX.

## Что поднимается

1. `vLLM` с моделью `zai-org/GLM-OCR` на порту `8080`
2. `FastAPI`-сервис на порту `8001`

## Файлы

- `app.py` - API для загрузки PDF и возврата таблиц
- `config.selfhosted.yaml` - конфиг GLM-OCR SDK
- `requirements.txt` - Python-зависимости
- `glmocr-vllm.service` - systemd unit для vLLM
- `glmocr-401k.service` - systemd unit для API

## Быстрый запуск на Ubuntu + A100

```bash
sudo useradd -r -m -d /opt/services/glmocr-401k -s /bin/bash ocr || true
sudo mkdir -p /opt/services/glmocr-401k
sudo chown -R ocr:ocr /opt/services/glmocr-401k
```

Сначала скопируйте содержимое этого каталога на сервер в `/opt/services/glmocr-401k/`, а затем установите окружение:

```bash
sudo -u ocr bash -lc '
cd /opt/services/glmocr-401k
python3.11 -m venv .venv
source .venv/bin/activate
python -m pip install -U pip setuptools wheel
python -m pip install -r requirements.txt
mkdir -p tmp .cache/huggingface
'
```

Если `python3.11` ещё не установлен:

```bash
sudo apt-get update
sudo apt-get install -y python3.11 python3.11-venv
```

## Ручной запуск без systemd

В одном терминале:

```bash
cd /opt/services/glmocr-401k
source .venv/bin/activate
mkdir -p tmp .cache/huggingface
export CUDA_VISIBLE_DEVICES=0
vllm serve zai-org/GLM-OCR \
  --host 0.0.0.0 \
  --port 8080 \
  --served-model-name glm-ocr \
  --allowed-local-media-path /opt/services/glmocr-401k/tmp
```

Во втором терминале:

```bash
cd /opt/services/glmocr-401k
source .venv/bin/activate
export GLMOCR_CONFIG_PATH=/opt/services/glmocr-401k/config.selfhosted.yaml
export GLMOCR_UPLOAD_TMP_DIR=/opt/services/glmocr-401k/tmp
uvicorn app:app --host 0.0.0.0 --port 8001 --workers 1
```

## Проверка

```bash
curl http://127.0.0.1:8001/health
```

JSON-ответ с найденными таблицами:

```bash
curl -X POST http://127.0.0.1:8001/parse-pdf \
  -F "file=@/opt/data/sample.pdf" \
  -F "only_investment_tables=true" \
  -F "include_markdown=false" \
  -F "response_format=json"
```

XLSX-ответ:

```bash
curl -X POST http://127.0.0.1:8001/parse-pdf \
  -F "file=@/opt/data/sample.pdf" \
  -F "only_investment_tables=true" \
  -F "response_format=xlsx" \
  --output sample_tables.xlsx
```

## Запуск через systemd

```bash
sudo cp glmocr-vllm.service /etc/systemd/system/
sudo cp glmocr-401k.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now glmocr-vllm.service
sudo systemctl enable --now glmocr-401k.service
```

Проверка логов:

```bash
sudo journalctl -u glmocr-vllm.service -f
sudo journalctl -u glmocr-401k.service -f
```
