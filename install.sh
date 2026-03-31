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
echo -e "    ${CYAN}DATABRICKS_TOKEN${NC}             — Personal Access Token"
echo -e "    ${CYAN}OTEL_DIRECT_SPANS_TABLE${NC}      — Direct spans table (e.g. telemetry.otel.direct_otel_spans_v2)"
echo -e "    ${CYAN}OTEL_DIRECT_LOGS_TABLE${NC}       — Direct logs table"
echo -e "    ${CYAN}OTEL_DIRECT_METRICS_TABLE${NC}    — Direct metrics table"
echo -e "    ${CYAN}DATABRICKS_WAREHOUSE_ID${NC}      — SQL Warehouse ID for queries"
echo ""

# Validate key values are non-empty
set -a; source .env; set +a

MISSING=()
[[ -z "${DATABRICKS_HOST:-}" ]] && MISSING+=("DATABRICKS_HOST")
[[ -z "${DATABRICKS_TOKEN:-}" ]] && MISSING+=("DATABRICKS_TOKEN")
[[ -z "${OTEL_DIRECT_SPANS_TABLE:-}" ]] && MISSING+=("OTEL_DIRECT_SPANS_TABLE")
[[ -z "${OTEL_DIRECT_LOGS_TABLE:-}" ]] && MISSING+=("OTEL_DIRECT_LOGS_TABLE")
[[ -z "${OTEL_DIRECT_METRICS_TABLE:-}" ]] && MISSING+=("OTEL_DIRECT_METRICS_TABLE")
[[ -z "${DATABRICKS_WAREHOUSE_ID:-}" ]] && MISSING+=("DATABRICKS_WAREHOUSE_ID")

if [[ ${#MISSING[@]} -gt 0 ]]; then
    error "Missing values in .env: ${MISSING[*]}"
    echo ""
    echo -e "  Edit ${CYAN}.env${NC} and fill in the missing values, then re-run this script."
    exit 1
fi

info "All required .env values are set."

# Quick connectivity check
echo ""
info "Testing Databricks connectivity..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Authorization: Bearer ${DATABRICKS_TOKEN}" \
    "${DATABRICKS_HOST}/api/2.0/preview/scim/v2/Me" 2>/dev/null || echo "000")

if [[ "$HTTP_CODE" == "200" ]]; then
    info "Connected to ${DATABRICKS_HOST}"
elif [[ "$HTTP_CODE" == "000" ]]; then
    warn "Could not reach ${DATABRICKS_HOST} — check your network"
else
    warn "Databricks returned HTTP $HTTP_CODE — check your token"
fi

# ─── Step 4: Confirmation ─────────────────────────────────

step "Step 4/4: Ready to run"

echo ""
info "Setup complete. To start everything:"
echo ""
echo -e "    ${CYAN}./start-all.sh${NC}"
echo ""
echo -e "  This launches 5 sidecar collectors + both apps:"
echo -e "    OTel Simulator   → ${CYAN}http://localhost:8000${NC}"
echo -e "    LakeEO Dashboard → ${CYAN}http://localhost:8001${NC}"
echo ""
