# OTel Simulator — 5 Collectors to Databricks

An OpenTelemetry simulator that demonstrates how five different open-source collectors can forward telemetry to Databricks Unity Catalog. Each collector handles the signal types it's purpose-built for.

## Collector-to-Signal Mapping

| Collector | Logs | Metrics | Traces | Rationale |
|-----------|:----:|:-------:|:------:|-----------|
| **Fluent Bit** | Yes | - | - | Purpose-built log processor. ~1MB footprint, 300+ plugins, de facto standard for K8s log collection. |
| **Telegraf** | - | Yes | - | InfluxData's metrics agent. Supports OTLP input (gRPC) and OTLP/HTTP output. Drops optional histogram fields (min/max) during internal conversion, but Databricks accepts the payloads. |
| **Grafana Alloy** | Yes | Yes | Yes | Full OTel-native collector. Handles all signals with component-based pipelines. Best fit for Grafana ecosystem teams. |
| **Vector** | Yes | - | - | High-performance Rust-based pipeline. Excels at log collection and transformation (VRL). OTLP metrics forwarding has limitations. |
| **OTel Collector** | Yes | Yes | Yes | The CNCF (Cloud Native Computing Foundation) reference implementation. Vendor-neutral, handles all signals, 200+ community components. The standard choice for greenfield OTel. |

### Telegraf Note

Telegraf receives OTLP metrics via its [OpenTelemetry input plugin](https://docs.influxdata.com/telegraf/v1/input-plugins/opentelemetry/) (gRPC on :4319) and forwards them to Databricks using the [OpenTelemetry output plugin](https://docs.influxdata.com/telegraf/v1/output-plugins/opentelemetry/) (`encoding_type = "protobuf"`, OTLP/HTTP). Internally, Telegraf converts metrics to Influx line protocol, which drops optional histogram fields like `min`, `max`, and `start_time_unix_nano`. Databricks accepts these payloads since those fields are optional in the OTLP spec. Native OTLP collectors (Alloy, OTel Collector) pass metrics through without conversion and preserve full fidelity.

**The thesis:** Databricks exposes standard OTLP endpoints. Whatever collector you're already running, you can add a Databricks output — same three headers, data lands in Unity Catalog.

## Architecture

### Sidecar Mode

```
                        ┌───────────────────────────────────┐
                        │        Sidecar Collectors         │
                        │                                   │
                   ┌───→│  Fluent Bit       Logs            │
                   │    │  Telegraf         Metrics          │
┌─────────────┐    │    │  Grafana Alloy    All signals     │──→  Databricks
│  OTel       │────┘    │  Vector           Logs            │     OTLP Endpoints
│  Simulator  │─── OTLP │  OTel Collector   All signals     │
│             │────┐    │                                   │        │
└─────────────┘    │    └───────────────────────────────────┘        │
                   │                                                ▼
                   │          Each collector adds 3 headers:   ┌─────────────────┐
                   │          • Authorization                  │  Unity Catalog   │
                   └──────    • X-Databricks-UC-Table-Name     │  telemetry.otel  │
                              • X-Databricks-Workspace-Url     └─────────────────┘

  Tables created per collector:
  ├── fluentbit_otel_logs_v2       ├── alloy_otel_{logs,metrics,spans}_v2
  ├── telegraf_otel_metrics        ├── otelcol_otel_{logs,metrics,spans}_v2
  └── vector_otel_logs_v2
```

### Direct Mode

```
┌─────────────┐     OTLP/HTTP      ┌─────────────────┐
│  OTel       │────────────────────→│  Unity Catalog   │
│  Simulator  │     + 3 headers     │  telemetry.otel  │
└─────────────┘                     └─────────────────┘

  Tables:
  ├── direct_otel_spans_v2
  ├── direct_otel_logs_v2
  └── direct_otel_metrics
```

### Signal Fan-out

Each event emitted by the simulator fans out to every collector that handles that signal type:

| Signal | Collectors | Ports |
|--------|-----------|-------|
| **Logs** | Fluent Bit, Vector, Grafana Alloy, OTel Collector | :4318, :4322, :4320, :4323 |
| **Metrics** | Telegraf, Grafana Alloy, OTel Collector | :4319, :4320, :4323 |
| **Traces** | Grafana Alloy, OTel Collector | :4320, :4323 |

### How It Works

1. **The app emits telemetry using the OpenTelemetry Python SDK** — traces, logs, and metrics via OTLP exporters. Multiple exporters per signal fan out to all capable collectors.

2. **In sidecar mode** (`OTEL_SIDECAR_MODE=true`), each signal routes to every collector that handles it. The OTel SDK natively supports multiple span processors, log processors, and metric readers.

3. **Each collector receives OTLP data and forwards it** to the Databricks OTLP ingest endpoint, injecting the three required headers: `Authorization`, `X-Databricks-UC-Table-Name`, `X-Databricks-Workspace-Url`.

4. **Data lands in Unity Catalog** in `telemetry.otel`, with each table prefixed by the collector name — so you can compare how each collector delivers the same telemetry.

## Quick Start

### 1. Install collectors

```bash
./collectors/install.sh
```

Installs Fluent Bit, Telegraf, Grafana Alloy, Vector, and OTel Collector.

### 2. Create tables

Run `sql/setup_otel_tables.sql` against your Databricks workspace to create the target tables in `telemetry.otel`.

### 3. Configure environment

```bash
cp .env.example .env
# Edit .env — set DATABRICKS_HOST and DATABRICKS_TOKEN
```

### 4. Run everything

```bash
./start-all.sh
```

Launches all 5 collectors, the OTel Simulator (`http://localhost:8000`), and LakeEO Dashboard (`http://localhost:8001`).

Press `Ctrl+C` to stop all processes.

### Direct Mode (no sidecars)

To bypass the collectors and send directly to Databricks:

```bash
# In .env
OTEL_SIDECAR_MODE=false
```

Then run the app standalone:

```bash
cd app_otel_sim
uvicorn backend.server:app --port 8000
```

## Repo Structure

```
├── start-all.sh              # Launch all 5 collectors + app
├── .env.example                   # Environment config template
├── databricks.yml                 # Databricks bundle config
│
├── app_otel_sim/                  # Simulator app (FastAPI)
│   ├── backend/
│   │   ├── emitter.py             # OTel SDK setup + fan-out routing
│   │   ├── server.py              # API endpoints + sidecar health
│   │   ├── scenarios.py           # Enterprise event topologies
│   │   └── models.py              # Response models
│   └── frontend/                  # Static HTML/JS/CSS UI
│
├── app_lake_eo/                   # LakeEO — Enterprise Observability dashboard
│   ├── backend/                   # SQL queries against UC tables
│   └── frontend/                  # Dashboard UI
│
├── collectors/                    # Sidecar collector configs
│   ├── install.sh                 # Install all 5 collectors
│   ├── fluent-bit/
│   │   └── fluent-bit.yaml        # Fluent Bit (logs)
│   ├── telegraf/
│   │   └── telegraf.conf          # Telegraf (metrics — gauges only)
│   ├── alloy/
│   │   └── config.alloy           # Grafana Alloy (logs + metrics + traces)
│   ├── vector/
│   │   └── vector.yaml            # Vector (logs)
│   └── otel-collector/
│       └── otel-collector.yaml    # OTel Collector (logs + metrics + traces)
│
├── sql/
│   └── setup_otel_tables.sql      # Create 9 tables in telemetry.otel
│
├── notebooks/                     # Jupyter notebooks for testing
└── reference/                     # Reference OTel implementation
```

## Target Tables

Tables in `telemetry.otel`, prefixed by collector:

| Table | Collector | Signal |
|-------|-----------|--------|
| `fluentbit_otel_logs_v2` | Fluent Bit | Logs |
| `vector_otel_logs_v2` | Vector | Logs |
| `alloy_otel_logs_v2` | Grafana Alloy | Logs |
| `otelcol_otel_logs_v2` | OTel Collector | Logs |
| `telegraf_otel_metrics` | Telegraf | Metrics |
| `alloy_otel_metrics` | Grafana Alloy | Metrics |
| `otelcol_otel_metrics` | OTel Collector | Metrics |
| `alloy_otel_spans_v2` | Grafana Alloy | Traces |
| `otelcol_otel_spans_v2` | OTel Collector | Traces |
