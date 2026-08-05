CREATE SCHEMA app;

CREATE TABLE app.users (
    id text PRIMARY KEY,
    handle text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT current_timestamp,
    CONSTRAINT users_handle_key UNIQUE (handle)
);

CREATE TABLE app.audit_log (
    event_id text PRIMARY KEY,
    user_id text NOT NULL REFERENCES app.users(id) ON DELETE CASCADE,
    message text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT current_timestamp
);
