import { Env, TIER_NAME } from '../types';
import { getByRoblox, getByRobloxUserId, updateRobloxUsername, isBlacklisted } from '../db/queries';

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
