# parse_401k.py
import torch
import pymupdf as fitz
import re
import pandas as pd
from PIL import Image
from transformers import AutoProcessor, AutoModelForImageTextToText

MODEL_PATH = "zai-org/GLM-OCR"

# ── 1. Загрузка модели ─────────────────────────────────────────────────────
print("Загрузка GLM-OCR...")
processor = AutoProcessor.from_pretrained(MODEL_PATH)
model = AutoModelForImageTextToText.from_pretrained(
    MODEL_PATH,
    dtype=torch.float16,
    device_map="cuda",
)
model.eval()
print("✓ Модель готова\n")


# ── 2. PDF → изображения ───────────────────────────────────────────────────
def pdf_to_images(pdf_path: str, dpi: int = 200) -> list[Image.Image]:
    doc = fitz.open(pdf_path)
    images = []
    for page in doc:
        mat = fitz.Matrix(dpi / 72, dpi / 72)
        pix = page.get_pixmap(matrix=mat)
        img = Image.frombytes("RGB", [pix.width, pix.height], pix.samples)
        images.append(img)
    doc.close()
    return images


# ── 3. Изображение → Markdown через GLM-OCR ───────────────────────────────
def ocr_image(image: Image.Image) -> str:
    messages = [{
        "role": "user",
        "content": [
            {"type": "image", "url": image},
            {"type": "text",  "text": "Table Recognition:"}
        ]
    }]
    inputs = processor.apply_chat_template(
        messages,
        tokenize=True,
        add_generation_prompt=True,
        return_dict=True,
        return_tensors="pt"
    ).to("cuda")
    inputs.pop("token_type_ids", None)

    with torch.no_grad():
        generated_ids = model.generate(**inputs, max_new_tokens=4096)

    output = processor.decode(
        generated_ids[0][inputs["input_ids"].shape[1]:],
        skip_special_tokens=False
    )
    return output


# ── 4. Markdown → список таблиц (list of DataFrames) ──────────────────────
def markdown_to_dataframes(markdown: str) -> list[pd.DataFrame]:
    tables = []
    current = []

    for line in markdown.splitlines():
        line = line.strip()
        if line.startswith("|") and line.endswith("|"):
            if re.match(r"^\|[\s\-|:]+\|$", line):  # разделитель |---|
                continue
            cells = [c.strip() for c in line.strip("|").split("|")]
            current.append(cells)
        else:
            if len(current) >= 2:
                df = pd.DataFrame(current[1:], columns=current[0])
                tables.append(df)
            current = []

    if len(current) >= 2:
        df = pd.DataFrame(current[1:], columns=current[0])
        tables.append(df)

    return tables


# ── 5. Эвристика: это таблица вложений 401k? ──────────────────────────────
def is_investment_table(df: pd.DataFrame) -> bool:
    keywords = {
        "fund", "investment", "asset", "holding", "security",
        "shares", "units", "market value", "balance", "ticker",
        "symbol", "description", "plan", "account", "value"
    }
    header_text = " ".join(df.columns).lower()
    matches = sum(1 for kw in keywords if kw in header_text)
    return matches >= 1


# ── 6. Главная функция ────────────────────────────────────────────────────
def parse_401k_pdf(pdf_path: str, output_xlsx: str = None):
    print(f"Открываю: {pdf_path}")
    images = pdf_to_images(pdf_path)
    print(f"Страниц: {len(images)}\n")

    for i, image in enumerate(images):
        print(f"  Страница {i+1}/{len(images)}...")
        markdown = ocr_image(image)
        
        # ← ВРЕМЕННО: печатаем сырой вывод модели
        print("=" * 60)
        print("RAW OUTPUT:")
        print(markdown)
        print("=" * 60)
'''
def parse_401k_pdf(pdf_path: str, output_xlsx: str = None):
    print(f"Открываю: {pdf_path}")
    images = pdf_to_images(pdf_path)
    print(f"Страниц: {len(images)}\n")

    found_tables = []

    for i, image in enumerate(images):
        print(f"  Страница {i+1}/{len(images)}...", end=" ")
        markdown = ocr_image(image)

        dataframes = markdown_to_dataframes(markdown)
        investment_dfs = [df for df in dataframes if is_investment_table(df)]

        if investment_dfs:
            print(f"✓ найдено таблиц: {len(investment_dfs)}")
            for df in investment_dfs:
                found_tables.append((i + 1, df))
        else:
            print("— таблиц вложений нет")

    print(f"\nИтого таблиц вложений: {len(found_tables)}")

    if not found_tables:
        print("Таблицы не найдены.")
        return

    # Вывод в консоль
    for page_num, df in found_tables:
        print(f"\n── Страница {page_num} ──────────────────────")
        print(df.to_string(index=False))

    # Сохранение в XLSX
    if output_xlsx is None:
        output_xlsx = pdf_path.replace(".pdf", "_tables.xlsx")

    with pd.ExcelWriter(output_xlsx, engine="openpyxl") as writer:
        for idx, (page_num, df) in enumerate(found_tables):
            sheet = f"Page{page_num}_T{idx+1}"[:31]
            df.to_excel(writer, sheet_name=sheet, index=False)

    print(f"\n✓ Сохранено: {output_xlsx}")
    return found_tables
'''

# ── 7. Запуск ─────────────────────────────────────────────────────────────
if __name__ == "__main__":
    import sys

    if len(sys.argv) < 2:
        print("Использование: python parse_401k.py my_file.pdf")
        print("               python parse_401k.py my_file.pdf output.xlsx")
    else:
        pdf_path = sys.argv[1]
        output   = sys.argv[2] if len(sys.argv) > 2 else None
        parse_401k_pdf(pdf_path, output)