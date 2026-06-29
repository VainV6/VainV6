import { Env } from '../types';
import { getByRoblox, getByRobloxUserId, upsertPresence, getPresenceInJob } from '../db/queries';

// POST /presence  body: { username, userid?, jobId }
// Announces that this Vain client is currently injected in server <jobId>, and
// returns everyone else injected in the same server (with their tier) so the
// client can show who's around. Secret-gated; tier is resolved server-side from
// the whitelist DB (Free users default to 0), so the reported rank is accurate.
export async function handlePresence(request: Request, env: Env): Promise<Response> {
  if (request.headers.get('x-vain-secret') !== env.BOT_SECRET) return jsonErr('Unauthorized', 401);

  let body: { username?: string; userid?: string; jobId?: string };
  try { body = await request.json() as typeof body; }
  catch { return jsonErr('Invalid JSON', 400); }

  const username = (body.username ?? '').trim();
  const jobId    = (body.jobId ?? '').trim();
  if (!username) return jsonErr('Missing username', 400);

  // Accurate tier: prefer the stable userId, fall back to username.
  let row = body.userid ? await getByRobloxUserId(env.DB, body.userid) : null;
  if (!row) row = await getByRoblox(env.DB, username);
  const tier = row?.tier ?? 0;

  await upsertPresence(env.DB, username, tier, jobId);
  const users = await getPresenceInJob(env.DB, jobId, username);
  return json({ users });
}

function json(data: unknown): Response {
  return new Response(JSON.stringify(data), { headers: { 'Content-Type': 'application/json' } });
}
function jsonErr(msg: string, status: number): Response {
  return new Response(JSON.stringify({ error: msg }), { status, headers: { 'Content-Type': 'application/json' } });
}
