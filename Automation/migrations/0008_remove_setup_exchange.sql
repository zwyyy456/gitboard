CREATE TABLE setup_sessions_v2 (
    id TEXT PRIMARY KEY,
    setup_token_hash TEXT NOT NULL UNIQUE,
    oauth_state_hash TEXT UNIQUE,
    user_id TEXT REFERENCES users(id) ON DELETE CASCADE,
    oauth_credential_id TEXT REFERENCES oauth_credentials(id) ON DELETE CASCADE,
    installation_id INTEGER REFERENCES installations(installation_id) ON DELETE CASCADE,
    state TEXT NOT NULL,
    expires_at TEXT NOT NULL,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    purpose TEXT NOT NULL DEFAULT 'INITIAL',
    automation_id TEXT REFERENCES project_automations(id) ON DELETE CASCADE,
    management_token_id TEXT REFERENCES management_tokens(id) ON DELETE SET NULL
);

INSERT INTO setup_sessions_v2 (
    id, setup_token_hash, oauth_state_hash, user_id, oauth_credential_id,
    installation_id, state, expires_at, created_at, updated_at, purpose,
    automation_id, management_token_id
)
SELECT id, setup_token_hash, oauth_state_hash, user_id, oauth_credential_id,
       installation_id, state, expires_at, created_at, updated_at, purpose,
       automation_id, management_token_id
FROM setup_sessions;

DROP TABLE setup_sessions;
ALTER TABLE setup_sessions_v2 RENAME TO setup_sessions;

CREATE INDEX setup_sessions_expires_at ON setup_sessions(expires_at);
CREATE INDEX setup_sessions_automation_id ON setup_sessions(automation_id);
CREATE INDEX setup_sessions_management_token_id ON setup_sessions(management_token_id);
