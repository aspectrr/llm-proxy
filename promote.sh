#!/usr/bin/env bash
# promote.sh — staging-first deploy for the bifrost gateway.
#
# Flow: build+boot staging (port 8081) → smoke test it → recreate prod →
#       verify prod → report. Prod keeps serving until the promote step.
#
# Usage (from the deploy dir, e.g. ~/GitHub/llm-proxy):
#   ./promote.sh              # full flow: stage, test, promote
#   ./promote.sh --stage-only # boot staging and test, never touch prod
#
# ponytail: prod recreate is stop-old/start-new (~seconds of downtime); pi
# retries transient failures. True zero-downtime needs 2 replicas + LB —
# not worth it for a local router. Rollback = git revert + ./promote.sh.

set -euo pipefail
cd "$(dirname "$0")"

STAGING_URL="http://localhost:8081/v1"
PROD_URL="http://gateway.localhost/v1"
AUTH="Authorization: Bearer $(sed -n 's/^ADMIN_PASSWORD=//p' .env | head -1)"

fail() { echo "PROMOTE FAILED: $*" >&2; exit 1; }

wait_healthy() { # url label timeout_s
	local deadline=$(( $(date +%s) + ${3:-90} ))
	until curl -sS -f -m 5 -o /dev/null "$1/models" -H "$AUTH" 2>/dev/null; do
		[ "$(date +%s)" -ge "$deadline" ] && fail "$2 never became healthy"
		sleep 3
	done
	echo "✓ $2 healthy"
}

smoke() { # base_url label
	local base="$1" label="$2" models reply
	models=$(curl -sS -m 15 "$base/models" -H "$AUTH" | grep -o '"id"' | wc -l | tr -d ' ') || fail "$label: /models unreachable"
	[ "$models" -gt 100 ] || fail "$label: only $models models listed (expected 400+)"
	reply=$(curl -sS -m 90 "$base/chat/completions" -H "$AUTH" -H "Content-Type: application/json" \
		-d '{"model":"zai/glm-5.3-flash","messages":[{"role":"user","content":"reply with exactly: ok"}],"max_tokens":500}') \
		|| fail "$label: chat completion request failed"
	echo "$reply" | grep -q '"content":"ok' || fail "$label: unexpected reply: $(echo "$reply" | head -c 300)"
	echo "✓ $label smoke passed ($models models, chat ok)"
}

echo "==> Building + booting staging (prod untouched)"
docker compose -f docker-compose.yml -f docker-compose.staging.yml up -d --build bifrost-staging
wait_healthy "$STAGING_URL" staging
smoke "$STAGING_URL" staging

[ "${1:-}" = "--stage-only" ] && { echo "Staging only — prod not touched."; exit 0; }

echo "==> Promoting: recreating prod (brief downtime)"
docker compose build bifrost
docker compose up -d bifrost
wait_healthy "$PROD_URL" prod
smoke "$PROD_URL" prod

echo "==> Done. Staging left running on :8081 (docker compose -f docker-compose.yml -f docker-compose.staging.yml down bifrost-staging to remove)."
