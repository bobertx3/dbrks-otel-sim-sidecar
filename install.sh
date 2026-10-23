#!/usr/bin/env bash
set -euo pipefail

# Full setup for the OTel Simulator + LakeEO dashboard.
# Installs Python deps, collector binaries, and validates config.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${GREEN}[setup]${NC} $*"; }
warn()  { echo -e "${YELLOW}[setup]${NC} $*"; }
error() { echo -e "${RED}[setup]${NC} $*" >&2; }
step()  { echo -e "\n${CYAN}━━━ $* ━━━${NC}"; }

# ─── Step 1: Python dependencies ───────────────────────────

step "Step 1/4: Python dependencies"

if ! command -v python3 &>/dev/null; then
    error "python3 not found. Please install Python 3.10+."
    exit 1
fi

info "Python: $(python3 --version)"

if ! command -v databricks &>/dev/null; then
    error "Databricks CLI not found. Install it with: brew tap databricks/tap && brew install databricks"
    exit 1
fi
info "Databricks CLI: $(databricks --version)"

if [[ -d ".venv" ]]; then
    info "Virtual environment already exists (.venv)"
else
    info "Creating virtual environment..."
    python3 -m venv .venv
fi

info "Installing Python dependencies..."
.venv/bin/pip install -q -r requirements.txt
info "Python dependencies installed."

# ─── Step 2: Collector binaries ────────────────────────────

step "Step 2/4: OTel sidecar collectors"

if [[ -f "collectors/install.sh" ]]; then
    bash collectors/install.sh
else
    error "collectors/install.sh not found"
    exit 1
fi

# ─── Step 3: Environment config ────────────────────────────

step "Step 3/4: Environment configuration"

if [[ ! -f ".env" ]]; then
    if [[ -f ".env.example" ]]; then
        cp .env.example .env
        warn "Created .env from .env.example"
    else
        error "No .env or .env.example found."
        exit 1
    fi
fi

echo ""
echo -e "  Your ${CYAN}.env${NC} file must have these values set:"
echo ""
echo -e "    ${CYAN}DATABRICKS_HOST${NC}              — Workspace URL (e.g. https://my-workspace.cloud.databricks.com)"
echo -e "    ${CYAN}DATABRICKS_WORKSPACE_ID${NC}      — Numeric workspace ID"
echo -e "    ${CYAN}DATABRICKS_CONFIG_PROFILE${NC}    — CLI profile the apps use for SQL queries"
echo -e "    ${CYAN}DATABRICKS_WAREHOUSE_ID${NC}      — SQL Warehouse ID for queries"
echo -e "    ${CYAN}DATABRICKS_CLIENT_ID${NC}         — Service principal application ID"
echo -e "    ${CYAN}DATABRICKS_CLIENT_SECRET${NC}     — Service principal OAuth secret"
echo -e "    ${CYAN}ZEROBUS_HOST${NC}                 — <workspace-id>.zerobus.<region>.cloud.databricks.com"
echo -e "    ${CYAN}OTEL_DIRECT_SPANS_TABLE${NC}      — Direct spans table (e.g. bldemos.otel.direct_otel_spans)"
echo -e "    ${CYAN}OTEL_DIRECT_LOGS_TABLE${NC}       — Direct logs table"
echo -e "    ${CYAN}OTEL_DIRECT_METRICS_TABLE${NC}    — Direct metrics table"
echo ""

# Validate key values are non-empty
set -a; source .env; set +a

MISSING=()
for var in DATABRICKS_HOST DATABRICKS_WORKSPACE_ID DATABRICKS_CONFIG_PROFILE DATABRICKS_WAREHOUSE_ID \
           DATABRICKS_CLIENT_ID DATABRICKS_CLIENT_SECRET ZEROBUS_HOST \
           OTEL_DIRECT_SPANS_TABLE OTEL_DIRECT_LOGS_TABLE OTEL_DIRECT_METRICS_TABLE; do
    val="${!var:-}"
    # Empty, or still the "<...>" placeholder from .env.example
    [[ -z "$val" || "$val" == *"<"* ]] && MISSING+=("$var")
done

if [[ ${#MISSING[@]} -gt 0 ]]; then
    error "Missing values in .env: ${MISSING[*]}"
    echo ""
    echo -e "  Edit ${CYAN}.env${NC} and fill in the missing values, then re-run this script."
    exit 1
fi

info "All required .env values are set."

# Quick connectivity check (the apps run SQL through this CLI profile)
echo ""
info "Testing Databricks CLI profile '${DATABRICKS_CONFIG_PROFILE}'..."
if ME=$(databricks current-user me -p "$DATABRICKS_CONFIG_PROFILE" -o json 2>/dev/null); then
    info "Connected to ${DATABRICKS_HOST} as $(echo "$ME" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("userName",""))')"
else
    warn "CLI profile '${DATABRICKS_CONFIG_PROFILE}' is not logged in. Run:"
    warn "  databricks auth login --host ${DATABRICKS_HOST} --profile ${DATABRICKS_CONFIG_PROFILE}"
fi

# ─── Step 4: Confirmation ─────────────────────────────────

step "Step 4/4: Ready to run"

echo ""
info "Setup complete. To start everything:"
echo ""
echo -e "    ${CYAN}source .venv/bin/activate${NC}"
echo -e "    ${CYAN}./start-all.sh${NC}"
echo ""
echo -e "  This launches 4 sidecar collectors + both apps:"
echo -e "    OTel Simulator   → ${CYAN}http://localhost:8000${NC}"
echo -e "    LakeEO Dashboard → ${CYAN}http://localhost:8001${NC}"
echo ""
