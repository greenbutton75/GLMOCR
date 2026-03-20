from __future__ import annotations

import io
import os
import re
import threading
from collections import Counter
from contextlib import asynccontextmanager
from pathlib import Path
from tempfile import NamedTemporaryFile
from typing import Any

import pandas as pd
from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from fastapi.responses import JSONResponse, StreamingResponse
from glmocr import GlmOcr


BASE_DIR = Path(__file__).resolve().parent
CONFIG_PATH = Path(os.getenv("GLMOCR_CONFIG_PATH", BASE_DIR / "config.selfhosted.yaml"))
TMP_DIR = Path(os.getenv("GLMOCR_UPLOAD_TMP_DIR", BASE_DIR / "tmp"))
MAX_PDF_SIZE_MB = int(os.getenv("GLMOCR_MAX_PDF_SIZE_MB", "100"))

PARSER_LOCK = threading.Lock()
PARSER: GlmOcr | None = None


def _normalize_text(value: str) -> str:
    return re.sub(r"\s+", " ", value).strip().lower()


def _count_occurrences(text: str, needle: str) -> int:
    return text.count(needle)


def _split_markdown_tables(markdown: str) -> list[str]:
    tables: list[str] = []
    current: list[str] = []

    for raw_line in markdown.splitlines():
        line = raw_line.strip()
        if line.startswith("|") and line.endswith("|"):
            current.append(line)
            continue

        if len(current) >= 2:
            tables.append("\n".join(current))
        current = []

    if len(current) >= 2:
        tables.append("\n".join(current))

    return tables


def _split_html_tables(text: str) -> list[str]:
    return re.findall(r"(<table\b.*?</table>)", text, flags=re.IGNORECASE | re.DOTALL)


def _markdown_table_to_frame(markdown_table: str) -> pd.DataFrame | None:
    rows: list[list[str]] = []

    for line in markdown_table.splitlines():
        if re.match(r"^\|[\s\-:|]+\|$", line.strip()):
            continue
        cells = [cell.strip() for cell in line.strip().strip("|").split("|")]
        rows.append(cells)

    if len(rows) < 2:
        return None

    width = max(len(row) for row in rows)
    normalized_rows = [row + [""] * (width - len(row)) for row in rows]
    header = normalized_rows[0]
    body = normalized_rows[1:]
    return pd.DataFrame(body, columns=header)


def _normalize_frame(df: pd.DataFrame) -> pd.DataFrame | None:
    if df is None or df.empty:
        return None

    normalized = df.copy().fillna("")

    if isinstance(normalized.columns, pd.MultiIndex):
        normalized.columns = [
            " ".join(str(part).strip() for part in column if str(part).strip()).strip()
            for column in normalized.columns.to_flat_index()
        ]
    else:
        normalized.columns = [str(column).strip() for column in normalized.columns]

    normalized = normalized.astype(str)
    if normalized.shape[1] == 0:
        return None
    return normalized


def _html_table_to_frames(html_table: str) -> list[pd.DataFrame]:
    try:
        frames = pd.read_html(io.StringIO(html_table))
    except ValueError:
        return []

    normalized_frames: list[pd.DataFrame] = []
    for frame in frames:
        normalized = _normalize_frame(frame)
        if normalized is not None:
            normalized_frames.append(normalized)
    return normalized_frames


def _investment_match_reason(text: str) -> str | None:
    text = _normalize_text(text)
    if not text:
        return None

    is_borrower = "borrower" in text and (
        len(text) < 200 or "cost" in text or "value" in text
    )

    if "fair value" in text:
        return "fair_value"
    if is_borrower:
        return "borrower"
    if "identity of issue" in text:
        return "identity_of_issue"
    if "current value" in text and len(text) < 400:
        return "current_value"
    if "allocation of plan assets" in text and _count_occurrences(text, "value") >= 3:
        return "allocation_of_plan_assets"

    generic_keywords = {
        "fund",
        "investment",
        "asset",
        "holding",
        "security",
        "shares",
        "units",
        "market value",
        "balance",
        "ticker",
        "symbol",
        "description",
        "plan",
        "account",
        "value",
        "cost",
        "principal",
        "interest",
        "rate",
    }
    matches = sum(1 for keyword in generic_keywords if keyword in text)
    if matches >= 3:
        return "generic_keyword_match"

    return None


def _is_investment_table(df: pd.DataFrame) -> bool:
    normalized_df = _normalize_frame(df)
    if normalized_df is None:
        return False

    header_text = " ".join(str(column) for column in normalized_df.columns)
    sample_rows = " ".join(
        str(value) for value in normalized_df.head(5).to_numpy().flatten().tolist()
    )
    return _investment_match_reason(f"{header_text} {sample_rows}") is not None


def _text_table_to_frame(text: str) -> pd.DataFrame | None:
    lines = [line.strip() for line in text.splitlines() if line.strip()]
    rows: list[list[str]] = []

    for line in lines:
        cells = [
            cell.strip()
            for cell in re.split(r"\t+|\s{2,}", line)
            if cell.strip()
        ]
        if len(cells) >= 2:
            rows.append(cells)

    if len(rows) < 2:
        return None

    width = max(len(row) for row in rows)
    if width < 2:
        return None

    normalized_rows = [row + [""] * (width - len(row)) for row in rows]
    header = normalized_rows[0]
    body = normalized_rows[1:]
    return pd.DataFrame(body, columns=header)


def _frame_to_payload(
    df: pd.DataFrame,
    *,
    page: int | None,
    table_index: int,
    bbox_2d: list[int] | None,
    markdown: str,
    source_label: str,
    detection_reason: str | None,
) -> dict[str, Any]:
    clean_df = _normalize_frame(df)
    if clean_df is None:
        clean_df = pd.DataFrame()

    return {
        "page": page,
        "table_index": table_index,
        "bbox_2d": bbox_2d,
        "source_label": source_label,
        "detection_reason": detection_reason,
        "headers": [str(column) for column in clean_df.columns],
        "rows": clean_df.astype(str).to_dict(orient="records"),
        "is_investment_candidate": _is_investment_table(clean_df),
        "markdown": markdown,
    }


def _collect_debug_regions(parse_result: Any) -> tuple[dict[str, int], list[dict[str, Any]]]:
    label_counter: Counter[str] = Counter()
    candidate_regions: list[dict[str, Any]] = []
    page_results = getattr(parse_result, "json_result", []) or []

    for page_index, regions in enumerate(page_results, start=1):
        for region in regions:
            label = str(region.get("label", "unknown"))
            content = str(region.get("content", "") or "").strip()
            label_counter[label] += 1
            reason = _investment_match_reason(content)
            if reason:
                candidate_regions.append(
                    {
                        "page": page_index,
                        "label": label,
                        "bbox_2d": region.get("bbox_2d"),
                        "reason": reason,
                        "preview": content[:1000],
                    }
                )

    return dict(label_counter), candidate_regions


def _extract_tables(parse_result: Any) -> list[dict[str, Any]]:
    tables: list[dict[str, Any]] = []
    page_results = getattr(parse_result, "json_result", []) or []

    for page_index, regions in enumerate(page_results, start=1):
        table_counter = 0

        for region in regions:
            label = str(region.get("label", "unknown"))
            region_content = str(region.get("content", "") or "").strip()
            reason = _investment_match_reason(region_content)

            for html_table in _split_html_tables(region_content):
                for df in _html_table_to_frames(html_table):
                    table_counter += 1
                    tables.append(
                        _frame_to_payload(
                            df,
                            page=page_index,
                            table_index=table_counter,
                            bbox_2d=region.get("bbox_2d"),
                            markdown=html_table,
                            source_label=label,
                            detection_reason=reason,
                        )
                    )

            for block in _split_markdown_tables(region_content):
                df = _markdown_table_to_frame(block)
                if df is None:
                    continue
                table_counter += 1
                tables.append(
                    _frame_to_payload(
                        df,
                        page=page_index,
                        table_index=table_counter,
                        bbox_2d=region.get("bbox_2d"),
                        markdown=block,
                        source_label=label,
                        detection_reason=reason,
                    )
                )

            if reason and label != "table":
                df = _text_table_to_frame(region_content)
                if df is None:
                    continue
                table_counter += 1
                tables.append(
                    _frame_to_payload(
                        df,
                        page=page_index,
                        table_index=table_counter,
                        bbox_2d=region.get("bbox_2d"),
                        markdown=region_content,
                        source_label=label,
                        detection_reason=reason,
                    )
                )

    if tables:
        return tables

    markdown_result = str(getattr(parse_result, "markdown_result", "") or "").strip()
    table_counter = 0

    for html_table in _split_html_tables(markdown_result):
        for df in _html_table_to_frames(html_table):
            table_counter += 1
            tables.append(
                _frame_to_payload(
                    df,
                    page=None,
                    table_index=table_counter,
                    bbox_2d=None,
                    markdown=html_table,
                    source_label="markdown_result",
                    detection_reason=_investment_match_reason(html_table),
                )
            )

    for block in _split_markdown_tables(markdown_result):
        df = _markdown_table_to_frame(block)
        if df is None:
            continue
        table_counter += 1
        tables.append(
            _frame_to_payload(
                df,
                page=None,
                table_index=table_counter,
                bbox_2d=None,
                markdown=block,
                source_label="markdown_result",
                detection_reason=_investment_match_reason(block),
            )
        )

    return tables


def _tables_to_xlsx_bytes(tables: list[dict[str, Any]]) -> bytes:
    output = io.BytesIO()

    with pd.ExcelWriter(output, engine="openpyxl") as writer:
        if not tables:
            pd.DataFrame([{"message": "No tables found"}]).to_excel(
                writer,
                sheet_name="NoTables",
                index=False,
            )
        else:
            for index, table in enumerate(tables, start=1):
                df = pd.DataFrame(table["rows"])
                page = table["page"] if table["page"] is not None else "NA"
                sheet_name = f"Page{page}_T{index}"[:31]
                df.to_excel(writer, sheet_name=sheet_name, index=False)

    return output.getvalue()


@asynccontextmanager
async def lifespan(_: FastAPI):
    global PARSER

    TMP_DIR.mkdir(parents=True, exist_ok=True)
    PARSER = GlmOcr(config_path=str(CONFIG_PATH), mode="selfhosted")
    try:
        yield
    finally:
        if PARSER is not None:
            PARSER.close()
            PARSER = None


app = FastAPI(
    title="GLM-OCR 401k PDF Service",
    version="0.1.0",
    lifespan=lifespan,
)


@app.get("/health")
def health() -> dict[str, Any]:
    return {
        "status": "ok",
        "config_path": str(CONFIG_PATH),
        "tmp_dir": str(TMP_DIR),
    }


@app.post("/parse-pdf")
async def parse_pdf(
    file: UploadFile = File(...),
    only_investment_tables: bool = Form(True),
    include_markdown: bool = Form(False),
    include_debug: bool = Form(False),
    response_format: str = Form("json"),
):
    if not file.filename or not file.filename.lower().endswith(".pdf"):
        raise HTTPException(status_code=400, detail="Only PDF files are supported.")

    if PARSER is None:
        raise HTTPException(status_code=503, detail="Parser is not initialized yet.")

    pdf_bytes = await file.read()
    max_bytes = MAX_PDF_SIZE_MB * 1024 * 1024
    if len(pdf_bytes) > max_bytes:
        raise HTTPException(
            status_code=413,
            detail=f"PDF is too large. Max size is {MAX_PDF_SIZE_MB} MB.",
        )

    suffix = Path(file.filename).suffix or ".pdf"
    tmp_path: Path | None = None

    try:
        with NamedTemporaryFile(dir=TMP_DIR, suffix=suffix, delete=False) as tmp_file:
            tmp_file.write(pdf_bytes)
            tmp_path = Path(tmp_file.name)

        with PARSER_LOCK:
            result = PARSER.parse(str(tmp_path), save_layout_visualization=False)

        all_tables = _extract_tables(result)
        selected_tables = (
            [table for table in all_tables if table["is_investment_candidate"]]
            if only_investment_tables
            else all_tables
        )

        if response_format.lower() == "xlsx":
            xlsx_bytes = _tables_to_xlsx_bytes(selected_tables)
            output_name = f"{Path(file.filename).stem}_tables.xlsx"
            headers = {"Content-Disposition": f'attachment; filename="{output_name}"'}
            return StreamingResponse(
                io.BytesIO(xlsx_bytes),
                media_type=(
                    "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
                ),
                headers=headers,
            )

        if response_format.lower() != "json":
            raise HTTPException(
                status_code=400,
                detail="response_format must be either 'json' or 'xlsx'.",
            )

        payload: dict[str, Any] = {
            "filename": file.filename,
            "page_count": len(getattr(result, "json_result", []) or []),
            "all_tables_count": len(all_tables),
            "investment_tables_count": sum(
                1 for table in all_tables if table["is_investment_candidate"]
            ),
            "returned_tables_count": len(selected_tables),
            "tables": selected_tables,
        }
        if include_markdown:
            payload["markdown_result"] = getattr(result, "markdown_result", "") or ""
        if include_debug:
            region_counts, candidate_regions = _collect_debug_regions(result)
            payload["region_counts"] = region_counts
            payload["candidate_regions"] = candidate_regions

        return JSONResponse(payload)
    finally:
        if tmp_path and tmp_path.exists():
            tmp_path.unlink(missing_ok=True)
