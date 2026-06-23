import { WhitelistRow, TierValue } from '../types';

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
