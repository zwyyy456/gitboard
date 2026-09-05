ALTER TABLE project_automations
    ADD COLUMN review_status_policy TEXT NOT NULL DEFAULT 'USE_CONFIGURED_OPTION';
