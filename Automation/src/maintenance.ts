const dayMilliseconds = 24 * 60 * 60 * 1000;

export async function runMaintenance(
    database: D1Database,
    now: Date = new Date()
): Promise<void> {
    const timestamp = now.toISOString();
    const staleDeliveryCutoff = new Date(now.getTime() - 7 * dayMilliseconds).toISOString();
    const terminalDeliveryCutoff = new Date(now.getTime() - 30 * dayMilliseconds).toISOString();
    const expiredSetupCutoff = new Date(now.getTime() - dayMilliseconds).toISOString();

    await database.batch([
        database.prepare(
            `UPDATE webhook_deliveries
             SET processing_state = 'FAILED', error_code = 'DELIVERY_STALE',
                 completed_at = ?, state_updated_at = ?
             WHERE processing_state IN ('RECEIVED', 'QUEUED', 'PROCESSING', 'RETRYING')
               AND state_updated_at < ?`
        ).bind(timestamp, timestamp, staleDeliveryCutoff),
        database.prepare(
            `DELETE FROM webhook_deliveries
             WHERE processing_state IN ('COMPLETED', 'FAILED', 'IGNORED')
               AND COALESCE(completed_at, state_updated_at) < ?`
        ).bind(terminalDeliveryCutoff),
        database.prepare(
            "DELETE FROM setup_sessions WHERE expires_at < ?"
        ).bind(expiredSetupCutoff),
        database.prepare(
            `DELETE FROM oauth_credentials
             WHERE NOT EXISTS (
                     SELECT 1 FROM project_automations
                     WHERE oauth_credential_id = oauth_credentials.id
                 )
               AND NOT EXISTS (
                     SELECT 1 FROM setup_sessions
                     WHERE oauth_credential_id = oauth_credentials.id
                 )`
        ),
        database.prepare(
            `DELETE FROM installations
             WHERE NOT EXISTS (
                     SELECT 1 FROM project_automations
                     WHERE installation_id = installations.installation_id
                 )
               AND NOT EXISTS (
                     SELECT 1 FROM setup_sessions
                     WHERE installation_id = installations.installation_id
                 )`
        ),
        database.prepare(
            `DELETE FROM users
             WHERE NOT EXISTS (
                     SELECT 1 FROM project_automations WHERE user_id = users.id
                 )
               AND NOT EXISTS (
                     SELECT 1 FROM setup_sessions WHERE user_id = users.id
                 )
               AND NOT EXISTS (
                     SELECT 1 FROM oauth_credentials WHERE user_id = users.id
                 )
               AND NOT EXISTS (
                     SELECT 1 FROM installations WHERE user_id = users.id
                 )`
        ),
    ]);
}
