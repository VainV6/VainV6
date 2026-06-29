import { Env, TIER_NAME } from '../types';
import { getByRoblox, getByRobloxUserId, updateRobloxUsername, isBlacklisted, getTiersForUsernames, setCommandToken } from '../db/queries';
import { resolveDiscordTier } from '../tierSync';

// POST /tiers  body: { usernames: string[] }  ->  { tiers: { "<lowername>": tier } }
// Lets the client resolve other Vain users' tiers in one request so lower-tier
// users can't target higher-tier ones in game.
export async function handleTiers(request: Request, env: Env): Promise<Response> {
  if (request.headers.get('x-vain-secret') !== env.BOT_SECRET) return jsonErr('Unauthorized', 401);

  const body = await request.json().catch(() => null) as { usernames?: unknown } | null;
  const list = Array.isArray(body?.usernames)
    ? (body!.usernames as unknown[]).filter((u): u is string => typeof u === 'string')
    : [];

  const tiers = await getTiersForUsernames(env.DB, list);
  return json({ tiers });
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

  // Live rank: re-resolve from the user's CURRENT Discord roles every load, so
  // removing a role drops their rank immediately (not just after the 5m cron).
  const live = await resolveDiscordTier(env, row.discord_id);
  if (live !== null && live !== row.tier) {
    await env.DB.prepare('UPDATE whitelist SET tier = ?, updated_at = ? WHERE discord_id = ?')
      .bind(live, Date.now(), row.discord_id).run();
    row.tier = live;
  }

  // Hand the user their own command token so in-game commands work automatically
  // (no manual setup). Only over a valid secret, and only auto-provision for
  // whitelisted (tier >= 1) users. A Free user has nobody to command anyway.
  let command_token: string | undefined;
  const authed = request.headers.get('x-vain-secret') === env.BOT_SECRET;
  if (authed && row.tier >= 1) {
    command_token = row.command_token ?? undefined;
    if (!command_token) {
      command_token = crypto.randomUUID().replace(/-/g, '');
      await setCommandToken(env.DB, row.discord_id, command_token);
    }
  }

  return json({ blacklisted: false, tier: row.tier, tier_name: TIER_NAME[row.tier], command_token });
}

function json(data: unknown): Response {
  return new Response(JSON.stringify(data), { headers: { 'Content-Type': 'application/json' } });
}

function jsonErr(msg: string, status: number): Response {
  return new Response(JSON.stringify({ error: msg }), { status, headers: { 'Content-Type': 'application/json' } });
}
