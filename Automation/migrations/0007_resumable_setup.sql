ALTER TABLE setup_sessions
    ADD COLUMN management_token_id TEXT REFERENCES management_tokens(id) ON DELETE SET NULL;

CREATE INDEX setup_sessions_management_token_id
    ON setup_sessions(management_token_id);
