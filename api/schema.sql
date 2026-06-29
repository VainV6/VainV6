CREATE TABLE IF NOT EXISTS whitelist (
    discord_id   TEXT    PRIMARY KEY,
    roblox_username TEXT UNIQUE,
    roblox_user_id  TEXT,
    tier         INTEGER NOT NULL DEFAULT 0,
    created_at   INTEGER NOT NULL,
    updated_at   INTEGER NOT NULL,
    command_token TEXT
);

CREATE TABLE IF NOT EXISTS blacklist (
    roblox_user_id TEXT PRIMARY KEY,
    reason         TEXT,
    created_at     INTEGER NOT NULL
);

-- Key/value store for guild_id and cached role mappings
CREATE TABLE IF NOT EXISTS config (
    key        TEXT PRIMARY KEY,
    value      TEXT NOT NULL,
    updated_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS global_profiles (
    id           TEXT    PRIMARY KEY,
    author_discord_id    TEXT NOT NULL,
    author_roblox_username TEXT NOT NULL,
    game_id      TEXT NOT NULL,
    name         TEXT NOT NULL,
    description  TEXT,
    data         TEXT NOT NULL,
    installs     INTEGER NOT NULL DEFAULT 0,
    created_at   INTEGER NOT NULL,
    updated_at   INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_gprofiles_game_installs ON global_profiles(game_id, installs DESC);
CREATE INDEX IF NOT EXISTS idx_gprofiles_game_created  ON global_profiles(game_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_gprofiles_author        ON global_profiles(author_roblox_username);

CREATE INDEX IF NOT EXISTS idx_whitelist_roblox ON whitelist(roblox_username);

-- In-game ;<command> <target> relay queue. Rows are short-lived (expire 30s
-- after being issued) and pruned on every write.
CREATE TABLE IF NOT EXISTS command_queue (
    id                     TEXT    PRIMARY KEY,
    from_discord_id        TEXT    NOT NULL,
    from_roblox_username   TEXT    NOT NULL,
    target_roblox_username TEXT    NOT NULL,
    command                TEXT    NOT NULL,
    args                   TEXT,
    issued_at              INTEGER NOT NULL,
    expires_at             INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_cmd_queue_target ON command_queue(target_roblox_username, expires_at);
CREATE INDEX IF NOT EXISTS idx_whitelist_token   ON whitelist(command_token);

-- Who is currently injected, per server (job_id). Rows are pruned after ~60s of
-- no heartbeat. Drives the Vain Detector ("who's running Vain in my server").
CREATE TABLE IF NOT EXISTS presence (
    username   TEXT    PRIMARY KEY,
    tier       INTEGER NOT NULL DEFAULT 0,
    job_id     TEXT,
    last_seen  INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_presence_job ON presence(job_id, last_seen);
