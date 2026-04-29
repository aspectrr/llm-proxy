# Bifrost Metrics API Reference

Everything an agent needs to query and display metrics from the Bifrost LLM proxy.

## Connection

| Param | Value |
|---|---|
| **Supabase URL** | `https://nxufrhdjyggdhwuwzpbf.supabase.co` |
| **Anon Key** | (public, safe for frontend — find in Supabase Dashboard → Settings → API) |
| **Service Role Key** | (secret, server-side only — already in `.env`) |
| **Table** | `bifrost_metrics` |

Use the **anon key** on the frontend. RLS allows anyone to read, only service_role can write.

```ts
import { createClient } from '@supabase/supabase-js'

const supabase = createClient(
  'https://nxufrhdjyggdhwuwzpbf.supabase.co',
  'ANON_KEY'
)
```

## Table Schema

```
bifrost_metrics
├── id                  TEXT        PK  (Bifrost log UUID)
├── parent_request_id   TEXT            (grouped request ID, usually null)
├── provider            TEXT            "zai" | "openrouter" | "ollama"
├── model               TEXT            e.g. "glm-4.7", "anthropic/claude-sonnet-4"
├── status              TEXT            "success" | "error"
├── stream              BOOLEAN         true | false
├── timestamp           TIMESTAMPTZ     when Bifrost processed the request
├── latency_ms          DOUBLE          end-to-end latency in milliseconds
├── total_cost_usd      DOUBLE          total cost (may be null for some providers)
├── input_cost_usd      DOUBLE          input token cost
├── output_cost_usd     DOUBLE          output token cost
├── prompt_tokens       INTEGER         tokens sent to the model
├── completion_tokens   INTEGER         tokens returned by the model
├── total_tokens        INTEGER         prompt + completion
├── reasoning_tokens    INTEGER         reasoning/thinking tokens (may be null)
├── cached_read_tokens  INTEGER         cache hits (may be null)
├── number_of_retries   INTEGER         retry count
├── fallback_index      INTEGER         which fallback was used
└── created_at          TIMESTAMPTZ     when row was inserted into Supabase
```

### Notes on nulls
- `total_cost_usd`, `input_cost_usd`, `output_cost_usd` — **null** for providers that don't report cost (Ollama, Z.ai). Only OpenRouter reliably reports costs.
- `reasoning_tokens`, `cached_read_tokens` — null when not applicable to the model.
- `model` — can be empty string `""` for non-chat requests like `list_models`.

## Query Patterns

### Time range filters

The dashboard supports 1h / 3h / 5h windows. Filter with `.gte('timestamp', ...)`:

```ts
const cutoff = new Date(Date.now() - hours * 3600_000).toISOString()

const { data } = await supabase
  .from('bifrost_metrics')
  .select('*')
  .gte('timestamp', cutoff)
  .order('timestamp', { ascending: false })
```

### REST API equivalent

```
GET /rest/v1/bifrost_metrics?select=*&order=timestamp.desc&limit=100
Header: apikey: ANON_KEY
Header: Authorization: Bearer ANON_KEY
```

Pagination via `Range` header or `offset`/`limit` params.

## Dashboard Metrics

### 1. Tokens per second (per model)

```ts
// Fetch raw, compute client-side
const { data } = await supabase
  .from('bifrost_metrics')
  .select('model, completion_tokens, latency_ms')
  .eq('status', 'success')
  .gte('timestamp', cutoff)

// Group by model
const byModel = {}
for (const row of data) {
  if (!row.latency_ms || row.latency_ms <= 0) continue
  if (!byModel[row.model]) byModel[row.model] = { tokens: 0, ms: 0 }
  byModel[row.model].tokens += row.completion_tokens || 0
  byModel[row.model].ms += row.latency_ms
}
// tok/s = total_completion_tokens / (total_latency_ms / 1000)
for (const [model, agg] of Object.entries(byModel)) {
  const tps = agg.tokens / (agg.ms / 1000)
}
```

### 2. Average latency (per model)

```ts
const { data } = await supabase
  .from('bifrost_metrics')
  .select('model, latency_ms')
  .eq('status', 'success')
  .gte('timestamp', cutoff)

// Average per model
const byModel = {}
for (const row of data) {
  if (!byModel[row.model]) byModel[row.model] = { total: 0, count: 0 }
  byModel[row.model].total += row.latency_ms || 0
  byModel[row.model].count++
}
for (const [model, agg] of Object.entries(byModel)) {
  const avgMs = agg.total / agg.count
}
```

### 3. Cost per provider

```ts
const { data } = await supabase
  .from('bifrost_metrics')
  .select('provider, total_cost_usd')
  .gte('timestamp', cutoff)

const byProvider = {}
for (const row of data) {
  if (!byProvider[row.provider]) byProvider[row.provider] = 0
  byProvider[row.provider] += row.total_cost_usd || 0
}
```

### 4. Cost per model

Same pattern, group by `model` instead of `provider`. Note: cost will be $0 or missing for providers that don't report it.

### 5. Request volume

```ts
// Total requests in window
const { count } = await supabase
  .from('bifrost_metrics')
  .select('*', { count: 'exact', head: true })
  .gte('timestamp', cutoff)

// By status
const { data } = await supabase
  .from('bifrost_metrics')
  .select('status')
  .gte('timestamp', cutoff)
// Count success vs error client-side
```

### 6. Token usage per model

```ts
const { data } = await supabase
  .from('bifrost_metrics')
  .select('model, prompt_tokens, completion_tokens, total_tokens')
  .gte('timestamp', cutoff)

// Sum per model
```

## Providers

| Provider | Models (example) | Reports Cost? |
|---|---|---|
| `zai` | `glm-4.7` | ❌ null |
| `openrouter` | `anthropic/claude-sonnet-4`, `openai/gpt-4.1-mini`, etc. | ✅ yes |
| `ollama` | (varies) | ❌ null |

## Gotchas

1. **Filter out `list_models` rows** — some rows have `model: ""` and `object: "list_models"` (not stored, but characterized by empty model + low token counts). Filter with `.neq('model', '')` if you only want chat requests.
2. **Latency is in milliseconds** — divide by 1000 for seconds.
3. **Costs are nullable** — always use `|| 0` when summing `total_cost_usd`.
4. **Dedup is handled** — the scraper upserts by `id`, so no duplicate rows.
5. **Timestamps are UTC** — `TIMESTAMPTZ`, display in user's local timezone.
6. **Max page size is 1000** — use pagination (offset/limit or Range header) for large datasets.
