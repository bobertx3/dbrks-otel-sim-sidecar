# OTel Simulator — 4 Collectors to Databricks

An OpenTelemetry simulator that demonstrates how four different open-source collectors can forward telemetry to Databricks Unity Catalog through the [Zerobus Ingest OTLP endpoint](https://docs.databricks.com/aws/en/ingestion/opentelemetry/). Each collector handles the signal types it's purpose-built for.

## Collector-to-Signal Mapping

| Collector | Logs | Metrics | Traces | Rationale |
|-----------|:----:|:-------:|:------:|-----------|
| **Fluent Bit** | Yes | - | - | Purpose-built log processor. ~1MB footprint, 300+ plugins, de facto standard for K8s log collection. |
| **Telegraf** | - | Yes | - | InfluxData's metrics agent. Supports OTLP input (gRPC) and OTLP/HTTP output. Drops optional histogram fields (min/max) during internal conversion, but Databricks accepts the payloads. |
| **Grafana Alloy** | Yes | Yes | Yes | Full OTel-native collector. Handles all signals with component-based pipelines. Best fit for Grafana ecosystem teams. |
| **Vector** | Yes | - | - | High-performance Rust-based pipeline. Excels at log collection and transformation (VRL). |

The OTel Collector was removed: it carries the same standard OTLP data as **direct mode** (the simulator's own OTel SDK exporters), so it didn't show anything new.

### Telegraf Note

Telegraf receives OTLP metrics via its [OpenTelemetry input plugin](https://docs.influxdata.com/telegraf/v1/input-plugins/opentelemetry/) (gRPC on :4319) and forwards them to Databricks using the [OpenTelemetry output plugin](https://docs.influxdata.com/telegraf/v1/output-plugins/opentelemetry/) (`encoding_type = "protobuf"`, OTLP/HTTP). Internally, Telegraf converts metrics to Influx line protocol, which drops optional histogram fields like `min`, `max`, and `start_time_unix_nano`. Databricks accepts these payloads since those fields are optional in the OTLP spec. Grafana Alloy passes metrics through without conversion and preserves full fidelity.

**The thesis:** Databricks exposes a standard OTLP endpoint. Whatever collector you're already running, point it at the Zerobus host, add two headers, and data lands in Unity Catalog.

## Architecture

### Sidecar Mode

```
                        ┌───────────────────────────────────┐
                        │        Sidecar Collectors         │
                   ┌───→│  Fluent Bit       Logs            │
┌─────────────┐    │    │  Telegraf         Metrics         │──→  Zerobus Ingest OTLP
│  OTel       │────┘    │  Grafana Alloy    All signals     │     <workspace-id>.zerobus.<region>
│  Simulator  │─── OTLP │  Vector           Logs            │     .cloud.databricks.com/v1/*
└─────────────┘         └───────────────────────────────────┘              │
                                                                           ▼
                          Each collector sends 2 headers:         ┌─────────────────┐
                          • Authorization: Bearer <token>         │  Unity Catalog  │
                          • x-databricks-zerobus-table-name       │  bldemos.otel   │
                                                                  └─────────────────┘
  Tables per collector:
  ├── fluentbit_otel_logs          ├── alloy_otel_{spans,logs,metrics}
  ├── telegraf_otel_metrics        └── vector_otel_logs
```

### Direct Mode

```
┌─────────────┐   OTLP/HTTP + 2 headers   ┌─────────────────┐
│  OTel       │──────────────────────────→│  Zerobus Ingest │──→  bldemos.otel.direct_otel_{spans,logs,metrics}
│  Simulator  │                           │  OTLP endpoint  │
└─────────────┘                           └─────────────────┘
```

### Signal Fan-out

In sidecar mode, each event fans out to every collector that handles that signal type, so the same telemetry lands once per collector:

| Signal | Collectors | Ports |
|--------|-----------|-------|
| **Logs** | Fluent Bit, Vector, Grafana Alloy | :4318, :4322, :4320 |
| **Metrics** | Telegraf, Grafana Alloy | :4319, :4320 |
| **Traces** | Grafana Alloy | :4320 |

### How It Works

1. **The app emits telemetry using the OpenTelemetry Python SDK** — traces, logs, and metrics via OTLP exporters, batched in the background (`BatchSpanProcessor` / `BatchLogRecordProcessor`, 500 ms).
2. **In sidecar mode** (`OTEL_SIDECAR_MODE=true`), each signal routes to every local collector that handles it. **In direct mode**, the SDK sends straight to Zerobus.
3. **Each collector forwards to the Zerobus Ingest OTLP endpoint** with two headers: `Authorization` (a table-scoped OAuth token) and `x-databricks-zerobus-table-name`.
4. **Data lands in Unity Catalog** in `bldemos.otel`, with each table prefixed by the collector name — so you can compare how each collector delivers the same telemetry.

### Authentication (service principal → per-table tokens)

Zerobus only accepts OAuth tokens issued to a **service principal**, and each token is scoped to **one table**. `start-all.sh` handles this:

1. `scripts/oauth_token_refresh.py --auth-method zerobus` uses `DATABRICKS_CLIENT_ID` / `DATABRICKS_CLIENT_SECRET` to request one token per table from `{DATABRICKS_HOST}/oidc/v1/token` (with `resource=…/zerobusDirectWriteApi` and table-scoped `authorization_details`).
2. Tokens are written to `/tmp/.databricks_zerobus_tokens/<catalog.schema.table>.token` and refreshed ~1 minute before they expire (every ~59 min).
3. Collectors get their token as an env var (`ZB_TOKEN_*`, see `ZB_TABLE_TOKENS` in `start-all.sh`).

| Component | After the first hour |
|-----------|----------------------|
| Fluent Bit | Keeps working — `start-fluent-bit.sh` restarts it when its token file changes |
| Simulator direct mode | Keeps working — reads the token file on every export |
| Telegraf, Alloy, Vector | Read their token once at startup — **restart `./start-all.sh` after ~1 hour** |

The apps' own SQL queries (table counts, LakeEO dashboard) run as **you**, via the Databricks CLI profile in `DATABRICKS_CONFIG_PROFILE`.

## Fresh Install (new computer)

Tested on macOS (Apple Silicon) with: Python 3.14, Databricks CLI v1.20, Fluent Bit 4.2, Telegraf 1.38, Grafana Alloy 1.8, Vector 0.54.

### 1. Download prerequisites

| What | How | Why |
|------|-----|-----|
| **Homebrew** | [brew.sh](https://brew.sh) | Installs the CLI and most collectors |
| **Python 3.10+** | `brew install python` | Runs the simulator, dashboard, and token refresher |
| **Databricks CLI** | `brew tap databricks/tap && brew install databricks` | The apps run SQL through a CLI profile |
| **Fluent Bit, Telegraf, Vector** | installed by `./install.sh` (via Homebrew) | Sidecar collectors |
| **Grafana Alloy** | downloaded by `./install.sh` into `collectors/bin/` | Sidecar collector (no Homebrew formula used) |

Collector binaries are **not in git** — they're large (Telegraf alone is ~260 MB, over GitHub's 100 MB limit) and are ignored via `.gitignore` (`collectors/bin/`, `collectors/telegraf/telegraf`, `collectors/fluent-bit/fluent-bit`). Always install them with the script; never commit them.

### 2. Clone and log in to Databricks

```bash
git clone <repo-url> && cd dbrks-otel-sim-sidecar
databricks auth login --host https://<workspace>.cloud.databricks.com --profile DEFAULT
```

### 3. Set up the workspace (once per workspace)

1. **Catalog and schema:** `bldemos.otel` must exist (or find/replace `bldemos.otel` across the repo with your own).
2. **Service principal:** create one (this demo uses `bobertx3-otel`) and generate an **OAuth secret** for it (*Settings → Identity and access → Service principals → Secrets*). The secret is shown only once.
3. **Tables + grants:** run [`sql/setup_otel_tables.sql`](sql/setup_otel_tables.sql) on a SQL warehouse. It creates the 9 tables and grants the service principal `USE CATALOG`, `USE SCHEMA`, and `MODIFY, SELECT` on each table. Replace the service principal's application ID in the `GRANT` statements if you use a different one. (`ALL PRIVILEGES` is not sufficient.)
4. **Find your Zerobus host:** `<workspace-id>.zerobus.<region>.cloud.databricks.com`
   - Workspace ID: `grep workspace_id ~/.databrickscfg` (after step 2), or the `?o=` value in the workspace URL.
   - Region: `dig +short <workspace>.cloud.databricks.com` — the ELB name shows the AWS region (e.g. `us-east-1`).
   - The collector configs have the host written in directly — update it in `collectors/*/` if your workspace differs.

### 4. Install and configure

```bash
./install.sh                 # creates .venv, installs Python deps + collectors, creates .env from .env.example
```

Fill in `.env` (it is git-ignored — this is where the secret goes), then re-run `./install.sh` to validate it:

| Variable | Example / where to find it |
|----------|----------------------------|
| `DATABRICKS_HOST` | `https://fevm-bobertx3-aws-fevm.cloud.databricks.com` |
| `DATABRICKS_WORKSPACE_ID` | `7474645374628060` |
| `DATABRICKS_CONFIG_PROFILE` | `DEFAULT` (the profile from step 2) |
| `DATABRICKS_WAREHOUSE_ID` | SQL warehouse ID used for the apps' queries |
| `DATABRICKS_CLIENT_ID` | Service principal **application ID** (OAuth client ID) |
| `DATABRICKS_CLIENT_SECRET` | Service principal OAuth secret |
| `ZEROBUS_HOST` | `7474645374628060.zerobus.us-east-1.cloud.databricks.com` |
| `OTEL_DIRECT_{SPANS,LOGS,METRICS}_TABLE` | `bldemos.otel.direct_otel_{spans,logs,metrics}` |

Keep `<placeholder>` values quoted in `.env` — the file is `source`d by bash.

### 5. Run everything

```bash
source .venv/bin/activate    # start-all.sh uses python3/uvicorn from your PATH
./start-all.sh
```

Starts the token refresher, the 4 collectors, the OTel Simulator (`http://localhost:8000`), and the LakeEO Dashboard (`http://localhost:8001`). Press `Ctrl+C` to stop everything.

In the simulator: choose **Streaming** and press **Start** to emit continuously. Use the **Sidecar** toggle to switch between sidecar mode (collector tables) and direct mode (`direct_otel_*` tables).

## Target Tables

All in `bldemos.otel`, using the Zerobus OTLP table schema (`otel.schemaVersion = 'v2'` table property, `VARIANT` attributes):

| Table | Written by | Signal |
|-------|-----------|--------|
| `fluentbit_otel_logs` | Fluent Bit | Logs |
| `vector_otel_logs` | Vector | Logs |
| `alloy_otel_logs` | Grafana Alloy | Logs |
| `telegraf_otel_metrics` | Telegraf | Metrics |
| `alloy_otel_metrics` | Grafana Alloy | Metrics |
| `alloy_otel_spans` | Grafana Alloy | Traces |
| `direct_otel_spans` | Simulator (direct mode) | Traces |
| `direct_otel_logs` | Simulator (direct mode) | Logs |
| `direct_otel_metrics` | Simulator (direct mode) | Metrics |

`test/count_all_tables.sql` counts rows across all of them (and has commented-out `TRUNCATE`s to reset demo data).

## Repo Structure

```
├── install.sh                     # Fresh-install setup: venv, deps, collectors, .env check
├── start-all.sh                   # Token refresher + 4 collectors + both apps
├── .env.example                   # Environment config template (copy to .env)
├── requirements.txt
├── scripts/
│   └── oauth_token_refresh.py     # Service principal → per-table Zerobus tokens
│
├── app_otel_sim/                  # Simulator app (FastAPI)
│   ├── backend/
│   │   ├── emitter.py             # OTel SDK setup, fan-out routing, Zerobus direct mode
│   │   ├── server.py              # API endpoints + sidecar health
│   │   ├── scenarios.py           # Enterprise event topologies
│   │   └── models.py              # Response models
│   └── frontend/                  # Static HTML/JS/CSS UI
│
├── app_lake_eo/                   # LakeEO — Enterprise Observability dashboard
│   ├── backend/                   # SQL queries against UC tables
│   └── frontend/                  # Dashboard UI
│
├── collectors/                    # Sidecar collector configs (binaries are not in git)
│   ├── install.sh                 # Install all 4 collectors
│   ├── fluent-bit/
│   │   ├── fluent-bit.yaml        # Fluent Bit (logs)
│   │   └── start-fluent-bit.sh    # Restarts Fluent Bit when its token rotates
│   ├── telegraf/telegraf.conf     # Telegraf (metrics)
│   ├── alloy/config.alloy         # Grafana Alloy (logs + metrics + traces)
│   └── vector/vector.yaml         # Vector (logs)
│
├── sql/setup_otel_tables.sql      # Create 9 tables in bldemos.otel + service principal grants
└── test/count_all_tables.sql      # Row counts across all tables
```

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| `start-all.sh`: *Zerobus token for … not created after 30 s* | Check `DATABRICKS_CLIENT_ID` / `DATABRICKS_CLIENT_SECRET`; `invalid_client` in the log means the ID or secret is wrong |
| Collector logs show `401 Invalid token audience` | The token isn't a Zerobus token — Zerobus needs the service principal (personal/CLI logins are rejected) |
| Telegraf / Alloy / Vector start failing after ~1 hour | Their tokens expired — restart `./start-all.sh` |
| Table counts / dashboard return 500 | Check `DATABRICKS_WAREHOUSE_ID` exists and the CLI profile is logged in (`databricks auth login --profile DEFAULT`) |
| GitHub Desktop: *Files Too Large* (`collectors/telegraf/telegraf`) | Cancel — that's a local binary and must not be committed (it's in `.gitignore`) |
| `.env: parse error near '\n'` | Quote placeholder values: `DATABRICKS_CLIENT_SECRET="<secret>"` |
