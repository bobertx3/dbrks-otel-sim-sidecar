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

# Collector → table definitions (telemetry.otel schema)
COLLECTORS = {
    "fluentbit": {
        "label": "Fluent Bit",
        "signals": ["logs"],
        "tables": {"logs": "telemetry.otel.fluentbit_otel_logs_v2"},
    },
    "alloy": {
        "label": "Grafana Alloy",
        "signals": ["logs", "metrics", "traces"],
        "tables": {
            "logs": "telemetry.otel.alloy_otel_logs_v2",
            "metrics": "telemetry.otel.alloy_otel_metrics",
            "traces": "telemetry.otel.alloy_otel_spans_v2",
        },
    },
    "telegraf": {
        "label": "Telegraf",
        "signals": ["metrics"],
        "tables": {"metrics": "telemetry.otel.telegraf_otel_metrics"},
    },
    "vector": {
        "label": "Vector",
        "signals": ["logs"],
        "tables": {"logs": "telemetry.otel.vector_otel_logs_v2"},
    },
    "otelcol": {
        "label": "OTel Collector",
        "signals": ["logs", "metrics", "traces"],
        "tables": {
            "logs": "telemetry.otel.otelcol_otel_logs_v2",
            "metrics": "telemetry.otel.otelcol_otel_metrics",
            "traces": "telemetry.otel.otelcol_otel_spans_v2",
        },
    },
    "direct": {
        "label": "Direct",
        "signals": ["logs", "metrics", "traces"],
        "tables": {
            "logs": os.getenv("OTEL_DIRECT_LOGS_TABLE", "telemetry.otel.direct_otel_logs_v2"),
            "metrics": os.getenv("OTEL_DIRECT_METRICS_TABLE", "telemetry.otel.direct_otel_metrics"),
            "traces": os.getenv("OTEL_DIRECT_SPANS_TABLE", "telemetry.otel.direct_otel_spans_v2"),
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
  COALESCE(
    gauge.time_unix_nano,
    sum.time_unix_nano,
    histogram.time_unix_nano
  ) AS time_unix_nano,
  histogram.count AS hist_count,
  histogram.sum AS hist_sum,
  histogram.min AS hist_min,
  histogram.max AS hist_max,
  resource.attributes AS resource_attributes
FROM {table}
WHERE 1=1
ORDER BY COALESCE(
  gauge.time_unix_nano,
  sum.time_unix_nano,
  histogram.time_unix_nano
) DESC NULLS LAST
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
