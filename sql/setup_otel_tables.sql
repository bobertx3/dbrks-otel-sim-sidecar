-- Setup script: Create OTel tables for the 5-collector demo
-- Target schema: telemetry.otel
-- Tables are prefixed by collector name.
--
-- Run this once before emitting telemetry.

-- ============================================================
-- Schema
-- ============================================================
CREATE SCHEMA IF NOT EXISTS telemetry.otel;

-- ============================================================
-- Spans (v2 schema) — Grafana Alloy + OTel Collector
-- ============================================================
CREATE TABLE IF NOT EXISTS telemetry.otel.alloy_otel_spans_v2 (
  record_id STRING, time TIMESTAMP, date DATE, service_name STRING, trace_id STRING,
  span_id STRING, trace_state STRING, parent_span_id STRING, flags INT, name STRING,
  kind STRING, start_time_unix_nano BIGINT, end_time_unix_nano BIGINT,
  attributes VARIANT, dropped_attributes_count INT,
  events ARRAY<STRUCT<time_unix_nano: BIGINT, name: STRING, attributes: VARIANT, dropped_attributes_count: INT>>,
  dropped_events_count INT,
  links ARRAY<STRUCT<trace_id: STRING, span_id: STRING, trace_state: STRING, attributes: VARIANT, dropped_attributes_count: INT, flags: INT>>,
  dropped_links_count INT,
  status STRUCT<message: STRING, code: STRING>,
  resource STRUCT<attributes: VARIANT, dropped_attributes_count: INT>,
  resource_schema_url STRING,
  instrumentation_scope STRUCT<name: STRING, version: STRING, attributes: VARIANT, dropped_attributes_count: INT>,
  span_schema_url STRING
) USING delta TBLPROPERTIES ('delta.parquet.compression.codec' = 'zstd', 'otel.schemaVersion' = 'v2');

CREATE TABLE IF NOT EXISTS telemetry.otel.otelcol_otel_spans_v2 (
  record_id STRING, time TIMESTAMP, date DATE, service_name STRING, trace_id STRING,
  span_id STRING, trace_state STRING, parent_span_id STRING, flags INT, name STRING,
  kind STRING, start_time_unix_nano BIGINT, end_time_unix_nano BIGINT,
  attributes VARIANT, dropped_attributes_count INT,
  events ARRAY<STRUCT<time_unix_nano: BIGINT, name: STRING, attributes: VARIANT, dropped_attributes_count: INT>>,
  dropped_events_count INT,
  links ARRAY<STRUCT<trace_id: STRING, span_id: STRING, trace_state: STRING, attributes: VARIANT, dropped_attributes_count: INT, flags: INT>>,
  dropped_links_count INT,
  status STRUCT<message: STRING, code: STRING>,
  resource STRUCT<attributes: VARIANT, dropped_attributes_count: INT>,
  resource_schema_url STRING,
  instrumentation_scope STRUCT<name: STRING, version: STRING, attributes: VARIANT, dropped_attributes_count: INT>,
  span_schema_url STRING
) USING delta TBLPROPERTIES ('delta.parquet.compression.codec' = 'zstd', 'otel.schemaVersion' = 'v2');

-- ============================================================
-- Logs (v2 schema) — Fluent Bit, Grafana Alloy, Vector, OTel Collector
-- ============================================================
CREATE TABLE IF NOT EXISTS telemetry.otel.fluentbit_otel_logs_v2 (
  record_id STRING, time TIMESTAMP, date DATE, service_name STRING, event_name STRING,
  trace_id STRING, span_id STRING, time_unix_nano BIGINT, observed_time_unix_nano BIGINT,
  severity_number STRING, severity_text STRING, body VARIANT, attributes VARIANT,
  dropped_attributes_count INT, flags INT,
  resource STRUCT<attributes: VARIANT, dropped_attributes_count: INT>,
  resource_schema_url STRING,
  instrumentation_scope STRUCT<name: STRING, version: STRING, attributes: VARIANT, dropped_attributes_count: INT>,
  log_schema_url STRING
) USING delta TBLPROPERTIES ('delta.parquet.compression.codec' = 'zstd', 'otel.schemaVersion' = 'v2');

CREATE TABLE IF NOT EXISTS telemetry.otel.alloy_otel_logs_v2 (
  record_id STRING, time TIMESTAMP, date DATE, service_name STRING, event_name STRING,
  trace_id STRING, span_id STRING, time_unix_nano BIGINT, observed_time_unix_nano BIGINT,
  severity_number STRING, severity_text STRING, body VARIANT, attributes VARIANT,
  dropped_attributes_count INT, flags INT,
  resource STRUCT<attributes: VARIANT, dropped_attributes_count: INT>,
  resource_schema_url STRING,
  instrumentation_scope STRUCT<name: STRING, version: STRING, attributes: VARIANT, dropped_attributes_count: INT>,
  log_schema_url STRING
) USING delta TBLPROPERTIES ('delta.parquet.compression.codec' = 'zstd', 'otel.schemaVersion' = 'v2');

CREATE TABLE IF NOT EXISTS telemetry.otel.vector_otel_logs_v2 (
  record_id STRING, time TIMESTAMP, date DATE, service_name STRING, event_name STRING,
  trace_id STRING, span_id STRING, time_unix_nano BIGINT, observed_time_unix_nano BIGINT,
  severity_number STRING, severity_text STRING, body VARIANT, attributes VARIANT,
  dropped_attributes_count INT, flags INT,
  resource STRUCT<attributes: VARIANT, dropped_attributes_count: INT>,
  resource_schema_url STRING,
  instrumentation_scope STRUCT<name: STRING, version: STRING, attributes: VARIANT, dropped_attributes_count: INT>,
  log_schema_url STRING
) USING delta TBLPROPERTIES ('delta.parquet.compression.codec' = 'zstd', 'otel.schemaVersion' = 'v2');

CREATE TABLE IF NOT EXISTS telemetry.otel.otelcol_otel_logs_v2 (
  record_id STRING, time TIMESTAMP, date DATE, service_name STRING, event_name STRING,
  trace_id STRING, span_id STRING, time_unix_nano BIGINT, observed_time_unix_nano BIGINT,
  severity_number STRING, severity_text STRING, body VARIANT, attributes VARIANT,
  dropped_attributes_count INT, flags INT,
  resource STRUCT<attributes: VARIANT, dropped_attributes_count: INT>,
  resource_schema_url STRING,
  instrumentation_scope STRUCT<name: STRING, version: STRING, attributes: VARIANT, dropped_attributes_count: INT>,
  log_schema_url STRING
) USING delta TBLPROPERTIES ('delta.parquet.compression.codec' = 'zstd', 'otel.schemaVersion' = 'v2');

-- ============================================================
-- Metrics (v1 schema) — Grafana Alloy, OTel Collector
-- ============================================================
-- NOTE: Telegraf has been removed from the project (histogram fidelity issues).
-- This table is retained for backward compatibility with existing data.
CREATE TABLE IF NOT EXISTS telemetry.otel.telegraf_otel_metrics (
  name STRING, description STRING, unit STRING, metric_type STRING,
  gauge STRUCT<start_time_unix_nano: BIGINT, time_unix_nano: BIGINT, value: DOUBLE, exemplars: ARRAY<STRUCT<time_unix_nano: BIGINT, value: DOUBLE, span_id: STRING, trace_id: STRING, filtered_attributes: MAP<STRING, STRING>>>, attributes: MAP<STRING, STRING>, flags: INT>,
  sum STRUCT<start_time_unix_nano: BIGINT, time_unix_nano: BIGINT, value: DOUBLE, exemplars: ARRAY<STRUCT<time_unix_nano: BIGINT, value: DOUBLE, span_id: STRING, trace_id: STRING, filtered_attributes: MAP<STRING, STRING>>>, attributes: MAP<STRING, STRING>, flags: INT, aggregation_temporality: STRING, is_monotonic: BOOLEAN>,
  histogram STRUCT<start_time_unix_nano: BIGINT, time_unix_nano: BIGINT, count: BIGINT, sum: DOUBLE, bucket_counts: ARRAY<BIGINT>, explicit_bounds: ARRAY<DOUBLE>, exemplars: ARRAY<STRUCT<time_unix_nano: BIGINT, value: DOUBLE, span_id: STRING, trace_id: STRING, filtered_attributes: MAP<STRING, STRING>>>, attributes: MAP<STRING, STRING>, flags: INT, min: DOUBLE, max: DOUBLE, aggregation_temporality: STRING>,
  exponential_histogram STRUCT<attributes: MAP<STRING, STRING>, start_time_unix_nano: BIGINT, time_unix_nano: BIGINT, count: BIGINT, sum: DOUBLE, scale: INT, zero_count: BIGINT, positive_bucket: STRUCT<offset: INT, bucket_counts: ARRAY<BIGINT>>, negative_bucket: STRUCT<offset: INT, bucket_counts: ARRAY<BIGINT>>, flags: INT, exemplars: ARRAY<STRUCT<time_unix_nano: BIGINT, value: DOUBLE, span_id: STRING, trace_id: STRING, filtered_attributes: MAP<STRING, STRING>>>, min: DOUBLE, max: DOUBLE, zero_threshold: DOUBLE, aggregation_temporality: STRING>,
  summary STRUCT<start_time_unix_nano: BIGINT, time_unix_nano: BIGINT, count: BIGINT, sum: DOUBLE, quantile_values: ARRAY<STRUCT<quantile: DOUBLE, value: DOUBLE>>, attributes: MAP<STRING, STRING>, flags: INT>,
  metadata MAP<STRING, STRING>,
  resource STRUCT<attributes: MAP<STRING, STRING>, dropped_attributes_count: INT>,
  resource_schema_url STRING,
  instrumentation_scope STRUCT<name: STRING, version: STRING, attributes: MAP<STRING, STRING>, dropped_attributes_count: INT>,
  metric_schema_url STRING
) USING delta TBLPROPERTIES ('delta.parquet.compression.codec' = 'zstd', 'otel.schemaVersion' = 'v1');

CREATE TABLE IF NOT EXISTS telemetry.otel.alloy_otel_metrics (
  name STRING, description STRING, unit STRING, metric_type STRING,
  gauge STRUCT<start_time_unix_nano: BIGINT, time_unix_nano: BIGINT, value: DOUBLE, exemplars: ARRAY<STRUCT<time_unix_nano: BIGINT, value: DOUBLE, span_id: STRING, trace_id: STRING, filtered_attributes: MAP<STRING, STRING>>>, attributes: MAP<STRING, STRING>, flags: INT>,
  sum STRUCT<start_time_unix_nano: BIGINT, time_unix_nano: BIGINT, value: DOUBLE, exemplars: ARRAY<STRUCT<time_unix_nano: BIGINT, value: DOUBLE, span_id: STRING, trace_id: STRING, filtered_attributes: MAP<STRING, STRING>>>, attributes: MAP<STRING, STRING>, flags: INT, aggregation_temporality: STRING, is_monotonic: BOOLEAN>,
  histogram STRUCT<start_time_unix_nano: BIGINT, time_unix_nano: BIGINT, count: BIGINT, sum: DOUBLE, bucket_counts: ARRAY<BIGINT>, explicit_bounds: ARRAY<DOUBLE>, exemplars: ARRAY<STRUCT<time_unix_nano: BIGINT, value: DOUBLE, span_id: STRING, trace_id: STRING, filtered_attributes: MAP<STRING, STRING>>>, attributes: MAP<STRING, STRING>, flags: INT, min: DOUBLE, max: DOUBLE, aggregation_temporality: STRING>,
  exponential_histogram STRUCT<attributes: MAP<STRING, STRING>, start_time_unix_nano: BIGINT, time_unix_nano: BIGINT, count: BIGINT, sum: DOUBLE, scale: INT, zero_count: BIGINT, positive_bucket: STRUCT<offset: INT, bucket_counts: ARRAY<BIGINT>>, negative_bucket: STRUCT<offset: INT, bucket_counts: ARRAY<BIGINT>>, flags: INT, exemplars: ARRAY<STRUCT<time_unix_nano: BIGINT, value: DOUBLE, span_id: STRING, trace_id: STRING, filtered_attributes: MAP<STRING, STRING>>>, min: DOUBLE, max: DOUBLE, zero_threshold: DOUBLE, aggregation_temporality: STRING>,
  summary STRUCT<start_time_unix_nano: BIGINT, time_unix_nano: BIGINT, count: BIGINT, sum: DOUBLE, quantile_values: ARRAY<STRUCT<quantile: DOUBLE, value: DOUBLE>>, attributes: MAP<STRING, STRING>, flags: INT>,
  metadata MAP<STRING, STRING>,
  resource STRUCT<attributes: MAP<STRING, STRING>, dropped_attributes_count: INT>,
  resource_schema_url STRING,
  instrumentation_scope STRUCT<name: STRING, version: STRING, attributes: MAP<STRING, STRING>, dropped_attributes_count: INT>,
  metric_schema_url STRING
) USING delta TBLPROPERTIES ('delta.parquet.compression.codec' = 'zstd', 'otel.schemaVersion' = 'v1');

CREATE TABLE IF NOT EXISTS telemetry.otel.vector_otel_metrics (
  name STRING, description STRING, unit STRING, metric_type STRING,
  gauge STRUCT<start_time_unix_nano: BIGINT, time_unix_nano: BIGINT, value: DOUBLE, exemplars: ARRAY<STRUCT<time_unix_nano: BIGINT, value: DOUBLE, span_id: STRING, trace_id: STRING, filtered_attributes: MAP<STRING, STRING>>>, attributes: MAP<STRING, STRING>, flags: INT>,
  sum STRUCT<start_time_unix_nano: BIGINT, time_unix_nano: BIGINT, value: DOUBLE, exemplars: ARRAY<STRUCT<time_unix_nano: BIGINT, value: DOUBLE, span_id: STRING, trace_id: STRING, filtered_attributes: MAP<STRING, STRING>>>, attributes: MAP<STRING, STRING>, flags: INT, aggregation_temporality: STRING, is_monotonic: BOOLEAN>,
  histogram STRUCT<start_time_unix_nano: BIGINT, time_unix_nano: BIGINT, count: BIGINT, sum: DOUBLE, bucket_counts: ARRAY<BIGINT>, explicit_bounds: ARRAY<DOUBLE>, exemplars: ARRAY<STRUCT<time_unix_nano: BIGINT, value: DOUBLE, span_id: STRING, trace_id: STRING, filtered_attributes: MAP<STRING, STRING>>>, attributes: MAP<STRING, STRING>, flags: INT, min: DOUBLE, max: DOUBLE, aggregation_temporality: STRING>,
  exponential_histogram STRUCT<attributes: MAP<STRING, STRING>, start_time_unix_nano: BIGINT, time_unix_nano: BIGINT, count: BIGINT, sum: DOUBLE, scale: INT, zero_count: BIGINT, positive_bucket: STRUCT<offset: INT, bucket_counts: ARRAY<BIGINT>>, negative_bucket: STRUCT<offset: INT, bucket_counts: ARRAY<BIGINT>>, flags: INT, exemplars: ARRAY<STRUCT<time_unix_nano: BIGINT, value: DOUBLE, span_id: STRING, trace_id: STRING, filtered_attributes: MAP<STRING, STRING>>>, min: DOUBLE, max: DOUBLE, zero_threshold: DOUBLE, aggregation_temporality: STRING>,
  summary STRUCT<start_time_unix_nano: BIGINT, time_unix_nano: BIGINT, count: BIGINT, sum: DOUBLE, quantile_values: ARRAY<STRUCT<quantile: DOUBLE, value: DOUBLE>>, attributes: MAP<STRING, STRING>, flags: INT>,
  metadata MAP<STRING, STRING>,
  resource STRUCT<attributes: MAP<STRING, STRING>, dropped_attributes_count: INT>,
  resource_schema_url STRING,
  instrumentation_scope STRUCT<name: STRING, version: STRING, attributes: MAP<STRING, STRING>, dropped_attributes_count: INT>,
  metric_schema_url STRING
) USING delta TBLPROPERTIES ('delta.parquet.compression.codec' = 'zstd', 'otel.schemaVersion' = 'v1');

CREATE TABLE IF NOT EXISTS telemetry.otel.otelcol_otel_metrics (
  name STRING, description STRING, unit STRING, metric_type STRING,
  gauge STRUCT<start_time_unix_nano: BIGINT, time_unix_nano: BIGINT, value: DOUBLE, exemplars: ARRAY<STRUCT<time_unix_nano: BIGINT, value: DOUBLE, span_id: STRING, trace_id: STRING, filtered_attributes: MAP<STRING, STRING>>>, attributes: MAP<STRING, STRING>, flags: INT>,
  sum STRUCT<start_time_unix_nano: BIGINT, time_unix_nano: BIGINT, value: DOUBLE, exemplars: ARRAY<STRUCT<time_unix_nano: BIGINT, value: DOUBLE, span_id: STRING, trace_id: STRING, filtered_attributes: MAP<STRING, STRING>>>, attributes: MAP<STRING, STRING>, flags: INT, aggregation_temporality: STRING, is_monotonic: BOOLEAN>,
  histogram STRUCT<start_time_unix_nano: BIGINT, time_unix_nano: BIGINT, count: BIGINT, sum: DOUBLE, bucket_counts: ARRAY<BIGINT>, explicit_bounds: ARRAY<DOUBLE>, exemplars: ARRAY<STRUCT<time_unix_nano: BIGINT, value: DOUBLE, span_id: STRING, trace_id: STRING, filtered_attributes: MAP<STRING, STRING>>>, attributes: MAP<STRING, STRING>, flags: INT, min: DOUBLE, max: DOUBLE, aggregation_temporality: STRING>,
  exponential_histogram STRUCT<attributes: MAP<STRING, STRING>, start_time_unix_nano: BIGINT, time_unix_nano: BIGINT, count: BIGINT, sum: DOUBLE, scale: INT, zero_count: BIGINT, positive_bucket: STRUCT<offset: INT, bucket_counts: ARRAY<BIGINT>>, negative_bucket: STRUCT<offset: INT, bucket_counts: ARRAY<BIGINT>>, flags: INT, exemplars: ARRAY<STRUCT<time_unix_nano: BIGINT, value: DOUBLE, span_id: STRING, trace_id: STRING, filtered_attributes: MAP<STRING, STRING>>>, min: DOUBLE, max: DOUBLE, zero_threshold: DOUBLE, aggregation_temporality: STRING>,
  summary STRUCT<start_time_unix_nano: BIGINT, time_unix_nano: BIGINT, count: BIGINT, sum: DOUBLE, quantile_values: ARRAY<STRUCT<quantile: DOUBLE, value: DOUBLE>>, attributes: MAP<STRING, STRING>, flags: INT>,
  metadata MAP<STRING, STRING>,
  resource STRUCT<attributes: MAP<STRING, STRING>, dropped_attributes_count: INT>,
  resource_schema_url STRING,
  instrumentation_scope STRUCT<name: STRING, version: STRING, attributes: MAP<STRING, STRING>, dropped_attributes_count: INT>,
  metric_schema_url STRING
) USING delta TBLPROPERTIES ('delta.parquet.compression.codec' = 'zstd', 'otel.schemaVersion' = 'v1');
