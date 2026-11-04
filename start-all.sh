#!/usr/bin/env bash
set -euo pipefail

# Launch all 4 sidecar collectors, the OTel Simulator app, and the LakeEO Dashboard.
# Ctrl+C cleanly stops all processes.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${GREEN}[start]${NC} $*"; }
label() { echo -e "${CYAN}[start]${NC} $*"; }

# Load .env
if [[ -f .env ]]; then
    set -a
    source .env
    set +a
    info "Loaded .env"
else
    echo -e "${RED}[start]${NC} .env file not found. Copy .env.example to .env and fill in values."
    exit 1
fi

# Derive bare host (strip https://)
export DATABRICKS_HOST_BARE="${DATABRICKS_HOST#https://}"
export DATABRICKS_HOST_BARE="${DATABRICKS_HOST_BARE#http://}"
info "Workspace: $DATABRICKS_HOST_BARE"

# Track child PIDs for cleanup
PIDS=()
cleanup() {
    echo ""
    info "Shutting down..."
    for pid in "${PIDS[@]}"; do
        kill "$pid" 2>/dev/null || true
    done
    wait 2>/dev/null
    info "All processes stopped."
}
trap cleanup EXIT INT TERM

# Env for the Python apps (overridden in OAuth mode below)
APP_ENV=(env)

# ─── OAuth token refresh (optional) ───────────────────────────
if [[ "${DATABRICKS_AUTH_TYPE:-}" == "oauth" && "${DATABRICKS_AUTH_METHOD:-}" == "zerobus" ]]; then
    # Zerobus tokens are scoped to a single table, so fetch one per table.
    # Each entry: <env var the collector config reads>=<table>
    ZB_TABLE_TOKENS=(
        ZB_TOKEN_FLUENTBIT_LOGS=bldemos.otel.fluentbit_otel_logs
        ZB_TOKEN_TELEGRAF_METRICS=bldemos.otel.telegraf_otel_metrics
        ZB_TOKEN_ALLOY_SPANS=bldemos.otel.alloy_otel_spans
        ZB_TOKEN_ALLOY_LOGS=bldemos.otel.alloy_otel_logs
        ZB_TOKEN_ALLOY_METRICS=bldemos.otel.alloy_otel_metrics
        ZB_TOKEN_VECTOR_LOGS=bldemos.otel.vector_otel_logs
        ZB_TOKEN_DIRECT_SPANS="$OTEL_DIRECT_SPANS_TABLE"
        ZB_TOKEN_DIRECT_LOGS="$OTEL_DIRECT_LOGS_TABLE"
        ZB_TOKEN_DIRECT_METRICS="$OTEL_DIRECT_METRICS_TABLE"
    )
    export ZEROBUS_TOKEN_DIR="${ZEROBUS_TOKEN_DIR:-/tmp/.databricks_zerobus_tokens}"
    ZB_TABLES="$(printf '%s\n' "${ZB_TABLE_TOKENS[@]}" | cut -d= -f2 | paste -sd, -)"

    info "Zerobus mode: fetching ${#ZB_TABLE_TOKENS[@]} table-scoped tokens..."
    env -u DATABRICKS_AUTH_TYPE python3 "$SCRIPT_DIR/scripts/oauth_token_refresh.py" \
        --auth-method zerobus --token-dir "$ZEROBUS_TOKEN_DIR" --tables "$ZB_TABLES" &
    PIDS+=($!)

    # Wait for every token file (up to 30 s), then export each as its env var
    for entry in "${ZB_TABLE_TOKENS[@]}"; do
        var="${entry%%=*}"; file="$ZEROBUS_TOKEN_DIR/${entry#*=}.token"
        for _i in $(seq 1 30); do
            [[ -s "$file" ]] && break
            sleep 1
        done
        if [[ ! -s "$file" ]]; then
            echo -e "${RED}[start]${NC} Zerobus token for ${entry#*=} not created after 30 s — check DATABRICKS_CLIENT_ID/SECRET and grants."
            exit 1
        fi
        export "$var=$(cat "$file")"
    done
    info "Zerobus tokens acquired"

    # Fluent Bit's wrapper watches its own token file and restarts on rotation
    export DATABRICKS_OAUTH_TOKEN_FILE="$ZEROBUS_TOKEN_DIR/bldemos.otel.fluentbit_otel_logs.token"

    # Apps load .env themselves (load_dotenv won't override an existing var), so blank
    # these rather than unsetting them: the apps query SQL with the CLI profile, and the
    # simulator's direct mode reads its Zerobus tokens from ZEROBUS_TOKEN_DIR.
    APP_ENV=(env -u DATABRICKS_TOKEN DATABRICKS_AUTH_TYPE= DATABRICKS_CLIENT_ID= DATABRICKS_CLIENT_SECRET=)

elif [[ "${DATABRICKS_AUTH_TYPE:-}" == "oauth" ]]; then
    info "OAuth mode: starting token refresh daemon..."
    TOKEN_FILE="${DATABRICKS_OAUTH_TOKEN_FILE:-/tmp/.databricks_oauth_token}"
    AUTH_METHOD="${DATABRICKS_AUTH_METHOD:-oidc}"
    # The SDK also reads DATABRICKS_AUTH_TYPE and rejects "oauth", so hide it from Python processes
    env -u DATABRICKS_AUTH_TYPE python3 "$SCRIPT_DIR/scripts/oauth_token_refresh.py" --auth-method "$AUTH_METHOD" --token-file "$TOKEN_FILE" &
    PIDS+=($!)

    # Wait for the daemon to write the initial token (up to 15 s)
    for _i in $(seq 1 15); do
        [[ -s "$TOKEN_FILE" ]] && break
        sleep 1
    done
    if [[ ! -s "$TOKEN_FILE" ]]; then
        echo -e "${RED}[start]${NC} OAuth token file not created after 15 s — check credentials."
        exit 1
    fi
    export DATABRICKS_TOKEN="$(cat "$TOKEN_FILE")"
    info "OAuth token acquired"

    # Apps load .env themselves (load_dotenv won't override an existing var), so blank
    # DATABRICKS_AUTH_TYPE rather than unsetting it. Drop the static token so the apps
    # authenticate via the SDK, which refreshes on its own.
    APP_ENV=(env -u DATABRICKS_TOKEN DATABRICKS_AUTH_TYPE=)
fi

# Resolve collector binaries (prefer collectors/bin/, then PATH)
ALLOY_BIN="$(command -v alloy 2>/dev/null || echo "collectors/bin/alloy")"
VECTOR_BIN="$(command -v vector 2>/dev/null || echo "collectors/bin/vector")"

# ─── Sidecars ───────────────────────────────────────────────

label "Starting Fluent Bit on :4318 (logs)"
bash collectors/fluent-bit/start-fluent-bit.sh &
PIDS+=($!)

label "Starting Telegraf on :4319 (metrics — gauges only)"
telegraf --config collectors/telegraf/telegraf.conf &
PIDS+=($!)

label "Starting Grafana Alloy on :4320 (logs + metrics + traces)"
"$ALLOY_BIN" run collectors/alloy/config.alloy &
PIDS+=($!)

label "Starting Vector on :4322 (logs)"
"$VECTOR_BIN" --config collectors/vector/vector.yaml &
PIDS+=($!)

# Brief pause for collectors to bind ports
sleep 3

# ─── Apps ───────────────────────────────────────────────────

label "Starting OTel Simulator app on :8000"
cd app_otel_sim
"${APP_ENV[@]}" uvicorn backend.server:app --host 0.0.0.0 --port 8000 &
PIDS+=($!)
cd "$SCRIPT_DIR"

label "Starting LakeEO Dashboard on :8001"
cd app_lake_eo
"${APP_ENV[@]}" uvicorn backend.server:app --host 0.0.0.0 --port 8001 &
PIDS+=($!)
cd "$SCRIPT_DIR"

echo ""
info "=== All services running ==="
info ""
info "  Sidecars:"
info "    Fluent Bit     (logs)                → localhost:4318"
info "    Telegraf       (metrics/gauges)      → localhost:4319"
info "    Grafana Alloy  (logs+metrics+traces) → localhost:4320"
info "    Vector         (logs)                → localhost:4322"
info ""
info "  Apps:"
info "    Simulator      → http://localhost:8000"
info "    LakeEO Dashboard  → http://localhost:8001"
info ""
info "Press Ctrl+C to stop all services."
echo ""

# Wait for any child to exit
wait
