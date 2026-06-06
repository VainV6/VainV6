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
  await db.prepare(
    'UPDATE whitelist SET last_seen = ? WHERE LOWER(roblox_username) = LOWER(?)'
  ).bind(Date.now(), username).run();
}

export async function getOnlinePlayers(db: D1Database, windowMs = 30_000): Promise<WhitelistRow[]> {
  const cutoff = Date.now() - windowMs;
  const res = await db.prepare(
    'SELECT * FROM whitelist WHERE last_seen >= ? ORDER BY last_seen DESC'
  ).bind(cutoff).all<WhitelistRow>();
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
