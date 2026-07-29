ALTER TABLE api_keys
    ADD COLUMN IF NOT EXISTS openai_responses_stream_event_mode VARCHAR(20) NOT NULL DEFAULT 'strict';

ALTER TABLE usage_logs
    ADD COLUMN IF NOT EXISTS first_sse_event_ms INTEGER NULL;
