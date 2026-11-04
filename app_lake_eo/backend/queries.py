"""SQL queries for the OTel Ops Dashboard — multi-collector view."""

from __future__ import annotations

import os
from pathlib import Path

from dotenv import load_dotenv

load_dotenv(Path(__file__).resolve().parent.parent.parent / ".env")

RANGE_MAP = {
    "5m": 5,
    "15m": 15,
    "30m": 30,
    "1h": 60,
    "6h": 360,
    "24h": 1440,
    "all": 525600,
}

# Collector → table definitions (bldemos.otel schema)
COLLECTORS = {
    "fluentbit": {
        "label": "Fluent Bit",
        "signals": ["logs"],
        "tables": {"logs": "bldemos.otel.fluentbit_otel_logs"},
    },
    "alloy": {
        "label": "Grafana Alloy",
        "signals": ["logs", "metrics", "traces"],
        "tables": {
            "logs": "bldemos.otel.alloy_otel_logs",
            "metrics": "bldemos.otel.alloy_otel_metrics",
            "traces": "bldemos.otel.alloy_otel_spans",
        },
    },
    "telegraf": {
        "label": "Telegraf",
        "signals": ["metrics"],
        "tables": {"metrics": "bldemos.otel.telegraf_otel_metrics"},
    },
    "vector": {
        "label": "Vector",
        "signals": ["logs"],
        "tables": {"logs": "bldemos.otel.vector_otel_logs"},
    },
    "direct": {
        "label": "Direct",
        "signals": ["logs", "metrics", "traces"],
        "tables": {
            "logs": os.getenv("OTEL_DIRECT_LOGS_TABLE", "bldemos.otel.direct_otel_logs"),
            "metrics": os.getenv("OTEL_DIRECT_METRICS_TABLE", "bldemos.otel.direct_otel_metrics"),
            "traces": os.getenv("OTEL_DIRECT_SPANS_TABLE", "bldemos.otel.direct_otel_spans"),
        },
    },
}


def parse_range(range_str: str) -> int:
    return RANGE_MAP.get(range_str, 30)


def collector_counts_query(minutes: int) -> str:
    """Row counts per collector per signal type."""
    parts = []
    for cid, c in COLLECTORS.items():
        for signal, table in c["tables"].items():
            # Metrics tables don't have a top-level `time` column
            if signal == "metrics":
                parts.append(
                    f"SELECT '{cid}' AS collector, '{signal}' AS signal, COUNT(*) AS cnt "
                    f"FROM {table}"
                )
            else:
                parts.append(
                    f"SELECT '{cid}' AS collector, '{signal}' AS signal, COUNT(*) AS cnt "
                    f"FROM {table} WHERE time >= current_timestamp() - INTERVAL {minutes} MINUTES"
                )
    return " UNION ALL ".join(parts)


def logs_query(table: str, minutes: int, limit: int = 100) -> str:
    return f"""
SELECT
  time,
  severity_text,
  service_name,
  body::STRING AS body,
  trace_id,
  span_id,
  attributes
FROM {table}
WHERE time >= current_timestamp() - INTERVAL {minutes} MINUTES
ORDER BY time DESC
LIMIT {limit}
"""


def metrics_query(table: str, minutes: int, limit: int = 100) -> str:
    return f"""
SELECT
  name,
  description,
  unit,
  metric_type,
  COALESCE(
    gauge.attributes,
    sum.attributes,
    histogram.attributes
  ) AS attributes,
  COALESCE(gauge.value, sum.value) AS value,
  time_unix_nano,
  histogram.count AS hist_count,
  histogram.sum AS hist_sum,
  histogram.min AS hist_min,
  histogram.max AS hist_max,
  resource.attributes AS resource_attributes
FROM {table}
WHERE 1=1
ORDER BY time_unix_nano DESC NULLS LAST
LIMIT {limit}
"""


def traces_query(table: str, minutes: int, limit: int = 100) -> str:
    return f"""
SELECT
  time,
  trace_id,
  span_id,
  parent_span_id,
  name,
  kind,
  service_name,
  start_time_unix_nano,
  end_time_unix_nano,
  status,
  attributes
FROM {table}
WHERE time >= current_timestamp() - INTERVAL {minutes} MINUTES
ORDER BY time DESC
LIMIT {limit}
"""


def trace_detail_query(table: str, trace_id: str) -> str:
    safe_id = trace_id.replace("'", "''")
    return f"""
SELECT
  trace_id,
  span_id,
  parent_span_id,
  name,
  kind,
  service_name,
  start_time_unix_nano,
  end_time_unix_nano,
  status,
  attributes,
  events
FROM {table}
WHERE trace_id = '{safe_id}'
ORDER BY start_time_unix_nano ASC
"""
