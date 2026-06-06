import { Env, COMMANDS } from '../types';
import { getByRoblox, drainCommands, queueCommand, touchLastSeen } from '../db/queries';

// GET /commands?username=X — called by Vain client every 5s to drain its command queue
export async function handlePoll(request: Request, env: Env): Promise<Response> {
  const url      = new URL(request.url);
  const username = url.searchParams.get('username') ?? '';
  const secret   = request.headers.get('x-vain-secret') ?? '';

  if (!username) return jsonErr('Missing username', 400);
  if (secret !== env.BOT_SECRET) return jsonErr('Unauthorized', 401);

  // Touch last_seen only for whitelisted players (Free players are not in DB)
  const row = await getByRoblox(env.DB, username);
  if (row) await touchLastSeen(env.DB, username);

  const cmds = await drainCommands(env.DB, username);
  return json({ commands: cmds });
}

// POST /queue-command — called by Vain client to send an in-game command
export async function handleQueueCommand(request: Request, env: Env): Promise<Response> {
  const secret = request.headers.get('x-vain-secret') ?? '';
  if (secret !== env.BOT_SECRET) return jsonErr('Unauthorized', 401);

  let body: { from?: string; target?: string; command?: string; args?: string };
  try { body = await request.json() as typeof body; }
  catch { return jsonErr('Invalid JSON', 400); }

  const { from, target, command, args } = body;
  if (!from || !target || !command) return jsonErr('Missing fields', 400);
  if (!(COMMANDS as readonly string[]).includes(command)) return jsonErr('Unknown command', 400);

  const senderRow = await getByRoblox(env.DB, from);
  if (!senderRow) return jsonErr('Sender not whitelisted', 403);
  if (senderRow.tier < 1) return jsonErr('Need Premium or higher to use commands', 403);

  const targetRow = await getByRoblox(env.DB, target);
  const targetTier = targetRow?.tier ?? 0;
  if (targetTier >= senderRow.tier) return jsonErr('Cannot target equal or higher tier', 403);

  const id = crypto.randomUUID();
  await queueCommand(env.DB, id, senderRow.discord_id, from, target, command, args ?? null);
  return json({ ok: true });
}

function json(data: unknown): Response {
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
