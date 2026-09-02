CREATE TABLE setup_sessions (
    id TEXT PRIMARY KEY,
    setup_token_hash TEXT NOT NULL UNIQUE,
    oauth_state_hash TEXT UNIQUE,
    user_id TEXT REFERENCES users(id) ON DELETE CASCADE,
    oauth_credential_id TEXT REFERENCES oauth_credentials(id) ON DELETE CASCADE,
    installation_id INTEGER REFERENCES installations(installation_id) ON DELETE CASCADE,
    exchange_code_hash TEXT UNIQUE,
    state TEXT NOT NULL,
    expires_at TEXT NOT NULL,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE TABLE management_tokens (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    token_hash TEXT NOT NULL UNIQUE,
    created_at TEXT NOT NULL,
    last_used_at TEXT,
    revoked_at TEXT
);

CREATE INDEX setup_sessions_expires_at ON setup_sessions(expires_at);
CREATE INDEX management_tokens_user_id ON management_tokens(user_id);
