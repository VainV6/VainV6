import { Env, COMMANDS } from '../types';
import { getByRoblox, peekCommand, deleteCommand, queueCommand, touchLastSeen } from '../db/queries';

// GET /commands/poll?username=X
// Long-polls: holds open up to 25s, returns the instant a command is queued.
// Client reconnects immediately after receiving a command or timeout.
export async function handleLongPoll(request: Request, env: Env): Promise<Response> {
  const url      = new URL(request.url);
  const username = url.searchParams.get('username') ?? '';
  const secret   = request.headers.get('x-vain-secret') ?? '';

  if (!username) return jsonErr('Missing username', 400);
  if (secret !== env.BOT_SECRET) return jsonErr('Unauthorized', 401);

  // Stamp seen for every player — drives /players for all injected users
  await touchLastSeen(env.DB, username);

  const POLL_MS    = 500;   // check DB every 500ms
  const TIMEOUT_MS = 25000; // give up after 25s, client reconnects
  const deadline   = Date.now() + TIMEOUT_MS;

  while (Date.now() < deadline) {
    const cmd = await peekCommand(env.DB, username);
    if (cmd) {
      await deleteCommand(env.DB, cmd.id);
      return json({ command: cmd.command, args: cmd.args ?? null });
    }
    await sleep(POLL_MS);
  }

  // No command arrived — return empty so client reconnects
  return json({ command: null });
}

// POST /commands/queue — called by Discord bot to enqueue a command
export async function handleQueue(request: Request, env: Env): Promise<Response> {
  const secret = request.headers.get('x-vain-secret') ?? '';
  if (secret !== env.BOT_SECRET) return jsonErr('Unauthorized', 401);

  let body: { from?: string; target?: string; command?: string; args?: string };
  try { body = await request.json() as typeof body; }
  catch { return jsonErr('Invalid JSON', 400); }

  const { from, target, command, args } = body;
  if (!from || !target || !command) return jsonErr('Missing fields', 400);
  if (!(COMMANDS as readonly string[]).includes(command)) return jsonErr('Unknown command', 400);

  const senderRow = await getByRoblox(env.DB, from);
  if (!senderRow || senderRow.tier < 1) return jsonErr('Sender must be Premium', 403);

  // Target tier is 0 (Free) if not in DB — Premium can always target Free
  const targetRow = await getByRoblox(env.DB, target);
  const targetTier = targetRow?.tier ?? 0;
  if (targetTier >= senderRow.tier) return jsonErr('Cannot target equal or higher tier', 403);

  await queueCommand(env.DB, crypto.randomUUID(), senderRow.discord_id, from, target, command, args ?? null);
  return json({ ok: true });
}

function sleep(ms: number): Promise<void> {
  return new Promise(r => setTimeout(r, ms));
}

function json(data: unknown): Response {
  return new Response(JSON.stringify(data), { headers: { 'Content-Type': 'application/json' } });
}

function jsonErr(msg: string, status: number): Response {
  return new Response(JSON.stringify({ error: msg }), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });
}
