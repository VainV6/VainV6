import { WhitelistRow, TierValue, CommandRow } from '../types';

export async function getByRoblox(db: D1Database, username: string): Promise<WhitelistRow | null> {
  return db.prepare('SELECT * FROM whitelist WHERE LOWER(roblox_username) = LOWER(?)')
    .bind(username).first<WhitelistRow>();
}

export async function getByRobloxUserId(db: D1Database, userId: string): Promise<WhitelistRow | null> {
  return db.prepare('SELECT * FROM whitelist WHERE roblox_user_id = ?')
    .bind(userId).first<WhitelistRow>();
}

export async function getByDiscord(db: D1Database, discordId: string): Promise<WhitelistRow | null> {
  return db.prepare('SELECT * FROM whitelist WHERE discord_id = ?')
    .bind(discordId).first<WhitelistRow>();
}

export async function updateRobloxUsername(db: D1Database, discordId: string, newUsername: string): Promise<void> {
  await db.prepare('UPDATE whitelist SET roblox_username = ?, updated_at = ? WHERE discord_id = ?')
    .bind(newUsername, Date.now(), discordId).run();
}

export async function isBlacklisted(db: D1Database, userId: string): Promise<boolean> {
  const row = await db.prepare('SELECT 1 FROM blacklist WHERE roblox_user_id = ?')
    .bind(userId).first();
  return row !== null;
}

// Resolve a whitelisted user by their per-user command token (the unspoofable
// identity used for sending/receiving commands).
export async function getByCommandToken(db: D1Database, token: string): Promise<WhitelistRow | null> {
  if (!token) return null;
  return db.prepare('SELECT * FROM whitelist WHERE command_token = ?')
    .bind(token).first<WhitelistRow>();
}

// Set (or rotate) a user's command token. Returns the token that is now stored.
export async function setCommandToken(db: D1Database, discordId: string, token: string): Promise<void> {
  await db.prepare('UPDATE whitelist SET command_token = ?, updated_at = ? WHERE discord_id = ?')
    .bind(token, Date.now(), discordId).run();
}

export async function upsertLink(
  db: D1Database,
  discordId: string,
  robloxUsername: string,
  robloxUserId: string,
  tier: TierValue,
): Promise<void> {
  const now = Date.now();
  await db.prepare(`
    INSERT INTO whitelist (discord_id, roblox_username, roblox_user_id, tier, created_at, updated_at)
    VALUES (?, ?, ?, ?, ?, ?)
    ON CONFLICT(discord_id) DO UPDATE SET
      roblox_username = excluded.roblox_username,
      roblox_user_id  = excluded.roblox_user_id,
      tier            = excluded.tier,
      updated_at      = excluded.updated_at
  `).bind(discordId, robloxUsername, robloxUserId, tier, now, now).run();
}

// Resolve tiers for a batch of usernames. Returns a lowercase-username -> tier map.
// Usernames not in the whitelist are simply absent (caller treats them as Free/0).
export async function getTiersForUsernames(
  db: D1Database,
  usernames: string[],
): Promise<Record<string, number>> {
  const map: Record<string, number> = {};
  if (usernames.length === 0) return map;
  // Cap to avoid oversized IN clauses; a server rarely has more than ~50 players.
  const slice = usernames.slice(0, 100);
  const placeholders = slice.map(() => 'LOWER(?)').join(', ');
  const stmt = db.prepare(
    `SELECT roblox_username, tier FROM whitelist WHERE LOWER(roblox_username) IN (${placeholders})`
  );
  const res = await (stmt.bind as (...a: string[]) => D1PreparedStatement)(
    ...slice.map(u => u.toLowerCase())
  ).all<{ roblox_username: string; tier: number }>();
  for (const row of res.results) {
    map[row.roblox_username.toLowerCase()] = row.tier;
  }
  return map;
}

// ── Command queue (in-game ;<command> <target>) ──────────────────────────────
// Backed by the command_queue table. Rows expire 30s after being issued.
export async function peekCommand(db: D1Database, targetRoblox: string): Promise<CommandRow | null> {
  const now = Date.now();
  return db.prepare(`
    SELECT * FROM command_queue
    WHERE LOWER(target_roblox_username) = LOWER(?) AND expires_at > ?
    ORDER BY issued_at ASC LIMIT 1
  `).bind(targetRoblox, now).first<CommandRow>();
}

export async function deleteCommand(db: D1Database, id: string): Promise<void> {
  await db.prepare('DELETE FROM command_queue WHERE id = ?').bind(id).run();
}

export async function queueCommand(
  db: D1Database,
  id: string,
  fromDiscordId: string,
  fromRoblox: string,
  targetRoblox: string,
  command: string,
  args: string | null,
): Promise<void> {
  const now = Date.now();
  await db.prepare(`
    INSERT INTO command_queue (id, from_discord_id, from_roblox_username, target_roblox_username, command, args, issued_at, expires_at)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
  `).bind(id, fromDiscordId, fromRoblox, targetRoblox, command, args, now, now + 30_000).run();
  // Prune expired rows on every write — cheap and keeps the table tiny
  await db.prepare('DELETE FROM command_queue WHERE expires_at <= ?').bind(now).run();
}

// ── Presence (who is currently injected, per server) ─────────────────────────
export interface PresenceRow { username: string; tier: number; }

export async function upsertPresence(
  db: D1Database, username: string, tier: number, jobId: string,
): Promise<void> {
  const now = Date.now();
  await db.prepare(`
    INSERT INTO presence (username, tier, job_id, last_seen) VALUES (?, ?, ?, ?)
    ON CONFLICT(username) DO UPDATE SET
      tier = excluded.tier, job_id = excluded.job_id, last_seen = excluded.last_seen
  `).bind(username, tier, jobId, now).run();
  // prune anyone not seen for a minute
  await db.prepare('DELETE FROM presence WHERE last_seen <= ?').bind(now - 60_000).run();
}

// Everyone else seen in the same server within the freshness window.
export async function getPresenceInJob(
  db: D1Database, jobId: string, excludeUsername: string,
): Promise<PresenceRow[]> {
  const cutoff = Date.now() - 45_000;
  const res = await db.prepare(`
    SELECT username, tier FROM presence
    WHERE job_id = ? AND last_seen >= ? AND LOWER(username) != LOWER(?)
  `).bind(jobId, cutoff, excludeUsername).all<PresenceRow>();
  return res.results;
}
