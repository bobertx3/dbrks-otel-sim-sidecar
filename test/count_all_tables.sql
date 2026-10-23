-- Count all rows across every OTel table in bldemos.otel
-- Covers: 4 sidecar collectors + direct mode tables

SELECT 'fluentbit_otel_logs' AS `Table`, COUNT(*) AS `Count`
FROM `bldemos`.`otel`.`fluentbit_otel_logs`
UNION ALL
SELECT 'telegraf_otel_metrics' AS `Table`, COUNT(*) AS `Count`
FROM `bldemos`.`otel`.`telegraf_otel_metrics`
UNION ALL
SELECT 'alloy_otel_spans' AS `Table`, COUNT(*) AS `Count`
FROM `bldemos`.`otel`.`alloy_otel_spans`
UNION ALL
SELECT 'alloy_otel_logs' AS `Table`, COUNT(*) AS `Count`
FROM `bldemos`.`otel`.`alloy_otel_logs`
UNION ALL
SELECT 'alloy_otel_metrics' AS `Table`, COUNT(*) AS `Count`
FROM `bldemos`.`otel`.`alloy_otel_metrics`
UNION ALL
SELECT 'vector_otel_logs' AS `Table`, COUNT(*) AS `Count`
FROM `bldemos`.`otel`.`vector_otel_logs`
UNION ALL
SELECT 'direct_otel_spans' AS `Table`, COUNT(*) AS `Count`
FROM `bldemos`.`otel`.`direct_otel_spans`
UNION ALL
SELECT 'direct_otel_logs' AS `Table`, COUNT(*) AS `Count`
FROM `bldemos`.`otel`.`direct_otel_logs`
UNION ALL
SELECT 'direct_otel_metrics' AS `Table`, COUNT(*) AS `Count`
FROM `bldemos`.`otel`.`direct_otel_metrics`
ORDER BY `Table`;

-- ============================================================
-- Uncomment below to truncate all tables (reset demo data)
-- ============================================================
-- TRUNCATE TABLE `bldemos`.`otel`.`fluentbit_otel_logs`;
-- TRUNCATE TABLE `bldemos`.`otel`.`telegraf_otel_metrics`;
-- TRUNCATE TABLE `bldemos`.`otel`.`alloy_otel_spans`;
-- TRUNCATE TABLE `bldemos`.`otel`.`alloy_otel_logs`;
-- TRUNCATE TABLE `bldemos`.`otel`.`alloy_otel_metrics`;
-- TRUNCATE TABLE `bldemos`.`otel`.`vector_otel_logs`;
-- TRUNCATE TABLE `bldemos`.`otel`.`direct_otel_spans`;
-- TRUNCATE TABLE `bldemos`.`otel`.`direct_otel_logs`;
-- TRUNCATE TABLE `bldemos`.`otel`.`direct_otel_metrics`;
