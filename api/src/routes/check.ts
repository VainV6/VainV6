import { Env, TIER_NAME, ROLE_TIER_MAP, TierValue } from '../types';
import { getByRoblox, getByRobloxUserId, updateRobloxUsername, upsertLink, isBlacklisted } from '../db/queries';

async function fetchGuildRoles(guildId: string, botToken: string): Promise<Map<string, string>> {
  try {
    const res = await fetch(`https://discord.com/api/v10/guilds/${guildId}/roles`, {
      headers: { Authorization: `Bot ${botToken}` },
    });
    if (!res.ok) return new Map();
    const roles = await res.json() as Array<{ id: string; name: string }>;
    return new Map(roles.map(r => [r.id, r.name]));
  } catch { return new Map(); }
}

async function fetchMemberTier(guildId: string, discordId: string, botToken: string): Promise<TierValue | null> {
  try {
    const [memberRes, guildRoles] = await Promise.all([
      fetch(`https://discord.com/api/v10/guilds/${guildId}/members/${discordId}`, {
        headers: { Authorization: `Bot ${botToken}` },
      }),
      fetchGuildRoles(guildId, botToken),
    ]);
    if (!memberRes.ok) return null;
    const member = await memberRes.json() as { roles: string[] };
    let highest: TierValue = 0;
    for (const id of member.roles) {
      const name = guildRoles.get(id);
      if (name && ROLE_TIER_MAP[name] !== undefined && ROLE_TIER_MAP[name] > highest) {
        highest = ROLE_TIER_MAP[name];
      }
    }
    return highest;
  } catch { return null; }
}

export async function handleCheck(request: Request, env: Env): Promise<Response> {
  const url      = new URL(request.url);
  const username = url.searchParams.get('username') ?? '';
  const userId   = url.searchParams.get('userid') ?? '';

  if (!username && !userId) return jsonErr('Missing username', 400);

  if (userId && await isBlacklisted(env.DB, userId)) {
    return jsonData({ whitelisted: false, blacklisted: true, tier: 0, tier_name: 'Blacklisted' });
  }

  let row = username ? await getByRoblox(env.DB, username) : null;

  if (!row && userId) {
    row = await getByRobloxUserId(env.DB, userId);
    if (row && username && row.roblox_username !== username) {
      await updateRobloxUsername(env.DB, row.discord_id, username);
    }
  }

  if (!row) {
    return jsonData({ whitelisted: false, blacklisted: false, tier: 0, tier_name: 'Free' });
  }

  // Re-fetch Discord roles on every inject so tier is always current
  const liveTier = await fetchMemberTier(env.DISCORD_GUILD_ID, row.discord_id, env.DISCORD_BOT_TOKEN);
  if (liveTier !== null && liveTier !== row.tier) {
    await upsertLink(env.DB, row.discord_id, row.roblox_username ?? '', row.roblox_user_id ?? '', liveTier);
    row = { ...row, tier: liveTier };
  }

  return jsonData({
    whitelisted: true,
    blacklisted: false,
    tier: row.tier,
    tier_name: TIER_NAME[row.tier],
  });
}

function jsonData(data: unknown): Response {
  return new Response(JSON.stringify(data), { headers: { 'Content-Type': 'application/json' } });
}

function jsonErr(msg: string, status: number): Response {
  return new Response(JSON.stringify({ error: msg }), { status, headers: { 'Content-Type': 'application/json' } });
}
