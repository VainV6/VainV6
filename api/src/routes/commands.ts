import { Env, COMMANDS } from '../types';
import { getByRoblox, peekCommand, deleteCommand, queueCommand } from '../db/queries';

// GET /commands/poll?username=X
// Long-polls: holds open up to 25s, returns the instant a command is queued for
// this user. The client reconnects immediately after each response.
export async function handleLongPoll(request: Request, env: Env): Promise<Response> {
  const url      = new URL(request.url);
  const username = url.searchParams.get('username') ?? '';
  const secret   = request.headers.get('x-vain-secret') ?? '';

  if (!username) return jsonErr('Missing username', 400);
  if (secret !== env.BOT_SECRET) return jsonErr('Unauthorized', 401);

  const POLL_MS    = 500;   // check the queue every 500ms
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

  // No command arrived — return empty so the client reconnects
  return json({ command: null });
}

// POST /commands/queue — enqueue a command from an in-game ;<command> <target>.
// The sender must be whitelisted (resolved by Roblox username) and may only
// target a user ranked STRICTLY LOWER than themselves.
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
  if (!senderRow || senderRow.tier < 1) return jsonErr('You must be whitelisted to use commands', 403);

  // Target tier defaults to 0 (Free) when not in the DB — any rank can be
  // commanded as long as it is strictly below the sender's rank.
  const targetRow = await getByRoblox(env.DB, target);
  const targetTier = targetRow?.tier ?? 0;
  if (targetTier >= senderRow.tier) return jsonErr('You can only command players ranked below you', 403);

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
