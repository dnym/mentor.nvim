-- Observer: automatic observation and feedback. Activation is per project
-- and bound to the Observer endpoint (changing the endpoint requires
-- enabling again; the state persists across restarts so a disabled project
-- stays disabled). Findings persist per project with an issue digest for
-- deduplication, notification timestamps for cooldowns, dismissal state, a
-- staleness marker (restored findings start stale), and a usefulness
-- rating. Per-category presentation preferences (mute, snooze) persist too.
CREATE TABLE observer_state (
    project_id INTEGER PRIMARY KEY REFERENCES project(id) ON DELETE CASCADE,
    enabled INTEGER NOT NULL DEFAULT 0,
    endpoint TEXT NOT NULL DEFAULT '', -- endpoint accepted at activation
    consolidation_day TEXT,            -- last day a scheduled pass ran
    updated_at INTEGER NOT NULL
);

CREATE TABLE observation (
    id INTEGER PRIMARY KEY,
    project_id INTEGER NOT NULL REFERENCES project(id) ON DELETE CASCADE,
    category TEXT NOT NULL CHECK (category IN ('correctness', 'design', 'learning', 'praise')),
    summary TEXT NOT NULL,
    reasoning TEXT NOT NULL DEFAULT '',
    certainty TEXT NOT NULL CHECK (certainty IN ('high', 'medium', 'low')),
    refs TEXT,                         -- JSON array of paths (policy-authorized)
    fingerprints TEXT,                 -- JSON object: path -> mtime/size/buffer marker
    question TEXT NOT NULL DEFAULT '', -- constructive next step, when given
    issue_digest TEXT NOT NULL,        -- dedup key: issue kind + location
    notified_at INTEGER,               -- last time this finding notified
    dismissed INTEGER NOT NULL DEFAULT 0,
    stale INTEGER NOT NULL DEFAULT 0,  -- restored findings start stale
    rating TEXT CHECK (rating IN ('useful', 'not-useful')),
    created_at INTEGER NOT NULL
);
CREATE INDEX observation_project ON observation (project_id, dismissed, stale);
CREATE INDEX observation_digest ON observation (project_id, issue_digest);

CREATE TABLE observation_pref (
    project_id INTEGER NOT NULL REFERENCES project(id) ON DELETE CASCADE,
    category TEXT NOT NULL,
    muted INTEGER NOT NULL DEFAULT 0,
    snooze_until INTEGER NOT NULL DEFAULT 0, -- epoch ms; 0 = not snoozed
    updated_at INTEGER NOT NULL,
    PRIMARY KEY (project_id, category)
);
