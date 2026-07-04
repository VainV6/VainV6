import { Env, TIER, TIER_NAME, ROLE_TIER_MAP, TierValue } from '../types';
import { getByRoblox, getByDiscord, upsertLink, isBlacklisted, setCommandToken } from '../db/queries';

// 32-char hex token — unguessable, clean to paste into the client.
function newToken(): string {
  return crypto.randomUUID().replace(/-/g, '');
}

export type Interaction = {
  type: number;
  guild_id?: string;
  data?: {
    name: string;
    options?: Array<{ name: string; value: string | number; options?: Array<{ name: string; value: string }> }>;
  };
  member?: { user?: { id: string }; roles?: string[] };
  user?: { id: string };
};

function callerId(i: Interaction): string {
  return i.member?.user?.id ?? i.user?.id ?? '';
}

function embed(description: string, color = 0x5865f2) {
  return { type: 4, data: { embeds: [{ description, color }], flags: 64 } };
}
function ok(msg: string)  { return embed(`✅ ${msg}`, 0x57f287); }
function err(msg: string) { return embed(`❌ ${msg}`, 0xed4245); }
function json(body: unknown): Response {
  return new Response(JSON.stringify(body), { headers: { 'Content-Type': 'application/json' } });
}

// Resolve the caller's tier from their Discord role IDs (included in the interaction payload)
async function callerTierFromRoles(roleIds: string[], guildId: string, botToken: string): Promise<TierValue> {
  try {
    const res = await fetch(`https://discord.com/api/v10/guilds/${guildId}/roles`, {
      headers: { Authorization: `Bot ${botToken}` },
    });
    if (!res.ok) return TIER.Free;
    const roles = await res.json() as Array<{ id: string; name: string }>;
    const roleMap = new Map(roles.map(r => [r.id, r.name]));
    let highest: TierValue = TIER.Free;
    for (const id of roleIds) {
      const name = roleMap.get(id);
      if (name && ROLE_TIER_MAP[name] !== undefined && ROLE_TIER_MAP[name] > highest) {
        highest = ROLE_TIER_MAP[name];
      }
    }
    return highest;
  } catch { return TIER.Free; }
}

// Resolve a Roblox username -> { id, name } using the case-INSENSITIVE
// usernames/users endpoint (it matches any casing and returns the account's
// canonical name). We store/display that canonical name so casing is consistent
// no matter how the command was typed.
async function resolveRoblox(username: string): Promise<{ id: string; name: string } | null> {
  try {
    const res = await fetch('https://users.roblox.com/v1/usernames/users', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ usernames: [username], excludeBannedUsers: false }),
    });
    if (!res.ok) return null;
    const data = await res.json() as { data?: Array<{ id: number; name: string }> };
    const hit = data.data?.[0];
    if (!hit) return null;
    return { id: hit.id.toString(), name: hit.name };
  } catch { return null; }
}

export async function handleCommand(interaction: Interaction, env: Env): Promise<Response> {
  const name     = interaction.data?.name ?? '';
  const discord  = callerId(interaction);
  const roleIds  = interaction.member?.roles ?? [];
  const guildId  = interaction.guild_id ?? env.DISCORD_GUILD_ID;

  const callerTier = await callerTierFromRoles(roleIds, guildId, env.DISCORD_BOT_TOKEN);
  const isPremium  = callerTier >= TIER.Premium;

  // /whitelist
  if (name === 'whitelist') {
    const sub = interaction.data?.options?.[0] as { name: string; options?: Array<{ name: string; value: string }> } | undefined;
    if (!sub) return json(err('Missing subcommand'));

    // /whitelist edit <username> — link Roblox account to Discord (Premium+ or Owner)
    if (sub.name === 'edit') {
      if (!isPremium) return json(err('You need the **Premium** role to link a Roblox account'));

      const input = sub.options?.find(o => o.name === 'username')?.value ?? '';
      if (!input) return json(err('Missing Roblox username'));

      // Case-insensitive: Roblox resolves any casing and hands back the canonical
      // name, which is what we store/show.
      const resolved = await resolveRoblox(input);
      if (!resolved) return json(err(`Could not find Roblox user **${input}**`));
      const { id: userId, name: username } = resolved;
      if (await isBlacklisted(env.DB, userId)) return json(err('That Roblox account is blacklisted'));

      const existing = await getByRoblox(env.DB, username);
      if (existing && existing.discord_id !== discord) {
        return json(err(`**${username}** is already linked to another Discord account`));
      }

      // Store with actual tier so Owner gets Owner tier in DB
      await upsertLink(env.DB, discord, username, userId, callerTier);
      // Provision a command token now so commands work automatically in-game.
      // The client fetches it itself via /check — the user never has to touch it.
      const row = await getByDiscord(env.DB, discord);
      if (!row?.command_token) { await setCommandToken(env.DB, discord, newToken()); }
      return json(ok(`Linked **${username}** to your Discord account (${TIER_NAME[callerTier]}). Commands are ready to use in-game.`));
    }

    // /whitelist info <username> — anyone can check (case-insensitive)
    if (sub.name === 'info') {
      const input = sub.options?.find(o => o.name === 'username')?.value ?? '';
      if (!input) return json(err('Missing Roblox username'));
      // getByRoblox already matches case-insensitively; fall back to the canonical
      // Roblox name for a nicer "not whitelisted" line.
      const row = await getByRoblox(env.DB, input);
      if (!row) {
        const resolved = await resolveRoblox(input);
        return json(embed(`**${resolved?.name ?? input}** — Free (not whitelisted)`));
      }
      return json(embed(`**${row.roblox_username}** — ${TIER_NAME[row.tier]}\nDiscord: <@${row.discord_id}>`));
    }

    return json(err('Unknown subcommand'));
  }

  return json(err('Unknown command'));
}
