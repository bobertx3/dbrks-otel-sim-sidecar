"""OTel Ops Dashboard — multi-collector telemetry viewer."""

from __future__ import annotations

import logging
import os
from pathlib import Path
from typing import Any

from dotenv import load_dotenv
from fastapi import FastAPI, HTTPException, Query
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from databricks import sql as dbsql

from .queries import (
    COLLECTORS,
    parse_range,
    collector_counts_query,
    logs_query,
    metrics_query,
    traces_query,
    trace_detail_query,
)

APP_DIR = Path(__file__).resolve().parent.parent
FRONTEND_DIR = APP_DIR / "frontend"

load_dotenv(APP_DIR.parent / ".env")

logger = logging.getLogger(__name__)

DATABRICKS_HOST = os.getenv("DATABRICKS_HOST", "")
WAREHOUSE_ID = os.getenv("DATABRICKS_WAREHOUSE_ID", "")


def _resolve_sql_host() -> str:
    raw = os.getenv("DATABRICKS_HOST", "").strip()
    if not raw:
        try:
            from databricks.sdk.core import Config
            cfg = Config()
            raw = getattr(cfg, "host", None) or ""
        except Exception:
            pass
    if not raw:
        return ""
    return str(raw).replace("https://", "").replace("http://", "").split("/")[0].rstrip("/")


def _run_sql(query: str) -> list[dict[str, Any]]:
    host = _resolve_sql_host()
    if not host:
        raise HTTPException(status_code=503, detail="No Databricks host configured")
    if not WAREHOUSE_ID:
        raise HTTPException(status_code=503, detail="DATABRICKS_WAREHOUSE_ID not set")
    http_path = f"/sql/1.0/warehouses/{WAREHOUSE_ID}"
    pat = os.getenv("DATABRICKS_TOKEN", "").strip()
    try:
        if pat:
            conn = dbsql.connect(server_hostname=host, http_path=http_path, access_token=pat)
        else:
            from databricks.sdk.core import Config as SdkConfig
            sdk_cfg = SdkConfig()
            conn = dbsql.connect(server_hostname=host, http_path=http_path, credentials_provider=sdk_cfg.authenticate)
        with conn:
            with conn.cursor() as cursor:
                cursor.execute(query)
                columns = [desc[0] for desc in cursor.description] if cursor.description else []
                rows = cursor.fetchall()
                return [dict(zip(columns, row)) for row in rows]
    except Exception as e:
        logger.error(f"SQL error: {e}")
        raise HTTPException(status_code=500, detail=str(e))


app = FastAPI(title="OTel Ops Dashboard", version="2.0.0")

@app.middleware("http")
async def no_cache(request, call_next):
    response = await call_next(request)
    if request.url.path.startswith("/static/"):
        response.headers["Cache-Control"] = "no-store, max-age=0"
    return response

app.mount("/static", StaticFiles(directory=str(FRONTEND_DIR)), name="static")


@app.get("/")
def index():
    return FileResponse(str(FRONTEND_DIR / "index.html"))


@app.get("/api/health")
def health():
    try:
        host = _resolve_sql_host()
    except Exception:
        host = ""
    return {"status": "ok" if host and WAREHOUSE_ID else "misconfigured"}


@app.get("/api/collectors")
def get_collectors():
    """Return collector definitions with their signal affinities and table names."""
    return COLLECTORS


@app.get("/api/counts")
def get_counts(range: str = Query("30m", alias="range")):
    """Row counts per collector per signal type."""
    minutes = parse_range(range)
    rows = _run_sql(collector_counts_query(minutes))
    result: dict[str, dict[str, int]] = {}
    for r in rows:
        cid = r["collector"]
        signal = r["signal"]
        result.setdefault(cid, {})[signal] = int(r["cnt"] or 0)
    return result


@app.get("/api/logs/{collector}")
def get_logs(collector: str, range: str = Query("30m", alias="range"), limit: int = Query(100)):
    if collector not in COLLECTORS or "logs" not in COLLECTORS[collector]["tables"]:
        raise HTTPException(status_code=404, detail=f"No logs table for {collector}")
    table = COLLECTORS[collector]["tables"]["logs"]
    minutes = parse_range(range)
    rows = _run_sql(logs_query(table, minutes, limit))
    for r in rows:
        r["time"] = str(r.get("time") or "")
        if r.get("attributes"):
            r["attributes"] = str(r["attributes"])
    return {"collector": collector, "logs": rows}


@app.get("/api/metrics/{collector}")
def get_metrics(collector: str, range: str = Query("30m", alias="range"), limit: int = Query(100)):
    if collector not in COLLECTORS or "metrics" not in COLLECTORS[collector]["tables"]:
        raise HTTPException(status_code=404, detail=f"No metrics table for {collector}")
    table = COLLECTORS[collector]["tables"]["metrics"]
    minutes = parse_range(range)
    rows = _run_sql(metrics_query(table, minutes, limit))
    for r in rows:
        if r.get("attributes"):
            r["attributes"] = str(r["attributes"])
        if r.get("resource_attributes"):
            r["resource_attributes"] = str(r["resource_attributes"])
    return {"collector": collector, "metrics": rows}


@app.get("/api/traces/{collector}")
def get_traces(collector: str, range: str = Query("30m", alias="range"), limit: int = Query(100)):
    if collector not in COLLECTORS or "traces" not in COLLECTORS[collector]["tables"]:
        raise HTTPException(status_code=404, detail=f"No traces table for {collector}")
    table = COLLECTORS[collector]["tables"]["traces"]
    minutes = parse_range(range)
    rows = _run_sql(traces_query(table, minutes, limit))
    for r in rows:
        r["time"] = str(r.get("time") or "")
        if r.get("attributes"):
            r["attributes"] = str(r["attributes"])
        if r.get("status"):
            r["status"] = str(r["status"])
    return {"collector": collector, "traces": rows}


@app.get("/api/trace/{collector}/{trace_id}")
def get_trace_detail(collector: str, trace_id: str):
    if collector not in COLLECTORS or "traces" not in COLLECTORS[collector]["tables"]:
        raise HTTPException(status_code=404, detail=f"No traces table for {collector}")
    table = COLLECTORS[collector]["tables"]["traces"]
    rows = _run_sql(trace_detail_query(table, trace_id))
    spans = []
    for r in rows:
        spans.append({
            "trace_id": r.get("trace_id"),
            "span_id": r.get("span_id"),
            "parent_span_id": r.get("parent_span_id"),
            "name": r.get("name"),
            "kind": r.get("kind"),
            "service_name": r.get("service_name"),
            "start_time_unix_nano": r.get("start_time_unix_nano"),
            "end_time_unix_nano": r.get("end_time_unix_nano"),
            "status": str(r.get("status") or ""),
            "attributes": str(r.get("attributes") or ""),
            "events": str(r.get("events") or ""),
        })
    return {"trace_id": trace_id, "collector": collector, "spans": spans}
