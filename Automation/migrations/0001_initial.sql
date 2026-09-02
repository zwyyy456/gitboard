PRAGMA foreign_keys = ON;

CREATE TABLE users (
    id TEXT PRIMARY KEY,
    github_user_node_id TEXT NOT NULL UNIQUE,
    github_user_database_id INTEGER NOT NULL UNIQUE,
    github_login TEXT NOT NULL,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE TABLE oauth_credentials (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    encrypted_access_token TEXT NOT NULL,
    encrypted_refresh_token TEXT NOT NULL,
    access_token_expires_at TEXT NOT NULL,
    refresh_token_expires_at TEXT NOT NULL,
    granted_scopes TEXT NOT NULL,
    credential_version INTEGER NOT NULL,
    health_state TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE TABLE installations (
    installation_id INTEGER PRIMARY KEY,
    user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    github_account_id INTEGER NOT NULL,
    status TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE TABLE installation_repositories (
    installation_id INTEGER NOT NULL REFERENCES installations(installation_id) ON DELETE CASCADE,
    repository_id INTEGER NOT NULL,
    name_with_owner TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    PRIMARY KEY (installation_id, repository_id)
);

CREATE TABLE project_automations (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    oauth_credential_id TEXT NOT NULL REFERENCES oauth_credentials(id) ON DELETE CASCADE,
    installation_id INTEGER NOT NULL REFERENCES installations(installation_id) ON DELETE CASCADE,
    repository_id INTEGER NOT NULL,
    repository_name_with_owner TEXT NOT NULL,
    project_owner_login TEXT NOT NULL,
    project_number INTEGER NOT NULL,
    project_node_id TEXT NOT NULL,
    status_field_node_id TEXT NOT NULL,
    in_progress_option_id TEXT NOT NULL,
    in_review_option_id TEXT NOT NULL,
    done_option_id TEXT NOT NULL,
    enabled INTEGER NOT NULL DEFAULT 0,
    health_state TEXT NOT NULL,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE INDEX project_automations_source_repository
    ON project_automations(installation_id, repository_id, enabled);

CREATE TABLE webhook_deliveries (
    delivery_id TEXT PRIMARY KEY,
    automation_id TEXT NOT NULL REFERENCES project_automations(id) ON DELETE CASCADE,
    event_name TEXT NOT NULL,
    event_action TEXT NOT NULL,
    processing_state TEXT NOT NULL,
    attempt_count INTEGER NOT NULL DEFAULT 0,
    error_code TEXT,
    received_at TEXT NOT NULL,
    completed_at TEXT
);

CREATE INDEX webhook_deliveries_automation_received
    ON webhook_deliveries(automation_id, received_at);
