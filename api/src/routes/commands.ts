import { Env, COMMANDS } from '../types';
import { getByRoblox, getByCommandToken, peekCommand, deleteCommand, queueCommand, getPresenceInJob } from '../db/queries';

// GET /commands/poll?token=XXX
// Long-polls: holds open up to 25s, returns the instant a command is queued for
// the token's owner. The token (not a spoofable username) identifies the poller,
// so nobody can intercept another user's commands.
export async function handleLongPoll(request: Request, env: Env): Promise<Response> {
  const url   = new URL(request.url);
  const token = url.searchParams.get('token') ?? '';
  if (!token) return jsonErr('Missing token', 400);

  const me = await getByCommandToken(env.DB, token);
  if (!me || !me.roblox_username) return jsonErr('Invalid token', 403);

  const POLL_MS    = 500;   // check the queue every 500ms
  const TIMEOUT_MS = 25000; // give up after 25s, client reconnects
  const deadline   = Date.now() + TIMEOUT_MS;

  while (Date.now() < deadline) {
    const cmd = await peekCommand(env.DB, me.roblox_username);
    if (cmd) {
      await deleteCommand(env.DB, cmd.id);
      return json({ command: cmd.command, args: cmd.args ?? null });
    }
    await sleep(POLL_MS);
  }

  // No command arrived — return empty so the client reconnects
  return json({ command: null });
}

// POST /commands/queue  body: { token, target, command, args? }
// The SENDER is resolved from their per-user token (unspoofable) -- there is no
// client-supplied `from` to forge. A sender may only target a user ranked
// STRICTLY BELOW themselves.
export async function handleQueue(request: Request, env: Env): Promise<Response> {
  let body: { token?: string; target?: string; command?: string; args?: string; jobId?: string };
  try { body = await request.json() as typeof body; }
  catch { return jsonErr('Invalid JSON', 400); }

  const { token, target, command, args } = body;
  if (!token || !target || !command) return jsonErr('Missing fields', 400);
  if (!(COMMANDS as readonly string[]).includes(command)) return jsonErr('Unknown command', 400);

  // Identity comes from the token, NOT a client-asserted username.
  const senderRow = await getByCommandToken(env.DB, token);
  if (!senderRow || !senderRow.roblox_username) return jsonErr('Invalid token', 403);
  if (senderRow.tier < 1) return jsonErr('You must be whitelisted to use commands', 403);

  // target "all": fan the command out to every Vain user currently injected in
  // YOUR server (same jobId) who is ranked strictly below you. Only injected
  // users can receive a command anyway, so this is the full set it can hit.
  if (target.toLowerCase() === 'all') {
    const jobId = (body.jobId ?? '').trim();
    const peers = await getPresenceInJob(env.DB, jobId, senderRow.roblox_username);
    let count = 0;
    for (const p of peers) {
      if (p.tier < senderRow.tier) {
        await queueCommand(
          env.DB, crypto.randomUUID(), senderRow.discord_id,
          senderRow.roblox_username, p.username, command, args ?? null,
        );
        count++;
      }
    }
    return json({ ok: true, count });
  }

  // Single target: tier defaults to 0 (Free) when not in the DB — any rank can
  // be commanded as long as it is strictly below the sender's rank.
  const targetRow = await getByRoblox(env.DB, target);
  const targetTier = targetRow?.tier ?? 0;
  if (targetTier >= senderRow.tier) return jsonErr('You can only command players ranked below you', 403);

  await queueCommand(
    env.DB, crypto.randomUUID(), senderRow.discord_id,
    senderRow.roblox_username, target, command, args ?? null,
  );
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
