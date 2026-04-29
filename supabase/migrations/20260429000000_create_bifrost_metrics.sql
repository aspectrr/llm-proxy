-- Bifrost metrics table for the LLM proxy metrics scraper

CREATE TABLE IF NOT EXISTS bifrost_metrics (
    id                TEXT PRIMARY KEY,
    parent_request_id TEXT,
    provider          TEXT,
    model             TEXT,
    status            TEXT,
    stream            BOOLEAN,
    timestamp         TIMESTAMPTZ,
    latency_ms        DOUBLE PRECISION,
    total_cost_usd    DOUBLE PRECISION,
    input_cost_usd    DOUBLE PRECISION,
    output_cost_usd   DOUBLE PRECISION,
    prompt_tokens     INTEGER,
    completion_tokens INTEGER,
    total_tokens      INTEGER,
    reasoning_tokens  INTEGER,
    cached_read_tokens INTEGER,
    number_of_retries INTEGER,
    fallback_index    INTEGER,
    created_at        TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_metrics_timestamp ON bifrost_metrics (timestamp DESC);
CREATE INDEX IF NOT EXISTS idx_metrics_provider  ON bifrost_metrics (provider);
CREATE INDEX IF NOT EXISTS idx_metrics_model     ON bifrost_metrics (model);

ALTER TABLE bifrost_metrics ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Allow anonymous reads"
    ON bifrost_metrics FOR SELECT
    USING (true);
