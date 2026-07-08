import { Env } from '../types';
import { listGlobalTargets } from '../db/queries';

// GET /globaltargets -> { targets: ["Name1", "Name2", ...] }
// Read by every client (they compare by username against players in-server).
// Just the canonical usernames; who added each one stays server-side.
export async function handleGlobalTargets(_request: Request, env: Env): Promise<Response> {
  const rows = await listGlobalTargets(env.DB);
  return new Response(JSON.stringify({ targets: rows.map(r => r.roblox_username) }), {
    headers: { 'Content-Type': 'application/json' },
  });
}
