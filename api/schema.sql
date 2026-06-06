CREATE TABLE IF NOT EXISTS whitelist (
    discord_id   TEXT    PRIMARY KEY,
    roblox_username TEXT UNIQUE,
    roblox_user_id  TEXT,
    tier         INTEGER NOT NULL DEFAULT 0,
    created_at   INTEGER NOT NULL,
    updated_at   INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS blacklist (
    roblox_user_id TEXT PRIMARY KEY,
    reason         TEXT,
    created_at     INTEGER NOT NULL
);

-- C2 command queue: commands targeting a Vain user, polled and executed client-side
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

-- Key/value store for guild_id and cached role mappings
CREATE TABLE IF NOT EXISTS config (
    key        TEXT PRIMARY KEY,
    value      TEXT NOT NULL,
    updated_at INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_whitelist_roblox ON whitelist(roblox_username);
CREATE INDEX IF NOT EXISTS idx_cmd_queue_target  ON command_queue(target_roblox_username, expires_at);
