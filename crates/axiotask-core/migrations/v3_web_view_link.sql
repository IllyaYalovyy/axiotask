-- Schema v3. Applied when PRAGMA user_version < 3.
--
-- Google returns a `webViewLink` for every task — an absolute URL to that task
-- in the Google Tasks web app. We persist it so the UI can offer an "Open in
-- Google Tasks" action (the only place recurrence and other Google-only
-- features can be managed, since the REST API doesn't expose them).
--
-- Output-only and populated on pull; NULL for tasks not yet synced.
ALTER TABLE tasks ADD COLUMN web_view_link TEXT;
