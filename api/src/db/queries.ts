import { WhitelistRow, CommandRow, TierValue } from '../types';

export async function getByDiscordId(db: D1Database, discordId: string): Promise<WhitelistRow | null> {
  return db.prepare('SELECT * FROM whitelist WHERE discord_id = ?')
    .bind(discordId).first<WhitelistRow>();
}

export async function getByRoblox(db: D1Database, username: string): Promise<WhitelistRow | null> {
  return db.prepare('SELECT * FROM whitelist WHERE LOWER(roblox_username) = LOWER(?)')
    .bind(username).first<WhitelistRow>();
}

export async function getByRobloxUserId(db: D1Database, userId: string): Promise<WhitelistRow | null> {
  return db.prepare('SELECT * FROM whitelist WHERE roblox_user_id = ?')
    .bind(userId).first<WhitelistRow>();
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

export async function removeLink(db: D1Database, discordId: string): Promise<boolean> {
  const result = await db.prepare('DELETE FROM whitelist WHERE discord_id = ?')
    .bind(discordId).run();
  return (result.meta.changes ?? 0) > 0;
}

export async function touchLastSeen(db: D1Database, username: string): Promise<void> {
  const now = Date.now();
  // Update whitelist last_seen if they're whitelisted
  await db.prepare(
    'UPDATE whitelist SET last_seen = ? WHERE LOWER(roblox_username) = LOWER(?)'
  ).bind(now, username).run();
  // Always upsert into player_seen for /players visibility
  await db.prepare(
    'INSERT INTO player_seen (username, last_seen) VALUES (?, ?) ON CONFLICT(username) DO UPDATE SET last_seen = excluded.last_seen'
  ).bind(username, now).run();
}

export interface PlayerSeenRow { username: string; last_seen: number; }

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

export async function getOnlinePlayers(db: D1Database, windowMs = 30_000): Promise<PlayerSeenRow[]> {
  const cutoff = Date.now() - windowMs;
  const res = await db.prepare(
    'SELECT username, last_seen FROM player_seen WHERE last_seen >= ? ORDER BY last_seen DESC'
  ).bind(cutoff).all<PlayerSeenRow>();
  return res.results;
}

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
