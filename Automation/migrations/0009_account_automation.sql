CREATE TABLE account_automation_keepers (
    installation_id INTEGER PRIMARY KEY,
    automation_id TEXT NOT NULL UNIQUE
);

INSERT INTO account_automation_keepers (installation_id, automation_id)
SELECT installation_id, id
FROM project_automations candidate
WHERE NOT EXISTS (
    SELECT 1
    FROM project_automations newer
    WHERE newer.installation_id = candidate.installation_id
      AND (
          newer.updated_at > candidate.updated_at
          OR (newer.updated_at = candidate.updated_at AND newer.id > candidate.id)
      )
);

UPDATE webhook_deliveries
SET automation_id = (
    SELECT keeper.automation_id
    FROM project_automations previous
    JOIN account_automation_keepers keeper
      ON keeper.installation_id = previous.installation_id
    WHERE previous.id = webhook_deliveries.automation_id
)
WHERE automation_id IS NOT NULL;

UPDATE setup_sessions
SET automation_id = (
    SELECT keeper.automation_id
    FROM project_automations previous
    JOIN account_automation_keepers keeper
      ON keeper.installation_id = previous.installation_id
    WHERE previous.id = setup_sessions.automation_id
)
WHERE automation_id IS NOT NULL;

DELETE FROM project_automations
WHERE id NOT IN (SELECT automation_id FROM account_automation_keepers);

DROP TABLE account_automation_keepers;
DROP INDEX project_automations_source_repository;
DROP INDEX project_automations_unique_source;

ALTER TABLE project_automations DROP COLUMN repository_id;
ALTER TABLE project_automations DROP COLUMN repository_name_with_owner;

UPDATE project_automations
SET enabled = 1,
    health_state = 'CONTENT_VISIBILITY_UNVERIFIED',
    updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
WHERE health_state = 'INSTALLATION_REPOSITORY_REMOVED'
  AND EXISTS (
      SELECT 1 FROM installations
      WHERE installations.installation_id = project_automations.installation_id
        AND installations.status = 'ACTIVE'
  )
  AND EXISTS (
      SELECT 1 FROM oauth_credentials
      WHERE oauth_credentials.id = project_automations.oauth_credential_id
        AND oauth_credentials.health_state = 'ACTIVE'
  )
  AND EXISTS (
      SELECT 1 FROM installation_repositories
      WHERE installation_repositories.installation_id = project_automations.installation_id
  );

CREATE UNIQUE INDEX project_automations_unique_installation
    ON project_automations(installation_id);
