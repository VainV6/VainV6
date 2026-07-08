import { Env } from './types';
import { verifyDiscordSignature } from './discord/verify';
import { handleCommand } from './discord/commands';
import { handleCheck, handleTiers } from './routes/check';
import { handleLongPoll, handleQueue } from './routes/commands';
import { handlePresence } from './routes/presence';
import { handleGlobalTargets } from './routes/globalTargets';
import { resyncAllTiers } from './tierSync';
import {
  handleListProfiles, handleGetProfile, handleCreateProfile, handleUpdateProfile,
  handleDeleteProfile, handleInstallProfile,
} from './routes/globalProfiles';

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url    = new URL(request.url);
    const method = request.method;
    const path   = url.pathname;

    if (method === 'OPTIONS') return new Response(null, { headers: corsHeaders() });

    if (method === 'POST' && path === '/discord') {
      const body = await request.text();
      const valid = await verifyDiscordSignature(request, env.DISCORD_PUBLIC_KEY, body);
      if (!valid) return new Response('Invalid signature', { status: 401 });
      const interaction = JSON.parse(body);
      if (interaction.type === 1) return json({ type: 1 });
      if (interaction.type === 2) return handleCommand(interaction, env);
      return new Response('Unknown interaction type', { status: 400 });
    }

    if (method === 'GET'  && path === '/check')           return withCors(await handleCheck(request, env));
    if (method === 'POST' && path === '/tiers')           return withCors(await handleTiers(request, env));
    if (method === 'GET'  && path === '/commands/poll')   return withCors(await handleLongPoll(request, env));
    if (method === 'POST' && path === '/commands/queue')  return withCors(await handleQueue(request, env));
    if (method === 'POST' && path === '/presence')        return withCors(await handlePresence(request, env));
    if (method === 'GET'  && path === '/globaltargets')   return withCors(await handleGlobalTargets(request, env));

    if (path === '/profiles') {
      if (method === 'GET')  return withCors(await handleListProfiles(request, env));
      if (method === 'POST') return withCors(await handleCreateProfile(request, env));
    }
    const profileMatch = path.match(/^\/profiles\/([^/]+)(\/install)?$/);
    if (profileMatch) {
      const id = profileMatch[1];
      if (method === 'GET' && !profileMatch[2]) return withCors(await handleGetProfile(request, env, id));
      if (method === 'PUT')    return withCors(await handleUpdateProfile(request, env, id));
      if (method === 'DELETE') return withCors(await handleDeleteProfile(request, env, id));
      if (method === 'POST' && profileMatch[2]) return withCors(await handleInstallProfile(request, env, id));
    }

    return new Response('Not found', { status: 404 });
  },

  // Cron (*/5 * * * *): keep every whitelisted user's tier in sync with their
  // live Discord roles, so removing a role actually drops their in-game rank.
  async scheduled(_event: ScheduledEvent, env: Env, ctx: ExecutionContext): Promise<void> {
    ctx.waitUntil(resyncAllTiers(env));
  },
};

function json(data: unknown): Response {
  return new Response(JSON.stringify(data), {
    headers: { 'Content-Type': 'application/json', ...corsHeaders() },
  });
}
function corsHeaders(): Record<string, string> {
  return {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type, x-vain-secret',
  };
}
function withCors(response: Response): Response {
  const headers = new Headers(response.headers);
  for (const [k, v] of Object.entries(corsHeaders())) headers.set(k, v);
  return new Response(response.body, { status: response.status, headers });
}
