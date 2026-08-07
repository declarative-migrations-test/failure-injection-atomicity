CREATE SCHEMA app;

CREATE TABLE app.users (
    id text PRIMARY KEY,
    handle text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT current_timestamp
);
