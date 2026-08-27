#!/usr/bin/env bash
# add-model-pricing.sh — fill missing pricing/context for a model the gateway
# serves with nulls.
#
# Why: Bifrost syncs governance_model_pricing from getbifrost.ai/datasheet,
# which lags new zai/GLM models by weeks. Until then /v1/models returns null
# pricing + null context, and pi shows no session cost. models.dev has the
# data same-day, so we pull from there and insert the row by hand.
#
# Usage (from the deploy dir, e.g. ~/GitHub/llm-proxy — needs real .env):
#   ./add-model-pricing.sh glm-5.3-flash          # provider defaults to zai
#   ./add-model-pricing.sh <model> <provider>
#
# Idempotent (INSERT OR REPLACE). Brief gateway downtime (~30s) while the
# sqlite edit happens — the container has no sqlite3, so the DB is copied
# out, edited, copied back.
#
# ponytail: hand rows survive Bifrost's 24h datasheet sync (it upserts,
# never deletes), so this is safe to leave in place. When the datasheet
# eventually catches up, its upsert just overwrites our row with identical
# values. If a model needs tiered/above-128k pricing someday, extend the
# INSERT with the *_above_* columns.

set -euo pipefail
cd "$(dirname "$0")"

MODEL="${1:?usage: $0 <model> [provider]}"
PROVIDER="${2:-zai}"
CONTAINER="${BIFROST_CONTAINER:-bifrost}"
DB_PATH="/var/lib/bifrost/config.db"
AUTH="Authorization: Bearer $(sed -n 's/^ADMIN_PASSWORD=//p' .env | head -1)"

fail() { echo "FAILED: $*" >&2; exit 1; }
command -v jq >/dev/null || fail "jq required"
command -v sqlite3 >/dev/null || fail "sqlite3 required"
[ -f .env ] || fail "no .env here — run from the deploy dir (~/GitHub/llm-proxy), not a worktree"

# --- 1. Fetch pricing from models.dev ($/M → per-token in awk/jq) ---
META=$(curl -sS -m 30 "https://models.dev/api.json") || fail "models.dev unreachable"
ENTRY=$(jq -e --arg p "$PROVIDER" --arg m "$MODEL" '.[$p].models[$m]' <<<"$META") \
	|| fail "models.dev has no $PROVIDER/$MODEL (not public yet?)"

CTX=$(jq -r '.limit.context // 0' <<<"$ENTRY")
MAX_OUT=$(jq -r '.limit.output // 0' <<<"$ENTRY")
IN=$(jq -r '.cost.input // 0' <<<"$ENTRY")
OUT=$(jq -r '.cost.output // 0' <<<"$ENTRY")
CACHE_READ=$(jq -r '.cost.cache_read // 0' <<<"$ENTRY")
[ "$CTX" != "0" ] || fail "models.dev entry has no context limit — needs manual values"
echo "==> $PROVIDER/$MODEL: ctx=$CTX out=$MAX_OUT in=\$$IN/M out=\$$OUT/M cache_read=\$$CACHE_READ/M"

# --- 2. Stop gateway, edit config.db, restart ---
echo "==> Stopping $CONTAINER (brief downtime)"
TMP=$(mktemp -d)
# always restart the gateway on exit, even if a step below fails
trap 'docker start "$CONTAINER" >/dev/null 2>&1 || true; rm -rf "$TMP"' EXIT
docker stop "$CONTAINER" >/dev/null

# copy the db WITH its wal/shm — editing a main db without them can yield
# 'malformed' or lose recent writes; local sqlite checkpoints on close
docker cp "$CONTAINER:$DB_PATH" "$TMP/config.db" || fail "could not copy config.db"
docker cp "$CONTAINER:$DB_PATH-wal" "$TMP/config.db-wal" 2>/dev/null || true
docker cp "$CONTAINER:$DB_PATH-shm" "$TMP/config.db-shm" 2>/dev/null || true

sqlite3 "$TMP/config.db" "INSERT OR REPLACE INTO governance_model_pricing
	(model, provider, mode, context_length, max_input_tokens, max_output_tokens,
	 input_cost_per_token, output_cost_per_token, cache_read_input_token_cost, is_deprecated)
	VALUES ('$MODEL', '$PROVIDER', 'chat', $CTX, $CTX, $MAX_OUT,
		$(jq -n --argjson v "$IN" '$v/1000000'), $(jq -n --argjson v "$OUT" '$v/1000000'),
		$(jq -n --argjson v "$CACHE_READ" '$v/1000000'), 0);" \
	|| fail "sqlite insert failed"

# copy the checkpointed main db back; the container's stale wal/shm are
# left in place — sqlite ignores a wal whose salts don't match the new main
# db (docker exec can't run on a stopped container to delete them)
docker cp "$TMP/config.db" "$CONTAINER:$DB_PATH" || fail "could not copy config.db back"
docker start "$CONTAINER" >/dev/null

# --- 3. Verify /v1/models now serves it ---
# 240s: start.sh gates on Redis LOAD and logs.db is huge — observed 72s+
deadline=$(( $(date +%s) + 240 ))
until curl -sS -f -m 5 -o /dev/null http://gateway.localhost/v1/models -H "$AUTH" 2>/dev/null; do
	[ "$(date +%s)" -ge "$deadline" ] && fail "gateway never came back"
	sleep 2
done
curl -sS http://gateway.localhost/v1/models -H "$AUTH" \
	| jq -e --arg id "$PROVIDER/$MODEL" '.data[] | select(.id==$id) | .context_length != null and .pricing != null' >/dev/null \
	|| fail "/v1/models still shows nulls for $PROVIDER/$MODEL"
echo "✓ $PROVIDER/$MODEL serving pricing + context"

# --- 4. Recost past logs that recorded $0/null ---
curl -sS -X POST http://gateway.localhost/api/logs/recalculate-cost -H "$AUTH" \
	-H 'Content-Type: application/json' -d '{}' | jq -r '"✓ log recalc queued (\(.total) logs)"'
