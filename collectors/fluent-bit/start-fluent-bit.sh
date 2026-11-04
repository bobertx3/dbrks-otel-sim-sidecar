#!/usr/bin/env bash
# ────────────────────────────────────────────────────────────────
# Fluent Bit launcher with OAuth token-refresh support
#
# PAT mode  (default):  runs Fluent Bit directly — no wrapper needed.
# OAuth mode:           reads the token from a file written by
#                       scripts/oauth_token_refresh.py, and gracefully
#                       restarts Fluent Bit whenever the token rotates.
#
# Env vars:
#   DATABRICKS_AUTH_TYPE        — "oauth" to enable refresh; anything else = PAT
#   DATABRICKS_OAUTH_TOKEN_FILE — path to token file (default /tmp/.databricks_oauth_token)
#   DATABRICKS_HOST_BARE        — workspace host without https://
# ────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FB_CONFIG="${SCRIPT_DIR}/fluent-bit.yaml"
TOKEN_FILE="${DATABRICKS_OAUTH_TOKEN_FILE:-/tmp/.databricks_oauth_token}"
POLL_INTERVAL=30  # seconds between token-file checks

# ── PAT mode: just exec Fluent Bit ─────────────────────────────
if [[ "${DATABRICKS_AUTH_TYPE:-pat}" != "oauth" ]]; then
    exec fluent-bit -c "$FB_CONFIG"
fi

# ── OAuth mode: watch token file, restart on change ─────────────
echo "[fluent-bit-oauth] OAuth mode — watching ${TOKEN_FILE}"

cleanup() {
    [[ -n "${FB_PID:-}" ]] && kill "$FB_PID" 2>/dev/null || true
    wait "$FB_PID" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

while true; do
    # Read current token
    if [[ ! -f "$TOKEN_FILE" ]]; then
        echo "[fluent-bit-oauth] Waiting for token file..."
        sleep 2
        continue
    fi

    DATABRICKS_TOKEN="$(cat "$TOKEN_FILE")"
    export DATABRICKS_TOKEN

    echo "[fluent-bit-oauth] Starting Fluent Bit with fresh token"
    fluent-bit -c "$FB_CONFIG" &
    FB_PID=$!

    # Poll for token changes
    while kill -0 "$FB_PID" 2>/dev/null; do
        sleep "$POLL_INTERVAL"
        NEW_TOKEN="$(cat "$TOKEN_FILE" 2>/dev/null || echo "")"
        if [[ -n "$NEW_TOKEN" && "$NEW_TOKEN" != "$DATABRICKS_TOKEN" ]]; then
            echo "[fluent-bit-oauth] Token rotated — restarting Fluent Bit"
            kill "$FB_PID" 2>/dev/null || true
            wait "$FB_PID" 2>/dev/null || true
            break  # outer loop restarts with new token
        fi
    done
done
