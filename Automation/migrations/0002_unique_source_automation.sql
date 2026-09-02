CREATE UNIQUE INDEX project_automations_unique_source
    ON project_automations(installation_id, repository_id);
