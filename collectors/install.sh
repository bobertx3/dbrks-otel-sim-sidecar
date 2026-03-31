#!/usr/bin/env bash
set -euo pipefail

# Install Fluent Bit, Telegraf, Grafana Alloy, Vector, and OTel Collector
# for local sidecar collection. Prefers Homebrew on macOS.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$SCRIPT_DIR/bin"
mkdir -p "$BIN_DIR"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[install]${NC} $*"; }
warn()  { echo -e "${YELLOW}[install]${NC} $*"; }
error() { echo -e "${RED}[install]${NC} $*" >&2; }

check_cmd() { command -v "$1" &>/dev/null; }

# --- Fluent Bit ---
install_fluent_bit() {
    if check_cmd fluent-bit; then
        info "Fluent Bit already installed: $(fluent-bit --version 2>/dev/null | head -1)"
        return
    fi
    if check_cmd brew; then
        info "Installing Fluent Bit via Homebrew..."
        brew install fluent-bit
    else
        error "Homebrew not found. Install Fluent Bit manually: https://docs.fluentbit.io/manual/installation"
        return 1
    fi
    info "Fluent Bit installed: $(fluent-bit --version 2>/dev/null | head -1)"
}

# --- Telegraf ---
install_telegraf() {
    if check_cmd telegraf; then
        info "Telegraf already installed: $(telegraf --version 2>/dev/null | head -1)"
        return
    fi
    if check_cmd brew; then
        info "Installing Telegraf via Homebrew..."
        brew install telegraf
    else
        error "Homebrew not found. Install Telegraf manually: https://docs.influxdata.com/telegraf/v1/install/"
        return 1
    fi
    info "Telegraf installed: $(telegraf --version 2>/dev/null | head -1)"
}

# --- Grafana Alloy ---
install_alloy() {
    if [[ -x "$BIN_DIR/alloy" ]] || check_cmd alloy; then
        info "Grafana Alloy already installed"
        return
    fi
    info "Downloading Grafana Alloy binary..."
    local arch="arm64"
    [[ "$(uname -m)" == "x86_64" ]] && arch="amd64"
    local url="https://github.com/grafana/alloy/releases/download/v1.8.3/alloy-darwin-${arch}.zip"
    curl -sL "$url" -o "$BIN_DIR/alloy.zip"
    (cd "$BIN_DIR" && unzip -o alloy.zip && rm alloy.zip && chmod +x alloy-darwin-${arch} && ln -sf alloy-darwin-${arch} alloy)
    info "Grafana Alloy installed: $($BIN_DIR/alloy --version 2>&1 | head -1)"
}

# --- Vector ---
install_vector() {
    if check_cmd vector; then
        info "Vector already installed: $(vector --version 2>/dev/null | head -1)"
        return
    fi
    if check_cmd brew; then
        info "Installing Vector via Homebrew..."
        brew install vector
    else
        error "Homebrew not found. Install Vector manually: https://vector.dev/docs/setup/installation/"
        return 1
    fi
    info "Vector installed: $(vector --version 2>/dev/null | head -1)"
}

# --- OTel Collector ---
install_otel_collector() {
    if [[ -x "$BIN_DIR/otelcol-contrib" ]] || check_cmd otelcol-contrib; then
        info "OTel Collector already installed"
        return
    fi
    info "Downloading OTel Collector Contrib binary..."
    local arch="arm64"
    [[ "$(uname -m)" == "x86_64" ]] && arch="amd64"
    local version="0.114.0"
    local url="https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v${version}/otelcol-contrib_${version}_darwin_${arch}.tar.gz"
    curl -sL "$url" -o "$BIN_DIR/otelcol.tar.gz"
    (cd "$BIN_DIR" && tar xzf otelcol.tar.gz otelcol-contrib && rm otelcol.tar.gz && chmod +x otelcol-contrib)
    info "OTel Collector installed: $($BIN_DIR/otelcol-contrib --version 2>&1 | head -1)"
}

echo ""
info "=== Installing OTel sidecar collectors ==="
echo ""

install_fluent_bit
install_telegraf
install_alloy
install_vector
install_otel_collector

echo ""
info "=== All 5 collectors installed ==="
info "Run ./start-sidecars.sh to launch the full stack."
