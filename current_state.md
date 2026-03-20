# GLM-OCR 401k Service: Current State

## Задача

Нужно локально или на удаленном GPU-сервере развернуть Python-сервис, который:

- принимает PDF,
- прогоняет его через GLM-OCR,
- выделяет таблицы,
- фильтрует таблицы, похожие на Schedule of Assets / 401(k) investment holdings,
- возвращает JSON или XLSX.

Типичный целевой документ:

- PDF с таблицей вложений пенсионного плана 401(k),
- в PDF может быть несколько таблиц,
- часть таблиц не нужна,
- часть PDF вообще не содержит нужной таблицы,
- иногда страницы повернуты на 90 градусов.

Основной ориентир по нужной таблице:

- `fair value`
- `borrower`
- `identity of issuer`
- `current value`
- `allocation of plan assets`
- типовая структура `Schedule of Assets (Held at End of Year)`
- колонки `(a) ... (e) Current value`


## Что было сделано

В проект добавлен отдельный каталог сервиса:

- [services/glmocr_401k_service/app.py](D:/Work/ML/GLM-OCR/services/glmocr_401k_service/app.py)
- [services/glmocr_401k_service/config.selfhosted.yaml](D:/Work/ML/GLM-OCR/services/glmocr_401k_service/config.selfhosted.yaml)
- [services/glmocr_401k_service/requirements.txt](D:/Work/ML/GLM-OCR/services/glmocr_401k_service/requirements.txt)
- [services/glmocr_401k_service/README.md](D:/Work/ML/GLM-OCR/services/glmocr_401k_service/README.md)

Архитектура сервиса:

1. `vLLM` поднимает модель `zai-org/GLM-OCR`
2. `FastAPI`-обертка принимает PDF по HTTP
3. `GlmOcr(..., mode="selfhosted")` общается с локальным `vLLM`
4. API извлекает таблицы из ответа GLM-OCR
5. API фильтрует таблицы по эвристике 401(k)
6. API возвращает JSON или XLSX


## Что умеет текущий `app.py`

Текущая версия `app.py`:

- принимает PDF через `POST /parse-pdf`
- поддерживает:
  - `only_investment_tables=true|false`
  - `include_markdown=true|false`
  - `include_debug=true|false`
  - `response_format=json|xlsx`
- умеет парсить:
  - pipe-markdown таблицы
  - HTML-таблицы вида `<table>...</table>`
- собирает debug-информацию:
  - `region_counts`
  - `candidate_regions`
  - `markdown_result`
- использует эвристику для investment/401k tables

Эвристика сейчас учитывает:

- `fair value`
- `borrower`
- `identity of issue`
- `current value`
- `allocation of plan assets`
- общий набор keywords:
  - `fund`
  - `investment`
  - `asset`
  - `holding`
  - `security`
  - `shares`
  - `units`
  - `market value`
  - `balance`
  - `ticker`
  - `symbol`
  - `description`
  - `plan`
  - `account`
  - `value`
  - `cost`
  - `principal`
  - `interest`
  - `rate`


## Что делали на сервере Vast.ai

Работа велась на shared A100 машине, где уже был другой GPU-сервис.

Это было важно, потому что:

- нельзя было ломать существующий сервис,
- нельзя было занимать все 80 GB GPU памяти,
- пришлось запускать все изолированно:
  - отдельный каталог
  - отдельный `venv`
  - отдельные порты


## Каталог на сервере

Использовался путь:

```bash
/root/services/glmocr-401k
```

Создание:

```bash
mkdir -p /root/services/glmocr-401k/{logs,tmp,run}
```


## Что копировали на сервер

На сервер были скопированы:

- `app.py`
- `config.selfhosted.yaml`
- `requirements.txt`

Типовые команды с локальной Windows-машины:

```powershell
scp -P 39433 "D:\Work\ML\GLM-OCR\services\glmocr_401k_service\app.py" root@117.18.102.42:/root/services/glmocr-401k/
scp -P 39433 "D:\Work\ML\GLM-OCR\services\glmocr_401k_service\config.selfhosted.yaml" root@117.18.102.42:/root/services/glmocr-401k/
scp -P 39433 "D:\Work\ML\GLM-OCR\services\glmocr_401k_service\requirements.txt" root@117.18.102.42:/root/services/glmocr-401k/
```


## Проверка окружения на сервере

Полезные команды:

```bash
which python3 || true
python3 --version || true
which python3.11 || true
python3.11 --version || true
which nvidia-smi || true
nvidia-smi || true
ss -ltnp | grep -E ':(18080|18001)\b' || true
```


## Python окружение

На сервере был создан отдельный `venv`.

Сначала была попытка использовать `.venv`, затем для чистоты и чтобы не мешать уже существующему окружению был создан новый:

```bash
/root/services/glmocr-401k/.venv2
```

Создание:

```bash
cd /root/services/glmocr-401k
python3 -m venv /root/services/glmocr-401k/.venv2
source /root/services/glmocr-401k/.venv2/bin/activate
python -m pip install -U pip setuptools wheel
```


## Установка зависимостей

Ставились по частям, потому что `pip install -r requirements.txt` привел к dependency conflict.

Сначала:

```bash
python -m pip install -U "vllm>=0.17.0"
```

Потом:

```bash
python -m pip install -U \
  "glmocr==0.1.3" \
  "transformers>=5.3.0" \
  "torchvision>=0.25.0" \
  "sentencepiece>=0.2.0" \
  "accelerate>=1.13.0" \
  "pypdfium2>=5.6.0" \
  fastapi "uvicorn[standard]" python-multipart pandas openpyxl
```

Позже для HTML-таблиц:

```bash
python -m pip install -U lxml
```

Позже для поворота PDF:

```bash
python -m pip install -U pypdf
```


## Почему был OOM, хотя модель 0.9B

Проблема была не в одних весах модели, а в serving profile:

- `vLLM` резервирует память под KV-cache
- у модели очень длинный допустимый контекст
- PDF-страницы превращаются в multimodal input
- на GPU уже работал чужой процесс

Итог:

- при стандартном запуске `vllm` съедал почти всю память A100
- `GlmOcr` не мог нормально работать
- появлялся `CUDA out of memory`


## Какие проблемы были по дороге

### 1. `python: command not found`

На сервере не было `python`, нужно было пользоваться:

```bash
/root/services/glmocr-401k/.venv2/bin/python
```

или через:

```bash
source /root/services/glmocr-401k/.venv2/bin/activate
```


### 2. `vllm: No such file or directory`

Причина:

- `vllm` не был установлен в активный `venv`

Решение:

```bash
python -m pip install -U "vllm>=0.17.0"
```


### 3. Ошибка `LayoutConfig has no attribute id2label`

Причина:

- локальный упрощенный `config.selfhosted.yaml` был слишком коротким,
- в нем не было полного блока layout-настроек.

Решение:

- взять официальный `glmocr/config.yaml`
- поменять только нужные параметры:
  - `maas.enabled: false`
  - `ocr_api.api_port: 18080`
  - таймауты


### 4. API не поднимался из-за timeout к `127.0.0.1:18080`

Причина:

- `GlmOcr` на старте пытался подключиться к `vLLM`,
- а `vLLM` еще не успевал нормально подняться.

Решение:

- увеличить `connect_timeout`
- увеличить `request_timeout`


### 5. `CUDA out of memory`

Причина:

- shared A100,
- уже запущен другой GPU-процесс,
- слишком жирный serving profile `vllm`.

Решение:

- ограничить `vllm`:
  - `--max-model-len`
  - `--gpu-memory-utilization`
  - `--max-num-seqs 1`
  - `--enforce-eager`


### 6. `all_tables_count: 0`, хотя таблица в PDF есть

Сначала это было по двум причинам:

1. сервис искал только pipe-markdown таблицы
2. GLM-OCR на самом деле возвращал HTML `<table>...</table>`

Решение:

- доработать `app.py`
- добавить HTML parsing через `pandas.read_html`


### 7. Таблица находилась, но HTML был оборван

Симптомы:

- `region_counts: {'text': 4, 'table': 1}`
- `has_<table: True`
- `has_</table>: False`

Причина:

- слишком ужатый профиль OCR/generation

Решение:

- увеличить `max_tokens` в `config.selfhosted.yaml`
- увеличить `vllm --max-model-len`


### 8. Таблица находилась, но в XLSX попадал только хвост

Симптомы:

- `all_tables_count: 1`
- `investment_tables_count: 1`
- в XLSX только:
  - `Total Mutual Funds`
  - `Notes Receivable`
- нет основного списка фондов

Причина:

- GLM-OCR увидел длинную таблицу только частично
- вернулся лишь нижний кусок HTML-таблицы

Это текущая главная открытая проблема.


## Рабочий запуск на shared A100

### vLLM

В итоге стабильный запуск делался так:

```bash
cd /root/services/glmocr-401k
source /root/services/glmocr-401k/.venv2/bin/activate

export CUDA_VISIBLE_DEVICES=0
export PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True

nohup vllm serve zai-org/GLM-OCR \
  --host 0.0.0.0 \
  --port 18080 \
  --served-model-name glm-ocr \
  --allowed-local-media-path /root/services/glmocr-401k/tmp \
  --max-model-len 12288 \
  --max-num-seqs 1 \
  --gpu-memory-utilization 0.55 \
  --enforce-eager \
  > /root/services/glmocr-401k/logs/vllm.log 2>&1 &

echo $! > /root/services/glmocr-401k/run/vllm.pid
```

Проверка:

```bash
curl http://127.0.0.1:18080/v1/models
ss -ltnp | grep ':18080\b'
nvidia-smi
```


### API

Запуск:

```bash
cd /root/services/glmocr-401k
source /root/services/glmocr-401k/.venv2/bin/activate

export GLMOCR_CONFIG_PATH=/root/services/glmocr-401k/config.selfhosted.yaml
export GLMOCR_UPLOAD_TMP_DIR=/root/services/glmocr-401k/tmp
export GLMOCR_MAX_PDF_SIZE_MB=150

nohup uvicorn app:app \
  --host 0.0.0.0 \
  --port 18001 \
  --workers 1 \
  > /root/services/glmocr-401k/logs/api.log 2>&1 &

echo $! > /root/services/glmocr-401k/run/api.pid
```

Проверка:

```bash
curl http://127.0.0.1:18001/health
```


## Конфиг `config.selfhosted.yaml`

Ключевые параметры, которые менялись:

- `ocr_api.api_port: 18080`
- `ocr_api.connect_timeout: 180`
- `ocr_api.request_timeout: 900`
- `page_loader.max_tokens: 4096`
- `page_loader.pdf_dpi: 200`
- `page_loader.max_pixels: 33554432`

Важно:

- `max_tokens: 2048` оказался слишком маленьким и приводил к обрыву HTML-таблицы
- `4096` для этого кейса лучше


## Что получилось по MAGNETIKAINC.pdf

По debug JSON был получен результат:

- `region_counts: {'text': 4, 'table': 1}`
- `all_tables_count: 1`
- `investment_tables_count: 1`
- `returned_tables_count: 1`

Значит:

- layout таблицу видит,
- эвристика нужную таблицу тоже видит,
- сервис может вернуть таблицу как объект,
- но фактическая таблица пока неполная.

Пример заголовков, которые удалось поймать в одном из прогонов:

- `(a) Common Collective Trust Fund`
- `(b) Identity of issuer, borrower, lessor, or similar party Common Collective Trust Fund`
- `Cost`
- `(e) Current value`

Но на практике в некоторых XLSX попадал только хвост таблицы:

- `Total Mutual Funds`
- `Notes Receivable`


## Что получилось по TUNNELLCONSULTINGINC_434593.pdf

Файл повернут на 90 градусов.

План обработки:

1. сначала попробовать прогнать как есть
2. если не сработает:
   - сделать rotated copy
   - попробовать `90`
   - попробовать `270`
3. выбрать вариант, где `all_tables_count` больше

Команда для поворота:

```bash
python - <<'PY'
from pypdf import PdfReader, PdfWriter

src = "/root/services/glmocr-401k/TUNNELLCONSULTINGINC_434593.pdf"

for angle, dst in [
    (90, "/root/services/glmocr-401k/TUNNELLCONSULTINGINC_434593_rot90.pdf"),
    (270, "/root/services/glmocr-401k/TUNNELLCONSULTINGINC_434593_rot270.pdf"),
]:
    reader = PdfReader(src)
    writer = PdfWriter()
    for page in reader.pages:
        page.rotate(angle)
        writer.add_page(page)
    with open(dst, "wb") as f:
        writer.write(f)
    print(dst)
PY
```


## Команды обработки PDF

### JSON

```bash
curl -X POST http://127.0.0.1:18001/parse-pdf \
  -F "file=@/path/to/file.pdf" \
  -F "only_investment_tables=true" \
  -F "response_format=json"
```

### Debug JSON

```bash
curl -X POST http://127.0.0.1:18001/parse-pdf \
  -F "file=@/path/to/file.pdf" \
  -F "only_investment_tables=false" \
  -F "include_markdown=true" \
  -F "include_debug=true" \
  -F "response_format=json" \
  -o /path/to/out.json
```

### XLSX

```bash
curl -X POST http://127.0.0.1:18001/parse-pdf \
  -F "file=@/path/to/file.pdf" \
  -F "only_investment_tables=true" \
  -F "response_format=xlsx" \
  --output /path/to/out.xlsx
```


## Как скачать XLSX на локальную Windows-машину

```powershell
scp -P 39433 root@117.18.102.42:/root/services/glmocr-401k/MAGNETIKAINC_tables.xlsx "D:\Work\ML\GLM-OCR\"
```

Если нужно:

```powershell
scp -P 39433 root@117.18.102.42:/root/services/glmocr-401k/TUNNELLCONSULTINGINC_434593_tables.xlsx "D:\Work\ML\GLM-OCR\"
```


## Текущее состояние

Что уже работает:

- self-hosted GLM-OCR через `vLLM`
- API для загрузки PDF
- debug JSON
- HTML table extraction
- filtering инвестиционных таблиц
- генерация XLSX

Что не решено до конца:

- длинные таблицы иногда извлекаются только частично
- для `MAGNETIKAINC.pdf` в некоторых прогонах приходит только нижняя часть таблицы
- для повернутых PDF пока нужен отдельный preprocessing


## Главный вывод

На shared A100 сервис удалось поднять и довести до состояния:

- инфраструктура работает
- API работает
- таблица обнаруживается
- XLSX экспорт работает

Но качество извлечения длинных full-page таблиц пока недостаточно надежно.

Причина уже не в деплое, а в самом extraction pipeline.


## Что стоит сделать завтра на свободной машине

На машине, где не будет других сервисов, нужно начать именно с этого сценария.

### 1. Повторить установку в отдельный каталог

```bash
mkdir -p /root/services/glmocr-401k/{logs,tmp,run}
cd /root/services/glmocr-401k
python3 -m venv .venv
source .venv/bin/activate
python -m pip install -U pip setuptools wheel
```

### 2. Поставить зависимости

```bash
python -m pip install -U "vllm>=0.17.0"
python -m pip install -U \
  "glmocr==0.1.3" \
  "transformers>=5.3.0" \
  "torchvision>=0.25.0" \
  "sentencepiece>=0.2.0" \
  "accelerate>=1.13.0" \
  "pypdfium2>=5.6.0" \
  fastapi "uvicorn[standard]" python-multipart pandas openpyxl lxml pypdf
```

### 3. Взять текущий `app.py`

Нужно использовать текущую версию:

- [services/glmocr_401k_service/app.py](D:/Work/ML/GLM-OCR/services/glmocr_401k_service/app.py)

Потому что именно в ней уже есть:

- 401k-эвристика
- debug API
- HTML table extraction

### 4. Взять официальный `config.yaml` GLM-OCR

И изменить в нем:

- `maas.enabled: false`
- `ocr_api.api_port: 18080`
- `ocr_api.connect_timeout: 180`
- `ocr_api.request_timeout: 900`
- `page_loader.max_tokens: 4096`
- `page_loader.pdf_dpi: 200`
- `page_loader.max_pixels: 33554432`

### 5. На свободной машине попробовать менее зажатый `vllm`

На чистой A100 без соседнего сервиса логично начать так:

```bash
vllm serve zai-org/GLM-OCR \
  --host 0.0.0.0 \
  --port 18080 \
  --served-model-name glm-ocr \
  --allowed-local-media-path /root/services/glmocr-401k/tmp \
  --max-model-len 16384 \
  --max-num-seqs 1 \
  --gpu-memory-utilization 0.80
```

Если память позволяет, можно тестировать:

- `--max-model-len 24576`
- `--gpu-memory-utilization 0.85`

Цель:

- добиться того, чтобы GLM-OCR возвращал полную таблицу, а не только нижний фрагмент.

### 6. Если full-page extraction все равно будет резать таблицу

Следующий инженерный шаг:

- доработать `app.py`
- резать длинный `table` region на 2-3 вертикальных чанка
- OCR-ить куски отдельно
- склеивать строки

Это, скорее всего, и будет наиболее надежным решением для длинных 401(k) schedules.


## Практический план на завтра

1. Развернуть сервис на свободной машине без других GPU-процессов.
2. Сразу стартовать с менее зажатым `vllm`.
3. Проверить `MAGNETIKAINC.pdf`.
4. Проверить `TUNNELLCONSULTINGINC_434593.pdf`.
5. Посмотреть, возвращается ли полная HTML-таблица.
6. Если нет:
   - либо усиливать prompt/config,
   - либо делать chunked extraction длинной таблицы.


## Короткий итог

Сегодня удалось:

- понять архитектуру self-hosted GLM-OCR,
- поднять сервис на shared Vast.ai A100,
- изолировать его от уже работающего сервиса,
- добиться стабильного запуска,
- научить API парсить HTML-таблицы,
- получить обнаружение target-table.

Открытый вопрос на завтра:

- как добиться полного извлечения длинной таблицы Schedule of Assets, а не только ее хвоста.
