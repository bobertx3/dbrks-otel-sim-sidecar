# Plan: Re-instrument OTel Simulator with Fluent Bit + Telegraf + Grafana Alloy Sidecars

## Context

The app currently uses the OTel Python SDK to export logs, metrics, and traces **directly** to Databricks OTLP HTTP endpoints. The goal is to insert **Fluent Bit** (logs), **Telegraf** (metrics), and **Grafana Alloy** (traces) as local sidecar collectors between the app and Databricks, demonstrating an enterprise-realistic collection pipeline. Target catalog.schema: `bx3.otel_fluentbit_telegraf_alloy`.

## Architecture

```
App (emitter.py, sidecar mode)
  ├── Logs    → OTLP/HTTP localhost:4318  → Fluent Bit     → Databricks /api/2.0/tracing/otel/v1/logs
  ├── Metrics → OTLP/HTTP localhost:4319  → Telegraf       → Databricks /api/2.0/otel/v1/metrics
  └── Traces  → OTLP/HTTP localhost:4320  → Grafana Alloy  → Databricks /api/2.0/tracing/otel/v1/traces
```

All three signals now route through a dedicated sidecar. No direct-to-Databricks exports in sidecar mode.

## Repo Structure (after changes)

```
jnj-otel-sim-fluent-telegraf/
├── .env.example                       # Updated: sidecar mode + new table names
├── .gitignore                         # Updated: collectors/bin/
├── databricks.yml                     # Updated: apps removed, local-only
├── requirements.txt
├── start-sidecars.sh                  # NEW: launches all collectors + app
├── clean_up_uc.py
│
├── app_otel_sim/                      # Simulator app (emitter modified)
│   ├── app.yaml
│   ├── requirements.txt
│   ├── README.md
│   ├── backend/
│   │   ├── __init__.py
│   │   ├── emitter.py                 # MODIFIED: sidecar mode routing
│   │   ├── models.py
│   │   ├── scenarios.py
│   │   └── server.py
│   └── frontend/
│       ├── app.js
│       ├── datacenter.js
│       ├── index.html
│       ├── settings.js
│       ├── streaming.js
│       └── styles.css
│
├── app_otel_ops/                      # Ops dashboard (unchanged)
│   ├── app.yaml
│   ├── requirements.txt
│   ├── backend/
│   │   ├── __init__.py
│   │   ├── queries.py
│   │   └── server.py
│   └── frontend/
│       ├── app.js
│       ├── components.js
│       ├── index.html
│       └── styles.css
│
├── collectors/                        # NEW: sidecar collector configs
│   ├── install.sh                     # Download/install Fluent Bit, Telegraf, Alloy
│   ├── fluent-bit/
│   │   └── fluent-bit.yaml            # Logs: OTLP in (4318) → Databricks OTLP out
│   ├── telegraf/
│   │   └── telegraf.conf              # Metrics: OTLP in (4319) → Databricks HTTP out
│   ├── alloy/
│   │   └── config.alloy               # Traces: OTLP in (4320) → Databricks OTLP out
│   └── bin/                           # Downloaded binaries (gitignored)
│
├── config/
│   └── telemetry.emit.yaml
│
├── img/                               # Screenshots
│   └── *.png
│
├── notebooks/
│   ├── local_otel_emitter.ipynb
│   └── simple_otel_emitter.ipynb
│
├── reference/
│   └── emit_otel_v2.py
│
└── sql/
    ├── config_scenarios.sql
    ├── config_triplets.sql
    ├── v_component_status.sql
    ├── v_incident_timeline.sql
    └── v_kpi_summary.sql
```

## Step-by-step Implementation

### Step 1: Create `collectors/` directory and install script

**File: `collectors/install.sh`**
- Detect platform (macOS arm64/amd64, Linux)
- Install Fluent Bit: `brew install fluent-bit` or download binary to `collectors/bin/`
- Install Telegraf: `brew install telegraf` or download binary to `collectors/bin/`
- Install Grafana Alloy: `brew install grafana/grafana/alloy` or download binary to `collectors/bin/`
- Make script idempotent (skip if already installed)

### Step 2: Create Fluent Bit config (logs)

**File: `collectors/fluent-bit/fluent-bit.yaml`** (YAML format, Fluent Bit 2.x+)

```yaml
service:
  flush: 2
  log_level: info

pipeline:
  inputs:
    - name: opentelemetry
      listen: 0.0.0.0
      port: 4318
      tag: otel.*

  outputs:
    - name: opentelemetry
      match: "otel.*"
      host: ${DATABRICKS_HOST_BARE}
      port: 443
      logs_uri: /api/2.0/tracing/otel/v1/logs
      tls: on
      tls.verify: on
      header:
        - Authorization Bearer ${DATABRICKS_TOKEN}
        - X-Databricks-UC-Table-Name bx3.otel_fluentbit_telegraf_alloy.otel_logs_v2
        - X-Databricks-Workspace-Url https://${DATABRICKS_HOST_BARE}
```

### Step 3: Create Telegraf config (metrics)

**File: `collectors/telegraf/telegraf.conf`** (TOML format)

```toml
[agent]
  interval = "5s"
  flush_interval = "5s"

[[inputs.opentelemetry]]
  service_address = "0.0.0.0:4317"

[[outputs.http]]
  url = "https://${DATABRICKS_HOST_BARE}/api/2.0/otel/v1/metrics"
  method = "POST"
  data_format = "opentelemetry"
  [outputs.http.headers]
    Authorization = "Bearer ${DATABRICKS_TOKEN}"
    X-Databricks-UC-Table-Name = "bx3.otel_fluentbit_telegraf_alloy.otel_metrics"
    X-Databricks-Workspace-Url = "https://${DATABRICKS_HOST_BARE}"
    Content-Type = "application/x-protobuf"
```

**Note:** Telegraf's `inputs.opentelemetry` listens on gRPC (port 4317). The app's metric exporter will need to use `opentelemetry-exporter-otlp-proto-grpc` for this, OR we use Telegraf's `inputs.http_listener_v2` on port 4319 to accept OTLP/HTTP. Preference: keep the app on OTLP/HTTP and use `inputs.http_listener_v2` with port 4319 so no new Python dependency is needed.

### Step 4: Create Grafana Alloy config (traces)

**File: `collectors/alloy/config.alloy`** (Alloy/River syntax)

Grafana Alloy uses its own config language (River). The config will:

```alloy
otelcol.receiver.otlp "default" {
  http {
    endpoint = "0.0.0.0:4320"
  }
}

otelcol.exporter.otlphttp "databricks" {
  client {
    endpoint = "https://<DATABRICKS_HOST_BARE>"
    headers = {
      "Authorization"               = "Bearer <DATABRICKS_TOKEN>",
      "X-Databricks-UC-Table-Name"  = "bx3.otel_fluentbit_telegraf_alloy.otel_spans_v2",
      "X-Databricks-Workspace-Url"  = "https://<DATABRICKS_HOST_BARE>",
    }
  }
}

otelcol.processor.batch "default" {
  output {
    traces = [otelcol.exporter.otlphttp.databricks.input]
  }
}

otelcol.receiver.otlp.default.output {
  traces = [otelcol.processor.batch.default.input]
}
```

Alloy natively supports OTLP receive and OTLP/HTTP export with custom headers, plus env var substitution via `env("VAR_NAME")`.

### Step 5: Modify `emitter.py`

**File: `app_otel_sim/backend/emitter.py`**

Add `OTEL_SIDECAR_MODE` env var check. When enabled:

1. **Log exporter**: endpoint → `http://localhost:4318/v1/logs`, headers become empty (Fluent Bit adds auth)
2. **Metric exporter**: endpoint → `http://localhost:4319/v1/metrics`, headers become empty (Telegraf adds auth)
3. **Span exporter**: endpoint → `http://localhost:4320/v1/traces`, headers become empty (Alloy adds auth)
4. `EmitterConfig.from_env()`: make token/host optional when sidecar mode is on (sidecars handle auth)

Changes are confined to `__init__` method (~15 lines of conditional logic). No changes to `emit_*()` or `flush()` methods.

### Step 6: Update `.env.example`

**File: `.env.example`**

Add:
```
# Sidecar mode: route logs→Fluent Bit, metrics→Telegraf, traces→Alloy
OTEL_SIDECAR_MODE=true

# Updated target tables
OTEL_SPANS_TABLE=bx3.otel_fluentbit_telegraf_alloy.otel_spans_v2
OTEL_LOGS_TABLE=bx3.otel_fluentbit_telegraf_alloy.otel_logs_v2
OTEL_METRICS_TABLE=bx3.otel_fluentbit_telegraf_alloy.otel_metrics
```

### Step 7: Update `.gitignore`

Add:
```
# Collector binaries (downloaded locally)
collectors/bin/
```

### Step 8: Create startup script

**File: `start-sidecars.sh`**

- Source `.env` to export vars
- Strip `https://` from DATABRICKS_HOST → DATABRICKS_HOST_BARE
- Start Fluent Bit: `fluent-bit -c collectors/fluent-bit/fluent-bit.yaml`
- Start Telegraf: `telegraf --config collectors/telegraf/telegraf.conf`
- Start Alloy: `alloy run collectors/alloy/config.alloy`
- Start app: `cd app_otel_sim && uvicorn backend.server:app --port 8000`
- Trap SIGINT to kill all background processes on Ctrl+C

### Step 9: Strip `databricks.yml` of app deployments

**File: `databricks.yml`**

Remove both `otel-simulator` and `otel-operational-app` resource definitions. Keep just the bundle name and workspace target for any future non-app resources (e.g., notebooks, SQL files). Result:

```yaml
bundle:
  name: otel-simulator

targets:
  dev:
    mode: development
    workspace:
      profile: aws-west
      host: https://e2-demo-field-eng.cloud.databricks.com
```

Everything runs locally now — the app via `start-sidecars.sh`, no Databricks Apps deployment.

## Files Modified

| File | Change |
|------|--------|
| `app_otel_sim/backend/emitter.py` | Add sidecar mode conditional for all three signal endpoints |
| `.env.example` | Add `OTEL_SIDECAR_MODE`, update table names to new schema |
| `.gitignore` | Add `collectors/bin/` |
| `databricks.yml` | Remove both app resource definitions (local-only execution) |

## Files Created

| File | Purpose |
|------|---------|
| `collectors/fluent-bit/fluent-bit.yaml` | Fluent Bit: OTLP input → OTLP HTTP output (logs) |
| `collectors/telegraf/telegraf.conf` | Telegraf: OTLP input → HTTP output (metrics) |
| `collectors/alloy/config.alloy` | Grafana Alloy: OTLP input → OTLP HTTP output (traces) |
| `collectors/install.sh` | Download/install all three collector binaries |
| `start-sidecars.sh` | Launch all collectors + app together |

## Verification

1. Run `collectors/install.sh` — confirm Fluent Bit, Telegraf, and Alloy install
2. Run `start-sidecars.sh` — confirm all four processes start without errors
3. Open the simulator UI, trigger an event
4. Check Fluent Bit stdout for log forwarding activity
5. Check Telegraf stdout for metric forwarding activity
6. Check Alloy stdout for trace forwarding activity
7. Query `bx3.otel_fluentbit_telegraf_alloy.otel_logs_v2` — confirm logs landed
8. Query `bx3.otel_fluentbit_telegraf_alloy.otel_metrics` — confirm metrics landed
9. Query `bx3.otel_fluentbit_telegraf_alloy.otel_spans_v2` — confirm traces landed
10. Set `OTEL_SIDECAR_MODE=false` and verify the app still works in direct mode (backward compat)
