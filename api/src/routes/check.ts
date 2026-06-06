import { Env, TIER_NAME } from '../types';
import { getByRoblox, isBlacklisted } from '../db/queries';

export async function handleCheck(request: Request, env: Env): Promise<Response> {
  const url      = new URL(request.url);
  const username = url.searchParams.get('username') ?? '';
  const userId   = url.searchParams.get('userid') ?? '';

  if (!username) return jsonErr('Missing username', 400);

  if (userId && await isBlacklisted(env.DB, userId)) {
    return jsonData({ whitelisted: false, blacklisted: true, tier: 0, tier_name: 'Blacklisted' });
  }

  const row = await getByRoblox(env.DB, username);
  if (!row) {
    return jsonData({ whitelisted: false, blacklisted: false, tier: 0, tier_name: 'Free' });
  }

  return jsonData({
    whitelisted: true,
    blacklisted: false,
    tier: row.tier,
    tier_name: TIER_NAME[row.tier],
  });
}

function jsonData(data: unknown): Response {
  return new Response(JSON.stringify(data), {
    headers: { 'Content-Type': 'application/json' },
  });
}

function jsonErr(msg: string, status: number): Response {
  return new Response(JSON.stringify({ error: msg }), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });
}
