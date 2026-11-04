#!/usr/bin/env python3
"""
OAuth Token Refresh Daemon for Databricks OTLP Collectors

Fetches an OAuth2 access token and writes it to a file that collector wrapper
scripts (Fluent Bit, Alloy, Vector, etc.) poll for changes.

Three auth methods:

  oidc  — Direct client-credentials grant against {DATABRICKS_HOST}/oidc/v1/token.
           Requires DATABRICKS_CLIENT_ID and DATABRICKS_CLIENT_SECRET.
           Best for: local dev, VMs, any environment with explicit SP credentials.

  zerobus — Client-credentials grant scoped to the Zerobus Ingest OTLP endpoint.
           Zerobus tokens are bound to a single Unity Catalog table, so one token is
           fetched per table and written to <token-dir>/<catalog.schema.table>.token.
           Requires DATABRICKS_CLIENT_ID, DATABRICKS_CLIENT_SECRET, DATABRICKS_WORKSPACE_ID.

  sdk   — Uses the Databricks Python SDK (WorkspaceClient) which auto-detects
           credentials from the runtime environment.
           Best for: Databricks Apps (automatic SP auth), or any environment
           where the SDK is already configured (profiles, env vars, etc.).

Usage:
    # Local with explicit credentials
    python3 scripts/oauth_token_refresh.py --auth-method oidc

    # Inside a Databricks App (auto SP auth)
    python3 scripts/oauth_token_refresh.py --auth-method sdk

    # Zerobus OTLP endpoint (one token per table)
    python3 scripts/oauth_token_refresh.py --auth-method zerobus \
        --token-dir /tmp/.databricks_zerobus_tokens \
        --tables bldemos.otel.alloy_otel_spans,bldemos.otel.alloy_otel_logs

Environment variables:
    DATABRICKS_HOST          — workspace URL (required for both methods)
    DATABRICKS_CLIENT_ID     — SP client ID (oidc and zerobus methods)
    DATABRICKS_CLIENT_SECRET — SP secret (oidc and zerobus methods)
    DATABRICKS_WORKSPACE_ID  — numeric workspace ID (zerobus method only)
"""

import argparse
import json
import logging
import os
import stat
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [token-refresh] %(levelname)s  %(message)s",
    stream=sys.stderr,
)
log = logging.getLogger("token-refresh")


# ── OIDC client-credentials flow ────────────────────────────────

def fetch_token_oidc(
    host: str, client_id: str, client_secret: str, extra_params: dict[str, str] | None = None
) -> tuple[str, int]:
    """Return (access_token, expires_in_seconds) from the OIDC endpoint."""
    import base64

    url = f"{host.rstrip('/')}/oidc/v1/token"
    body = urllib.parse.urlencode({
        "grant_type": "client_credentials",
        "scope": "all-apis",
        **(extra_params or {}),
    }).encode()

    credentials = base64.b64encode(f"{client_id}:{client_secret}".encode()).decode()

    req = urllib.request.Request(
        url,
        data=body,
        headers={
            "Content-Type": "application/x-www-form-urlencoded",
            "Authorization": f"Basic {credentials}",
        },
        method="POST",
    )

    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            data = json.loads(resp.read())
    except urllib.error.HTTPError as exc:
        error_body = exc.read().decode(errors="replace")
        raise RuntimeError(
            f"Token request failed ({exc.code}): {error_body}"
        ) from exc

    return data["access_token"], int(data.get("expires_in", 3600))


# ── Zerobus Ingest flow ─────────────────────────────────────────

def zerobus_token_params(workspace_id: str, table: str) -> dict[str, str]:
    """Token request params that scope a token to one table on the Zerobus endpoint."""
    catalog, schema, _ = table.split(".")
    authorization_details = [
        {"type": "unity_catalog_privileges", "privileges": ["USE CATALOG"],
         "object_type": "CATALOG", "object_full_path": catalog},
        {"type": "unity_catalog_privileges", "privileges": ["USE SCHEMA"],
         "object_type": "SCHEMA", "object_full_path": f"{catalog}.{schema}"},
        {"type": "unity_catalog_privileges", "privileges": ["SELECT", "MODIFY"],
         "object_type": "TABLE", "object_full_path": table},
    ]
    return {
        "resource": f"api://databricks/workspaces/{workspace_id}/zerobusDirectWriteApi",
        "authorization_details": json.dumps(authorization_details),
    }


def zerobus_token_file(token_dir: str, table: str) -> str:
    return os.path.join(token_dir, f"{table}.token")


# ── Databricks SDK flow ─────────────────────────────────────────

def fetch_token_sdk() -> tuple[str, int]:
    """Return (access_token, expires_in_seconds) via the Databricks SDK.

    The SDK auto-detects credentials from the environment: Databricks Apps
    runtime injects SP auth automatically; locally it reads profiles or
    DATABRICKS_TOKEN / DATABRICKS_CLIENT_ID env vars.

    The SDK doesn't expose expires_in, so we conservatively assume 3600 s
    (the standard Databricks OAuth token lifetime).
    """
    from databricks.sdk import WorkspaceClient

    w = WorkspaceClient()
    header = w.config.authenticate()
    if header and "Authorization" in header:
        token = header["Authorization"].replace("Bearer ", "")
        return token, 3600

    raise RuntimeError("Databricks SDK returned no Authorization header")


# ── Shared helpers ───────────────────────────────────────────────

def write_token_atomic(token: str, path: str) -> None:
    """Write token to *path* atomically (temp-file + rename), chmod 600."""
    dir_name = os.path.dirname(path) or "/tmp"
    fd, tmp_path = tempfile.mkstemp(dir=dir_name, prefix=".oauth_token_")
    try:
        os.write(fd, token.encode())
        os.fchmod(fd, stat.S_IRUSR | stat.S_IWUSR)  # 0600
        os.close(fd)
        os.rename(tmp_path, path)
    except BaseException:
        os.close(fd) if not os.get_inheritable(fd) else None
        os.unlink(tmp_path)
        raise


def run(auth_method: str, token_file: str, refresh_margin: int,
        token_dir: str = "", tables: list[str] | None = None) -> None:
    host = os.environ.get("DATABRICKS_HOST", "").rstrip("/")

    if auth_method in ("oidc", "zerobus"):
        client_id = os.environ.get("DATABRICKS_CLIENT_ID", "")
        client_secret = os.environ.get("DATABRICKS_CLIENT_SECRET", "")
        if not host:
            log.error("DATABRICKS_HOST is not set")
            sys.exit(1)
        if not client_id or not client_secret:
            log.error("DATABRICKS_CLIENT_ID and DATABRICKS_CLIENT_SECRET must be set")
            sys.exit(1)

    if auth_method == "zerobus":
        run_zerobus(host, client_id, client_secret, token_dir, tables or [], refresh_margin)
        return

    if auth_method == "oidc":
        log.info("Auth method: OIDC client credentials")
        log.info("Token endpoint: %s/oidc/v1/token", host)

        def _fetch() -> tuple[str, int]:
            return fetch_token_oidc(host, client_id, client_secret)

    elif auth_method == "sdk":
        log.info("Auth method: Databricks SDK (auto-detect)")

        def _fetch() -> tuple[str, int]:
            return fetch_token_sdk()

    else:
        log.error("Unknown auth method: %s (expected 'oidc', 'zerobus' or 'sdk')", auth_method)
        sys.exit(1)

    log.info("Token file:     %s", token_file)
    log.info("Refresh margin: %ds before expiry", refresh_margin)

    while True:
        try:
            token, expires_in = _fetch()
            write_token_atomic(token, token_file)
            sleep_for = max(expires_in - refresh_margin, 30)
            log.info(
                "Token acquired (expires in %ds). Next refresh in %ds.",
                expires_in,
                sleep_for,
            )
            time.sleep(sleep_for)
        except Exception:
            log.exception("Token refresh failed — retrying in 15s")
            time.sleep(15)


def run_zerobus(host: str, client_id: str, client_secret: str, token_dir: str,
                tables: list[str], refresh_margin: int) -> None:
    """Keep one table-scoped Zerobus token per table fresh in *token_dir*."""
    workspace_id = os.environ.get("DATABRICKS_WORKSPACE_ID", "")
    if not workspace_id:
        log.error("DATABRICKS_WORKSPACE_ID must be set for the zerobus method")
        sys.exit(1)
    if not token_dir or not tables:
        log.error("--token-dir and --tables are required for the zerobus method")
        sys.exit(1)
    os.makedirs(token_dir, mode=0o700, exist_ok=True)
    log.info("Auth method: Zerobus client credentials (workspace %s)", workspace_id)
    log.info("Token dir:      %s (%d tables)", token_dir, len(tables))

    while True:
        min_expiry = None
        failed = False
        for table in tables:
            try:
                token, expires_in = fetch_token_oidc(
                    host, client_id, client_secret, zerobus_token_params(workspace_id, table)
                )
                write_token_atomic(token, zerobus_token_file(token_dir, table))
                min_expiry = expires_in if min_expiry is None else min(min_expiry, expires_in)
            except Exception:
                log.exception("Token refresh failed for %s", table)
                failed = True
        if failed or min_expiry is None:
            log.info("Retrying in 15s")
            time.sleep(15)
            continue
        sleep_for = max(min_expiry - refresh_margin, 30)
        log.info("Acquired %d tokens (expire in %ds). Next refresh in %ds.",
                 len(tables), min_expiry, sleep_for)
        time.sleep(sleep_for)


def main() -> None:
    parser = argparse.ArgumentParser(description="Databricks OAuth token refresh daemon")
    parser.add_argument(
        "--auth-method",
        choices=["oidc", "zerobus", "sdk"],
        default=os.environ.get("DATABRICKS_AUTH_METHOD", "oidc"),
        help="Token acquisition method: 'oidc' (client credentials), 'zerobus' (per-table "
             "Zerobus tokens) or 'sdk' (auto-detect). Default: oidc, or DATABRICKS_AUTH_METHOD env var.",
    )
    parser.add_argument(
        "--token-file",
        default=os.environ.get("DATABRICKS_OAUTH_TOKEN_FILE", "/tmp/.databricks_oauth_token"),
        help="Path to write the bearer token (default: /tmp/.databricks_oauth_token)",
    )
    parser.add_argument(
        "--refresh-margin",
        type=int,
        default=60,
        help="Seconds before expiry to refresh (default: 60)",
    )
    parser.add_argument(
        "--token-dir",
        default=os.environ.get("ZEROBUS_TOKEN_DIR", "/tmp/.databricks_zerobus_tokens"),
        help="Directory for per-table Zerobus tokens (zerobus method only)",
    )
    parser.add_argument(
        "--tables",
        default=os.environ.get("ZEROBUS_TABLES", ""),
        help="Comma-separated catalog.schema.table names to fetch Zerobus tokens for",
    )
    args = parser.parse_args()
    tables = [t.strip() for t in args.tables.split(",") if t.strip()]
    run(args.auth_method, args.token_file, args.refresh_margin, args.token_dir, tables)


if __name__ == "__main__":
    main()
