import { Env, TIER } from '../types';
import { getByRoblox } from '../db/queries';

const PAGE_SIZE = 20;

interface ProfileRow {
  id: string;
  author_discord_id: string;
  author_roblox_username: string;
  game_id: string;
  name: string;
  description: string | null;
  data: string;
  installs: number;
  created_at: number;
  updated_at: number;
}

function json(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });
}
function err(msg: string, status = 400): Response {
  return json({ error: msg }, status);
}
function authErr(): Response { return err('Unauthorized', 401); }

// GET /profiles?game_id=X&sort=installs|newest|name&search=Y&page=N
export async function handleListProfiles(request: Request, env: Env): Promise<Response> {
  const url    = new URL(request.url);
  const gameId = url.searchParams.get('game_id') ?? '';
  const sort   = url.searchParams.get('sort') ?? 'installs';
  const search = (url.searchParams.get('search') ?? '').trim();
  const page   = Math.max(1, parseInt(url.searchParams.get('page') ?? '1'));
  const offset = (page - 1) * PAGE_SIZE;

  if (!gameId) return err('Missing game_id');

  const orderBy = sort === 'newest' ? 'created_at DESC'
    : sort === 'name' ? 'LOWER(name) ASC'
    : 'installs DESC';

  let query: string;
  let binds: (string | number)[];

  if (search) {
    query = `SELECT id, author_roblox_username, game_id, name, description, installs, created_at, updated_at
             FROM global_profiles
             WHERE game_id = ? AND (LOWER(name) LIKE ? OR LOWER(author_roblox_username) LIKE ?)
             ORDER BY ${orderBy} LIMIT ? OFFSET ?`;
    const like = `%${search.toLowerCase()}%`;
    binds = [gameId, like, like, PAGE_SIZE, offset];
  } else {
    query = `SELECT id, author_roblox_username, game_id, name, description, installs, created_at, updated_at
             FROM global_profiles WHERE game_id = ?
             ORDER BY ${orderBy} LIMIT ? OFFSET ?`;
    binds = [gameId, PAGE_SIZE, offset];
  }

  const stmt = env.DB.prepare(query);
  const result = await (stmt.bind as (...a: (string|number)[]) => D1PreparedStatement)(...binds).all<Omit<ProfileRow, 'data' | 'author_discord_id'>>();

  const countQuery = search
    ? `SELECT COUNT(*) as c FROM global_profiles WHERE game_id = ? AND (LOWER(name) LIKE ? OR LOWER(author_roblox_username) LIKE ?)`
    : `SELECT COUNT(*) as c FROM global_profiles WHERE game_id = ?`;
  const countBinds = search ? [gameId, `%${search.toLowerCase()}%`, `%${search.toLowerCase()}%`] : [gameId];
  const countStmt = env.DB.prepare(countQuery);
  const countResult = await (countStmt.bind as (...a: string[]) => D1PreparedStatement)(...countBinds).first<{ c: number }>();

  return json({
    profiles: result.results,
    total: countResult?.c ?? 0,
    page,
    pages: Math.ceil((countResult?.c ?? 0) / PAGE_SIZE),
  });
}

// POST /profiles  body: { from, name, description?, data }
export async function handleCreateProfile(request: Request, env: Env): Promise<Response> {
  const secret = request.headers.get('x-vain-secret');
  if (secret !== env.BOT_SECRET) return authErr();

  const body = await request.json().catch(() => null) as Record<string, string> | null;
  if (!body?.from || !body.name || !body.data || !body.game_id) return err('Missing fields');
  if (body.name.length > 64) return err('Name too long (max 64)');

  const author = await getByRoblox(env.DB, body.from);
  if (!author) return err('Not whitelisted', 403);
  if (author.tier < TIER.Premium) return err('Premium or higher required to upload profiles', 403);

  const now = Date.now();

  // Rate limit: one upload per hour per author (Owner is exempt)
  if (author.tier < TIER.Owner) {
    const last = await env.DB.prepare(
      'SELECT MAX(created_at) as t FROM global_profiles WHERE author_discord_id = ?'
    ).bind(author.discord_id).first<{ t: number | null }>();
    const lastUpload = last?.t ?? 0;
    const HOUR = 60 * 60 * 1000;
    if (lastUpload && now - lastUpload < HOUR) {
      const minsLeft = Math.ceil((HOUR - (now - lastUpload)) / 60000);
      return err(`You can upload one profile per hour. Try again in ${minsLeft} min`, 429);
    }
  }

  // Names must be unique per game
  const dup = await env.DB.prepare(
    'SELECT 1 FROM global_profiles WHERE game_id = ? AND LOWER(name) = LOWER(?)'
  ).bind(body.game_id, body.name).first();
  if (dup) return err('A profile with that name already exists', 409);

  const id = crypto.randomUUID();
  await env.DB.prepare(`
    INSERT INTO global_profiles (id, author_discord_id, author_roblox_username, game_id, name, description, data, installs, created_at, updated_at)
    VALUES (?, ?, ?, ?, ?, ?, ?, 0, ?, ?)
  `).bind(id, author.discord_id, body.from, body.game_id, body.name, body.description ?? null, body.data, now, now).run();

  return json({ id });
}

// PUT /profiles/:id  body: { from, name?, description?, data? }
export async function handleUpdateProfile(request: Request, env: Env, id: string): Promise<Response> {
  const secret = request.headers.get('x-vain-secret');
  if (secret !== env.BOT_SECRET) return authErr();

  const body = await request.json().catch(() => null) as Record<string, string> | null;
  if (!body?.from) return err('Missing from');

  const author = await getByRoblox(env.DB, body.from);
  if (!author) return err('Not whitelisted', 403);

  const profile = await env.DB.prepare('SELECT * FROM global_profiles WHERE id = ?')
    .bind(id).first<ProfileRow>();
  if (!profile) return err('Profile not found', 404);
  if (profile.author_discord_id !== author.discord_id) return err('Not your profile', 403);

  const fields: string[] = [];
  const values: (string | number)[] = [];
  if (body.name)        { fields.push('name = ?');        values.push(body.name.slice(0, 64)); }
  if (body.description !== undefined) { fields.push('description = ?'); values.push(body.description); }
  if (body.data)        { fields.push('data = ?');        values.push(body.data); }
  fields.push('updated_at = ?'); values.push(Date.now());
  values.push(id);

  await (env.DB.prepare(`UPDATE global_profiles SET ${fields.join(', ')} WHERE id = ?`)
    .bind as (...a: (string|number)[]) => D1PreparedStatement)(...values).run();

  return json({ ok: true });
}

// DELETE /profiles/:id  body: { from }
export async function handleDeleteProfile(request: Request, env: Env, id: string): Promise<Response> {
  const secret = request.headers.get('x-vain-secret');
  if (secret !== env.BOT_SECRET) return authErr();

  const body = await request.json().catch(() => null) as Record<string, string> | null;
  if (!body?.from) return err('Missing from');

  const user = await getByRoblox(env.DB, body.from);
  if (!user) return err('Not whitelisted', 403);

  const profile = await env.DB.prepare('SELECT * FROM global_profiles WHERE id = ?')
    .bind(id).first<ProfileRow>();
  if (!profile) return err('Profile not found', 404);

  const isOwn = profile.author_discord_id === user.discord_id;
  const canDelete = isOwn || user.tier >= TIER.Owner;
  if (!canDelete) return err('Forbidden', 403);

  await env.DB.prepare('DELETE FROM global_profiles WHERE id = ?').bind(id).run();
  return json({ ok: true });
}

// POST /profiles/:id/install  body: { from }
export async function handleInstallProfile(request: Request, env: Env, id: string): Promise<Response> {
  const secret = request.headers.get('x-vain-secret');
  if (secret !== env.BOT_SECRET) return authErr();

  const body = await request.json().catch(() => null) as Record<string, string> | null;
  if (!body?.from) return err('Missing from');

  const user = await getByRoblox(env.DB, body.from);
  if (!user) return err('Not whitelisted', 403);

  const profile = await env.DB.prepare('SELECT * FROM global_profiles WHERE id = ?')
    .bind(id).first<ProfileRow>();
  if (!profile) return err('Profile not found', 404);

  await env.DB.prepare('UPDATE global_profiles SET installs = installs + 1 WHERE id = ?')
    .bind(id).run();

  return json({ data: profile.data, name: profile.name, author: profile.author_roblox_username });
}
