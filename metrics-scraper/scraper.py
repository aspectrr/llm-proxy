"""
Bifrost → Supabase metrics scraper.

Polls the Bifrost GET /api/logs endpoint every SCRAPE_INTERVAL_SECONDS,
deduplicates against what's already been shipped, and upserts individual
log entries into the Supabase `bifrost_metrics` table.

Supabase table schema (create this in the SQL editor):

CREATE TABLE bifrost_metrics (
    id              TEXT PRIMARY KEY,          -- Bifrost log id
    parent_request_id TEXT,
    provider        TEXT,
    model           TEXT,
    status          TEXT,
    stream          BOOLEAN,
    timestamp       TIMESTAMPTZ,              -- Bifrost log timestamp
    latency_ms      DOUBLE PRECISION,         -- latency in ms
    total_cost_usd  DOUBLE PRECISION,
    input_cost_usd  DOUBLE PRECISION,
    output_cost_usd DOUBLE PRECISION,
    prompt_tokens   INTEGER,
    completion_tokens INTEGER,
    total_tokens    INTEGER,
    reasoning_tokens INTEGER,
    cached_read_tokens INTEGER,
    number_of_retries INTEGER,
    fallback_index  INTEGER,
    created_at      TIMESTAMPTZ DEFAULT now() -- insertion time
);

-- Indexes for the common query patterns your website will use
CREATE INDEX idx_metrics_timestamp ON bifrost_metrics (timestamp DESC);
CREATE INDEX idx_metrics_provider  ON bifrost_metrics (provider);
CREATE INDEX idx_metrics_model     ON bifrost_metrics (model);
"""

import json
import os
import sys
import time
from datetime import datetime, timezone

import requests
from supabase import create_client

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
BIFROST_URL = os.environ["BIFROST_URL"].rstrip("/")
BIFROST_ADMIN_USER = os.environ.get("BIFROST_ADMIN_USER", "cpfeifer")
BIFROST_ADMIN_PASSWORD = os.environ["BIFROST_ADMIN_PASSWORD"]
SUPABASE_URL = os.environ["SUPABASE_URL"]
SUPABASE_KEY = os.environ["SUPABASE_KEY"]
SCRAPE_INTERVAL = int(os.environ.get("SCRAPE_INTERVAL_SECONDS", "60"))

TABLE = "bifrost_metrics"

# ---------------------------------------------------------------------------
# Supabase client
# ---------------------------------------------------------------------------
supabase = create_client(SUPABASE_URL, SUPABASE_KEY)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def get_auth_token() -> str:
    """Authenticate with Bifrost and return a bearer token."""
    r = requests.post(
        f"{BIFROST_URL}/api/auth/login",
        json={
            "username": BIFROST_ADMIN_USER,
            "password": BIFROST_ADMIN_PASSWORD,
        },
        timeout=15,
    )
    r.raise_for_status()
    body = r.json()
    # Bifrost may return the token under different keys depending on version
    return body.get("token") or body.get("access_token") or body.get("data", {}).get("token")


def fetch_logs(token: str, offset: int = 0, limit: int = 200) -> dict:
    """Fetch a page of logs from Bifrost."""
    headers = {"Authorization": f"Bearer {token}"}
    params = {
        "offset": offset,
        "limit": limit,
        "sort_by": "timestamp",
        "order": "desc",
    }
    r = requests.get(
        f"{BIFROST_URL}/api/logs",
        headers=headers,
        params=params,
        timeout=30,
    )
    r.raise_for_status()
    return r.json()


def already_shipped_ids(ids: list[str]) -> set[str]:
    """Return the subset of `ids` that already exist in Supabase."""
    if not ids:
        return set()
    # Query in chunks of 100 to avoid URL length limits
    existing: set[str] = set()
    for i in range(0, len(ids), 100):
        chunk = ids[i : i + 100]
        resp = (
            supabase.table(TABLE)
            .select("id")
            .in_("id", chunk)
            .execute()
        )
        existing.update(row["id"] for row in resp.data)
    return existing


def extract_row(log: dict) -> dict | None:
    """Pull the fields we care about out of a Bifrost log entry."""
    usage = log.get("token_usage") or {}
    cost = usage.get("cost") or {}
    prompt_details = usage.get("prompt_tokens_details") or {}
    completion_details = usage.get("completion_tokens_details") or {}

    # Parse timestamp
    ts_raw = log.get("timestamp") or log.get("created_at")
    if not ts_raw:
        return None
    try:
        ts = datetime.fromisoformat(ts_raw.replace("Z", "+00:00"))
    except (ValueError, AttributeError):
        return None

    return {
        "id": log["id"],
        "parent_request_id": log.get("parent_request_id"),
        "provider": log.get("provider"),
        "model": log.get("model"),
        "status": log.get("status"),
        "stream": log.get("stream"),
        "timestamp": ts.isoformat(),
        "latency_ms": log.get("latency"),
        "total_cost_usd": cost.get("total_cost"),
        "input_cost_usd": cost.get("input_tokens_cost"),
        "output_cost_usd": cost.get("output_tokens_cost"),
        "prompt_tokens": usage.get("prompt_tokens"),
        "completion_tokens": usage.get("completion_tokens"),
        "total_tokens": usage.get("total_tokens"),
        "reasoning_tokens": completion_details.get("reasoning_tokens"),
        "cached_read_tokens": prompt_details.get("cached_read_tokens"),
        "number_of_retries": log.get("number_of_retries"),
        "fallback_index": log.get("fallback_index"),
    }


def ship_rows(rows: list[dict]) -> int:
    """Upsert rows into Supabase. Returns count inserted."""
    if not rows:
        return 0
    # upsert in chunks of 100
    shipped = 0
    for i in range(0, len(rows), 100):
        chunk = rows[i : i + 100]
        resp = (
            supabase.table(TABLE)
            .upsert(chunk, on_conflict="id")
            .execute()
        )
        shipped += len(resp.data) if resp.data else 0
    return shipped


# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------

def scrape_once(token: str) -> None:
    """Fetch recent logs and ship any new ones."""
    all_rows: list[dict] = []
    seen_ids: list[str] = []
    page = 0
    page_size = 200

    while True:
        data = fetch_logs(token, offset=page * page_size, limit=page_size)
        logs = data.get("logs", [])
        if not logs:
            break

        for log in logs:
            row = extract_row(log)
            if row:
                all_rows.append(row)
                seen_ids.append(log["id"])

        # If Bifrost returned fewer than page_size, we've reached the end
        if len(logs) < page_size:
            break
        page += 1

        # Safety: don't pull more than 10 pages per scrape
        if page >= 10:
            break

    # Deduplicate against Supabase
    existing = already_shipped_ids(seen_ids)
    new_rows = [r for r in all_rows if r["id"] not in existing]

    if new_rows:
        count = ship_rows(new_rows)
        print(f"[{datetime.now(timezone.utc).isoformat()}] Shipped {count} new log entries")
    else:
        print(f"[{datetime.now(timezone.utc).isoformat()}] No new logs")


def main() -> None:
    print(f"Starting metrics scraper (interval={SCRAPE_INTERVAL}s)")
    print(f"Bifrost URL: {BIFROST_URL}")
    print(f"Supabase URL: {SUPABASE_URL}")

    # Warm up: wait for Bifrost
    while True:
        try:
            requests.get(f"{BIFROST_URL}/api/health", timeout=5)
            print("Bifrost is ready")
            break
        except requests.ConnectionError:
            print("Waiting for Bifrost...")
            time.sleep(5)

    token = get_auth_token()
    print("Authenticated with Bifrost")

    while True:
        try:
            scrape_once(token)
        except requests.exceptions.HTTPError as e:
            # Token may have expired, re-auth
            if e.response is not None and e.response.status_code == 401:
                print("Token expired, re-authenticating...")
                token = get_auth_token()
                try:
                    scrape_once(token)
                except Exception:
                    print(f"Error after re-auth: {e}", file=sys.stderr)
            else:
                print(f"HTTP error: {e}", file=sys.stderr)
        except Exception as e:
            print(f"Error: {e}", file=sys.stderr)

        time.sleep(SCRAPE_INTERVAL)


if __name__ == "__main__":
    main()
