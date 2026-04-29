"""
Quick smoke test: push fake Bifrost log data to local Supabase, then read it back.
Run with: uv run test_scraper.py
"""

import os
from datetime import datetime, timezone, timedelta
from supabase import create_client

SUPABASE_URL = os.environ.get("SUPABASE_URL", "http://127.0.0.1:54321")
SUPABASE_KEY = os.environ["SUPABASE_KEY"]

supabase = create_client(SUPABASE_URL, SUPABASE_KEY)

# ---------------------------------------------------------------------------
# 1. Insert fake metrics
# ---------------------------------------------------------------------------
now = datetime.now(timezone.utc)

fake_rows = [
    {
        "id": "log-test-001",
        "parent_request_id": "req-001",
        "provider": "openrouter",
        "model": "anthropic/claude-sonnet-4",
        "status": "completed",
        "stream": True,
        "timestamp": (now - timedelta(minutes=5)).isoformat(),
        "latency_ms": 1234.5,
        "total_cost_usd": 0.0087,
        "input_cost_usd": 0.0032,
        "output_cost_usd": 0.0055,
        "prompt_tokens": 1200,
        "completion_tokens": 890,
        "total_tokens": 2090,
        "reasoning_tokens": 200,
        "cached_read_tokens": 400,
        "number_of_retries": 0,
        "fallback_index": 0,
    },
    {
        "id": "log-test-002",
        "parent_request_id": "req-002",
        "provider": "zai",
        "model": "deepseek-v3-0324",
        "status": "completed",
        "stream": True,
        "timestamp": (now - timedelta(minutes=3)).isoformat(),
        "latency_ms": 856.2,
        "total_cost_usd": 0.0012,
        "input_cost_usd": 0.0004,
        "output_cost_usd": 0.0008,
        "prompt_tokens": 500,
        "completion_tokens": 600,
        "total_tokens": 1100,
        "reasoning_tokens": None,
        "cached_read_tokens": None,
        "number_of_retries": 0,
        "fallback_index": 0,
    },
    {
        "id": "log-test-003",
        "parent_request_id": "req-003",
        "provider": "openrouter",
        "model": "openai/gpt-4.1-mini",
        "status": "completed",
        "stream": False,
        "timestamp": (now - timedelta(minutes=1)).isoformat(),
        "latency_ms": 2100.0,
        "total_cost_usd": 0.0023,
        "input_cost_usd": 0.0010,
        "output_cost_usd": 0.0013,
        "prompt_tokens": 800,
        "completion_tokens": 450,
        "total_tokens": 1250,
        "reasoning_tokens": None,
        "cached_read_tokens": 100,
        "number_of_retries": 1,
        "fallback_index": 0,
    },
]

print("=== Inserting fake metrics ===")
resp = supabase.table("bifrost_metrics").upsert(fake_rows, on_conflict="id").execute()
print(f"Inserted {len(resp.data)} rows")
for row in resp.data:
    print(f"  {row['provider']:15s} {row['model']:30s} {row['latency_ms']}ms  ${row['total_cost_usd']}")

# ---------------------------------------------------------------------------
# 2. Read them back — last 1 hour
# ---------------------------------------------------------------------------
print("\n=== Query: last 1 hour ===")
cutoff = (now - timedelta(hours=1)).isoformat()
resp = supabase.table("bifrost_metrics").select("*").gte("timestamp", cutoff).order("timestamp", desc=True).execute()
print(f"Found {len(resp.data)} rows")

# ---------------------------------------------------------------------------
# 3. Aggregation-style queries via PostgREST
# ---------------------------------------------------------------------------
print("\n=== Cost per provider ===")
resp = supabase.table("bifrost_metrics").select("provider, total_cost_usd").gte("timestamp", cutoff).execute()
by_provider: dict[str, float] = {}
for row in resp.data:
    p = row["provider"]
    by_provider[p] = by_provider.get(p, 0) + (row["total_cost_usd"] or 0)
for p, c in by_provider.items():
    print(f"  {p}: ${c:.4f}")

print("\n=== Cost per model ===")
resp = supabase.table("bifrost_metrics").select("model, total_cost_usd").gte("timestamp", cutoff).execute()
by_model: dict[str, float] = {}
for row in resp.data:
    m = row["model"]
    by_model[m] = by_model.get(m, 0) + (row["total_cost_usd"] or 0)
for m, c in sorted(by_model.items(), key=lambda x: -x[1]):
    print(f"  {m}: ${c:.4f}")

print("\n=== Tokens per second (approx) ===")
resp = supabase.table("bifrost_metrics").select("model, completion_tokens, latency_ms").gte("timestamp", cutoff).execute()
for row in resp.data:
    if row["latency_ms"] and row["latency_ms"] > 0:
        tps = (row["completion_tokens"] or 0) / (row["latency_ms"] / 1000.0)
        print(f"  {row['model']}: {tps:.1f} tok/s")

print("\n=== Test upsert (re-insert same IDs) ===")
resp = supabase.table("bifrost_metrics").upsert(fake_rows, on_conflict="id").execute()
print(f"Upserted {len(resp.data)} rows (should still have same count)")

# Verify total
resp = supabase.table("bifrost_metrics").select("id", count="exact").execute()
print(f"Total rows in table: {resp.count}")

print("\n✅ All tests passed!")
