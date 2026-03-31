-- Count all rows across every OTel table in telemetry.otel
-- Covers: 5 sidecar collectors + direct mode tables

-- Sidecar: Fluent Bit (logs)
SELECT 'fluentbit_otel_logs_v2' AS `Table`, COUNT(*) AS `Count`
FROM `telemetry`.`otel`.`fluentbit_otel_logs_v2`
UNION ALL

-- Sidecar: Telegraf (metrics)
SELECT 'telegraf_otel_metrics' AS `Table`, COUNT(*) AS `Count`
FROM `telemetry`.`otel`.`telegraf_otel_metrics`
UNION ALL

-- Sidecar: Grafana Alloy (all signals)
SELECT 'alloy_otel_logs_v2' AS `Table`, COUNT(*) AS `Count`
FROM `telemetry`.`otel`.`alloy_otel_logs_v2`
UNION ALL
SELECT 'alloy_otel_metrics' AS `Table`, COUNT(*) AS `Count`
FROM `telemetry`.`otel`.`alloy_otel_metrics`
UNION ALL
SELECT 'alloy_otel_spans_v2' AS `Table`, COUNT(*) AS `Count`
FROM `telemetry`.`otel`.`alloy_otel_spans_v2`
UNION ALL

-- Sidecar: Vector (logs)
SELECT 'vector_otel_logs_v2' AS `Table`, COUNT(*) AS `Count`
FROM `telemetry`.`otel`.`vector_otel_logs_v2`
UNION ALL

-- Sidecar: OTel Collector (all signals)
SELECT 'otelcol_otel_logs_v2' AS `Table`, COUNT(*) AS `Count`
FROM `telemetry`.`otel`.`otelcol_otel_logs_v2`
UNION ALL
SELECT 'otelcol_otel_metrics' AS `Table`, COUNT(*) AS `Count`
FROM `telemetry`.`otel`.`otelcol_otel_metrics`
UNION ALL
SELECT 'otelcol_otel_spans_v2' AS `Table`, COUNT(*) AS `Count`
FROM `telemetry`.`otel`.`otelcol_otel_spans_v2`
UNION ALL

-- Direct mode (no sidecars)
SELECT 'direct_otel_spans_v2' AS `Table`, COUNT(*) AS `Count`
FROM `telemetry`.`otel`.`direct_otel_spans_v2`
UNION ALL
SELECT 'direct_otel_logs_v2' AS `Table`, COUNT(*) AS `Count`
FROM `telemetry`.`otel`.`direct_otel_logs_v2`
UNION ALL
SELECT 'direct_otel_metrics' AS `Table`, COUNT(*) AS `Count`
FROM `telemetry`.`otel`.`direct_otel_metrics`

ORDER BY `Table`;

-- ============================================================
-- Uncomment below to truncate all tables (reset demo data)
-- ============================================================
-- TRUNCATE TABLE `telemetry`.`otel`.`fluentbit_otel_logs_v2`;
-- TRUNCATE TABLE `telemetry`.`otel`.`telegraf_otel_metrics`;
-- TRUNCATE TABLE `telemetry`.`otel`.`alloy_otel_logs_v2`;
-- TRUNCATE TABLE `telemetry`.`otel`.`alloy_otel_metrics`;
-- TRUNCATE TABLE `telemetry`.`otel`.`alloy_otel_spans_v2`;
-- TRUNCATE TABLE `telemetry`.`otel`.`vector_otel_logs_v2`;
-- TRUNCATE TABLE `telemetry`.`otel`.`otelcol_otel_logs_v2`;
-- TRUNCATE TABLE `telemetry`.`otel`.`otelcol_otel_metrics`;
-- TRUNCATE TABLE `telemetry`.`otel`.`otelcol_otel_spans_v2`;
-- TRUNCATE TABLE `telemetry`.`otel`.`direct_otel_spans_v2`;
-- TRUNCATE TABLE `telemetry`.`otel`.`direct_otel_logs_v2`;
-- TRUNCATE TABLE `telemetry`.`otel`.`direct_otel_metrics`;
