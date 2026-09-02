ALTER TABLE setup_sessions
    ADD COLUMN purpose TEXT NOT NULL DEFAULT 'INITIAL';

ALTER TABLE setup_sessions
    ADD COLUMN automation_id TEXT REFERENCES project_automations(id) ON DELETE CASCADE;

CREATE INDEX setup_sessions_automation_id ON setup_sessions(automation_id);
