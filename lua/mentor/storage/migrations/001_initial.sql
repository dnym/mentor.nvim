-- Initial schema. Projects are identified by their canonical root path
-- (requirement 4.2); one identity per Git worktree. Later milestones add
-- conversations, observations, memory, and usage accounting in further
-- migrations as each milestone needs them.
CREATE TABLE project (
    id INTEGER PRIMARY KEY,
    identity TEXT NOT NULL UNIQUE,
    root TEXT NOT NULL,
    is_git INTEGER NOT NULL DEFAULT 0,
    git_common_dir TEXT,
    created_at INTEGER NOT NULL
);
