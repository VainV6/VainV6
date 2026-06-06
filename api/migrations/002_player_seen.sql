CREATE TABLE IF NOT EXISTS player_seen (
    username   TEXT    PRIMARY KEY,
    last_seen  INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_player_seen_ts ON player_seen(last_seen DESC);
