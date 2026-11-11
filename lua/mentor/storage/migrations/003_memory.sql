-- Persistent memory and user control. Entries live in global or project
-- scope and carry optimistic-concurrency revisions; every change appends a
-- full snapshot to memory_revision (the inspectable history that powers
-- revert). Normal deletion keeps a tombstone so automatic recreation stays
-- suppressed; permanent erasure removes content everywhere and leaves only
-- a content-free memory_audit marker. chat_message gains the tool name so
-- persisted tool results can be re-authorized by kind before retransmission.
CREATE TABLE memory_entry (
    id INTEGER PRIMARY KEY,
    scope TEXT NOT NULL CHECK (scope IN ('global', 'project')),
    project_id INTEGER REFERENCES project(id) ON DELETE CASCADE, -- NULL for global
    entry_key TEXT NOT NULL,     -- stable slug: recreation suppression, consolidation
    category TEXT NOT NULL,
    summary TEXT NOT NULL,
    content TEXT NOT NULL DEFAULT '',
    uncertainty TEXT NOT NULL CHECK (uncertainty IN ('established', 'hypothesis')),
    refs TEXT,                   -- JSON array: paths and concepts (provenance)
    status TEXT NOT NULL CHECK (status IN ('active', 'deleted')),
    protected INTEGER NOT NULL DEFAULT 0, -- user edits win until the user releases
    revision INTEGER NOT NULL DEFAULT 1,
    author TEXT NOT NULL,        -- last change: 'user' | 'agent'
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
);
CREATE INDEX memory_entry_scope ON memory_entry (scope, project_id, status);
-- Uniqueness of (scope, project_id, entry_key) is enforced in the memory
-- repository: project_id is NULL for global rows, and SQL UNIQUE treats
-- NULLs as distinct.

CREATE TABLE memory_revision (
    id INTEGER PRIMARY KEY,
    entry_id INTEGER NOT NULL REFERENCES memory_entry(id) ON DELETE CASCADE,
    revision INTEGER NOT NULL,
    category TEXT NOT NULL,
    summary TEXT NOT NULL,
    content TEXT NOT NULL DEFAULT '',
    uncertainty TEXT NOT NULL CHECK (uncertainty IN ('established', 'hypothesis')),
    refs TEXT,
    author TEXT NOT NULL,
    reason TEXT,                 -- why the change happened, when given
    created_at INTEGER NOT NULL
);
CREATE INDEX memory_revision_entry ON memory_revision (entry_id, revision);

CREATE TABLE memory_audit (
    id INTEGER PRIMARY KEY,
    entry_id INTEGER NOT NULL,   -- historical reference; survives erasure
    scope TEXT NOT NULL,
    project_id INTEGER,
    entry_key TEXT NOT NULL,
    action TEXT NOT NULL,        -- 'erased'
    created_at INTEGER NOT NULL
);
CREATE INDEX memory_audit_entry ON memory_audit (entry_id);

ALTER TABLE chat_message ADD COLUMN tool TEXT; -- tool name on tool results
