import { Env, ROLE_TIER_MAP, TierValue, TIER } from './types';

// Discord role id -> name for the guild (fetched once per sync).
async function fetchGuildRoleMap(env: Env): Promise<Map<string, string>> {
  const res = await fetch(`https://discord.com/api/v10/guilds/${env.DISCORD_GUILD_ID}/roles`, {
    headers: { Authorization: `Bot ${env.DISCORD_BOT_TOKEN}` },
  });
  if (!res.ok) return new Map();
  const roles = await res.json() as Array<{ id: string; name: string }>;
  return new Map(roles.map(r => [r.id, r.name]));
}

// A member's CURRENT tier from their live Discord roles.
//   null  = transient error (couldn't tell) -> caller keeps the existing tier
//   Free  = member genuinely has no ranked role, or has left the guild (404)
async function memberTier(env: Env, discordId: string, roleMap: Map<string, string>): Promise<TierValue | null> {
  const res = await fetch(`https://discord.com/api/v10/guilds/${env.DISCORD_GUILD_ID}/members/${discordId}`, {
    headers: { Authorization: `Bot ${env.DISCORD_BOT_TOKEN}` },
  });
  if (res.status === 404) return TIER.Free;      // left the guild -> no rank
  if (!res.ok) return null;                       // rate limited / down -> don't touch
  const member = await res.json() as { roles?: string[] };
  let highest: TierValue = TIER.Free;
  for (const id of member.roles ?? []) {
    const name = roleMap.get(id);
    if (name && ROLE_TIER_MAP[name] !== undefined && ROLE_TIER_MAP[name] > highest) {
      highest = ROLE_TIER_MAP[name];
    }
  }
  return highest;
}

// Live tier for a single user (fetches its own role map). Used by /check so an
// injecting user always loads with their CURRENT rank, without waiting for the
// 5-minute cron. Returns null on a transient failure (caller keeps existing).
export async function resolveDiscordTier(env: Env, discordId: string): Promise<TierValue | null> {
  const roleMap = await fetchGuildRoleMap(env);
  if (roleMap.size === 0) return null;
  return memberTier(env, discordId, roleMap);
}

// Re-resolve every whitelisted user's tier from their live Discord roles and
// write back any changes. This is what keeps an in-game rank from getting stuck
// after a Discord role is removed. Safe under Discord outages: if the role list
// can't be fetched we abort, and per-member transient errors keep the old tier
// (we only ever drop someone to Free on a definitive 404 / no ranked role).
export async function resyncAllTiers(env: Env): Promise<void> {
  const rows = await env.DB.prepare('SELECT discord_id, tier FROM whitelist')
    .all<{ discord_id: string; tier: number }>();
  if (!rows.results.length) return;

  const roleMap = await fetchGuildRoleMap(env);
  if (roleMap.size === 0) return; // couldn't read roles -> never mass-wipe tiers

  for (const row of rows.results) {
    const t = await memberTier(env, row.discord_id, roleMap);
    if (t === null || t === row.tier) continue;
    await env.DB.prepare('UPDATE whitelist SET tier = ?, updated_at = ? WHERE discord_id = ?')
      .bind(t, Date.now(), row.discord_id).run();
  }
}
