DROP TABLE installation_repositories;

CREATE TABLE installation_repositories (
    installation_id INTEGER NOT NULL REFERENCES installations(installation_id) ON DELETE CASCADE,
    repository_id INTEGER NOT NULL,
    repository_node_id TEXT NOT NULL,
    name_with_owner TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    PRIMARY KEY (installation_id, repository_id),
    UNIQUE (installation_id, repository_node_id)
);
