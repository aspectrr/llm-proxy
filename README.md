# Bifrost LLM Gateway

Local Bifrost LLM gateway with Caddy HTTPS and Supabase metrics.

## Services

| Service | Description |
|---|---|
| **bifrost** | Bifrost LLM gateway (port 8080) |
| **caddy** | Reverse proxy at `gateway.localhost` with auto-HTTPS |
| **metrics-scraper** | Polls Bifrost logs → Supabase every 60s |

## Quick Start

1. Copy `.env.example` → `.env` and fill in values:
   ```sh
   cp .env.example .env
   ```

2. Start local Supabase and apply the migration:
   ```sh
   supabase start
   ```

3. Build and start the gateway stack:
   ```sh
   docker compose up -d --build
   ```

4. Use the gateway:
   - Direct: `http://localhost:8080`
   - Via Caddy: `https://gateway.localhost` (auto-HTTPS, no `/etc/hosts` needed)

## Local Development & Testing

The Supabase migration is tracked in `supabase/migrations/`. To reset and re-apply:
```sh
supabase db reset
```

Test the scraper against local Supabase:
```sh
cd metrics-scraper
uv sync
BIFROST_URL=http://localhost:8080 \
BIFROST_ADMIN_USER=cpfeifer \
BIFROST_ADMIN_PASSWORD=yourpassword \
SUPABASE_URL=http://127.0.0.1:54321 \
SUPABASE_KEY=<service_role_key_from_supabase_start> \
uv run test_scraper.py
```

## Environment Variables

| Variable | Required | Description |
|---|---|---|
| `ADMIN_PASSWORD` | ✅ | Bifrost admin + scraper auth |
| `OPENROUTER_API_KEY` | | OpenRouter provider key |
| `GLM_API_KEY` | | Z.ai provider key |
| `OLLAMA_URL` | | Ollama URL (default: `http://host.docker.internal:11434`) |
| `SUPABASE_URL` | ✅ | Your Supabase project URL |
| `SUPABASE_KEY` | ✅ | Supabase service_role key (for writes) |
| `SCRAPE_INTERVAL_SECONDS` | | Default: 60 |

## Querying Metrics from Your Website

Your website can query the `bifrost_metrics` table via the Supabase client or REST API.

### Example queries

```js
import { createClient } from '@supabase/supabase-js'
const supabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY)

// Last 1 hour of logs
const { data } = await supabase
  .from('bifrost_metrics')
  .select('*')
  .gte('timestamp', new Date(Date.now() - 3600_000).toISOString())
  .order('timestamp', { ascending: false })

// Last 3 hours
.gte('timestamp', new Date(Date.now() - 3 * 3600_000).toISOString())

// Last 5 hours
.gte('timestamp', new Date(Date.now() - 5 * 3600_000).toISOString())
```

### Useful SQL aggregations

```sql
-- Tokens per second (over last hour)
SELECT
  model,
  SUM(completion_tokens)::float / NULLIF(SUM(latency_ms) / 1000.0, 0) AS tokens_per_second
FROM bifrost_metrics
WHERE timestamp > now() - interval '1 hour'
GROUP BY model;

-- Cost per provider
SELECT provider, SUM(total_cost_usd) AS total_cost
FROM bifrost_metrics
WHERE timestamp > now() - interval '1 hour'
GROUP BY provider;

-- Cost per model
SELECT model, SUM(total_cost_usd) AS total_cost
FROM bifrost_metrics
WHERE timestamp > now() - interval '1 hour'
GROUP BY model
ORDER BY total_cost DESC;

-- Average latency per model
SELECT model, AVG(latency_ms) AS avg_latency_ms
FROM bifrost_metrics
WHERE timestamp > now() - interval '1 hour'
GROUP BY model;
```
