import { Env, TIER_NAME } from '../types';
import { getByRoblox, getByRobloxUserId, updateRobloxUsername, isBlacklisted, getTiersForUsernames, getOnlinePlayers } from '../db/queries';

// POST /tiers  body: { usernames: string[] }
//   -> { tiers: { "<lowername>": tier }, injected: ["<Username>", ...] }
// Lets the client resolve other injected Vain users' tiers in one request (to
// protect higher-tier players) AND learn which of those players are currently
// injected (seen polling within the last 60s) for the in-game player list.
export async function handleTiers(request: Request, env: Env): Promise<Response> {
  if (request.headers.get('x-vain-secret') !== env.BOT_SECRET) return jsonErr('Unauthorized', 401);

  const body = await request.json().catch(() => null) as { usernames?: unknown } | null;
  const list = Array.isArray(body?.usernames)
    ? (body!.usernames as unknown[]).filter((u): u is string => typeof u === 'string')
    : [];

  const tiers = await getTiersForUsernames(env.DB, list);

  // Which of the requested players are currently injected (recently seen polling)?
  const wanted = new Set(list.map(u => u.toLowerCase()));
  const online = await getOnlinePlayers(env.DB, 60_000);
  const injected = online.map(r => r.username).filter(u => wanted.has(u.toLowerCase()));

  return json({ tiers, injected });
}

export async function handleCheck(request: Request, env: Env): Promise<Response> {
  const url      = new URL(request.url);
  const username = url.searchParams.get('username') ?? '';
  const userId   = url.searchParams.get('userid') ?? '';

  if (!username && !userId) return jsonErr('Missing username', 400);

  if (userId && await isBlacklisted(env.DB, userId)) {
    return json({ blacklisted: true, tier: 0, tier_name: 'Blacklisted' });
  }

  let row = username ? await getByRoblox(env.DB, username) : null;

  // Fall back to userId lookup (handles username changes)
  if (!row && userId) {
    row = await getByRobloxUserId(env.DB, userId);
    if (row && username && row.roblox_username !== username) {
      await updateRobloxUsername(env.DB, row.discord_id, username);
    }
  }

  if (!row) {
    return json({ blacklisted: false, tier: 0, tier_name: 'Free' });
  }

  return json({ blacklisted: false, tier: row.tier, tier_name: TIER_NAME[row.tier] });
}

function json(data: unknown): Response {
  return new Response(JSON.stringify(data), { headers: { 'Content-Type': 'application/json' } });
}

function jsonErr(msg: string, status: number): Response {
  return new Response(JSON.stringify({ error: msg }), { status, headers: { 'Content-Type': 'application/json' } });
}
