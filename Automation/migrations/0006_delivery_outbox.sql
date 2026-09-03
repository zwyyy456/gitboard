DROP TABLE webhook_deliveries;

CREATE TABLE webhook_deliveries (
    delivery_id TEXT PRIMARY KEY,
    automation_id TEXT REFERENCES project_automations(id) ON DELETE CASCADE,
    installation_id INTEGER NOT NULL,
    repository_id INTEGER,
    pull_request_number INTEGER,
    event_name TEXT NOT NULL,
    event_action TEXT NOT NULL,
    processing_state TEXT NOT NULL,
    attempt_count INTEGER NOT NULL DEFAULT 0,
    error_code TEXT,
    received_at TEXT NOT NULL,
    state_updated_at TEXT NOT NULL,
    completed_at TEXT
);

CREATE INDEX webhook_deliveries_automation_received
    ON webhook_deliveries(automation_id, received_at);

CREATE INDEX webhook_deliveries_state_updated
    ON webhook_deliveries(processing_state, state_updated_at);
