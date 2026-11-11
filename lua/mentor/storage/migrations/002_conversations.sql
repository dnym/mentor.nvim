-- Conversations and usage accounting. Coach keeps one linear conversation
-- per project; messages are stored already sanitized. Usage is accounted per
-- project, local calendar day, and operation kind; in-flight requests hold a
-- reservation first so budget checks see work that has not reported usage yet.
CREATE TABLE chat_message (
    id INTEGER PRIMARY KEY,
    project_id INTEGER NOT NULL REFERENCES project(id) ON DELETE CASCADE,
    mode TEXT NOT NULL,
    role TEXT NOT NULL CHECK (role IN ('user', 'assistant', 'tool')),
    content TEXT NOT NULL DEFAULT '',
    tool_calls TEXT,          -- JSON array, assistant messages only
    tool_call_id TEXT,        -- tool messages: the call this result answers
    source TEXT,              -- tool messages: provenance path, if any
    created_at INTEGER NOT NULL
);
CREATE INDEX chat_message_scope ON chat_message (project_id, mode, id);

CREATE TABLE usage_day (
    id INTEGER PRIMARY KEY,
    project_id INTEGER NOT NULL REFERENCES project(id) ON DELETE CASCADE,
    day TEXT NOT NULL,        -- local calendar date YYYY-MM-DD
    kind TEXT NOT NULL CHECK (kind IN ('interactive', 'background')),
    model_requests INTEGER NOT NULL DEFAULT 0,
    est_tokens INTEGER NOT NULL DEFAULT 0,
    reported_input INTEGER NOT NULL DEFAULT 0,
    reported_output INTEGER NOT NULL DEFAULT 0,
    UNIQUE (project_id, day, kind)
);

CREATE TABLE usage_reservation (
    id INTEGER PRIMARY KEY,
    project_id INTEGER NOT NULL REFERENCES project(id) ON DELETE CASCADE,
    day TEXT NOT NULL,
    kind TEXT NOT NULL CHECK (kind IN ('interactive', 'background')),
    model_requests INTEGER NOT NULL,
    est_tokens INTEGER NOT NULL,
    -- pending: not dispatched yet (expired on sweep); dispatched: work may
    -- have reached the provider, its outcome is retained conservatively.
    state TEXT NOT NULL CHECK (state IN ('pending', 'dispatched')),
    created_at INTEGER NOT NULL
);
CREATE INDEX usage_reservation_scope ON usage_reservation (project_id, day, kind);
