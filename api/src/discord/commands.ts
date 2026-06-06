import { Env, TIER, TIER_NAME, TierValue, ROLE_TIER_MAP, COMMANDS } from '../types';
import {
  getByDiscordId, getByRoblox, upsertLink,
  isBlacklisted, queueCommand, getOnlinePlayers,
} from '../db/queries';

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
function callerRoles(i: Interaction): string[] {
  return i.member?.roles ?? [];
}
function subOpt(i: Interaction, name: string): string {
  const sub = i.data?.options?.[0] as { options?: Array<{ name: string; value: string }> } | undefined;
  return sub?.options?.find(o => o.name === name)?.value ?? '';
}
function topOpt(i: Interaction, name: string): string {
  return String(i.data?.options?.find(o => o.name === name)?.value ?? '');
}

function embed(description: string, color = 0x5865f2) {
  return { type: 4, data: { embeds: [{ description, color }], flags: 64 } };
}
function ok(msg: string)  { return embed(`✅ ${msg}`, 0x57f287); }
function err(msg: string) { return embed(`❌ ${msg}`, 0xed4245); }
function json(body: unknown): Response {
  return new Response(JSON.stringify(body), { headers: { 'Content-Type': 'application/json' } });
}

// Fetch guild roles from Discord, return map of roleId → roleName
async function fetchGuildRoles(guildId: string, botToken: string): Promise<Map<string, string>> {
  const res = await fetch(`https://discord.com/api/v10/guilds/${guildId}/roles`, {
    headers: { Authorization: `Bot ${botToken}` },
  });
  if (!res.ok) return new Map();
  const roles = await res.json() as Array<{ id: string; name: string }>;
  return new Map(roles.map(r => [r.id, r.name]));
}

// Derive highest tier from a member's role IDs
async function tierFromRoleIds(roleIds: string[], guildId: string, botToken: string): Promise<TierValue> {
  const guildRoles = await fetchGuildRoles(guildId, botToken);
  let highest: TierValue = TIER.Free;
  for (const id of roleIds) {
    const name = guildRoles.get(id);
    if (name && ROLE_TIER_MAP[name] !== undefined) {
      if (ROLE_TIER_MAP[name] > highest) highest = ROLE_TIER_MAP[name];
    }
  }
  return highest;
}


async function resolveRobloxId(username: string): Promise<string | null> {
  try {
    const res = await fetch('https://users.roblox.com/v1/usernames/users', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ usernames: [username], excludeBannedUsers: false }),
    });
    if (!res.ok) return null;
    const data = await res.json() as { data?: Array<{ id: number; name: string }> };
    return data.data?.[0]?.id?.toString() ?? null;
  } catch { return null; }
}

export async function handleCommand(interaction: Interaction, env: Env): Promise<Response> {
  const name     = interaction.data?.name ?? '';
  const discord  = callerId(interaction);
  const roles    = callerRoles(interaction);
  const guildId  = interaction.guild_id ?? env.DISCORD_GUILD_ID;

  const callerTier = await tierFromRoleIds(roles, guildId, env.DISCORD_BOT_TOKEN);

  // /whitelist edit <roblox_username> — self-service: link your own Roblox account
  if (name === 'whitelist') {
    const sub = interaction.data?.options?.[0] as { name: string; options?: Array<{ name: string; value: string }> } | undefined;
    if (!sub) return json(err('Missing subcommand'));
    const username = sub.options?.find(o => o.name === 'username')?.value ?? '';

    if (sub.name === 'edit') {
      if (callerTier < TIER.Premium) return json(err('You need **Premium** or higher to link a Roblox account'));
      if (!username) return json(err('Missing Roblox username'));
      const userId = await resolveRobloxId(username);
      if (!userId) return json(err(`Could not find Roblox user **${username}**`));
      if (await isBlacklisted(env.DB, userId)) return json(err('Your Roblox account is blacklisted'));

      // Check if another Discord account already owns this Roblox username
      const existing = await getByRoblox(env.DB, username);
      if (existing && existing.discord_id !== discord) {
        return json(err(`**${username}** is already linked to another Discord account`));
      }

      await upsertLink(env.DB, discord, username, userId, callerTier);
      return json(ok(`Linked **${username}** to your Discord. Your tier: **${TIER_NAME[callerTier]}**`));
    }

    if (sub.name === 'info') {
      if (!username) return json(err('Missing Roblox username'));
      const row = await getByRoblox(env.DB, username);
      if (!row) return json(err(`**${username}** is not whitelisted`));
      return json(embed(
        `**${row.roblox_username}**\nTier: **${TIER_NAME[row.tier]}**\nDiscord: <@${row.discord_id}>`,
      ));
    }

    return json(err('Unknown subcommand'));
  }

  // /<command> <target> [message] — individual command slash commands (Premium+)
  if ((COMMANDS as readonly string[]).includes(name)) {
    if (callerTier < TIER.Premium) return json(err('You need **Premium** or higher to use commands'));

    const target = topOpt(interaction, 'target');
    const args   = topOpt(interaction, 'message') || null;

    const targetRow = await getByRoblox(env.DB, target);
    const targetTier = targetRow?.tier ?? 0;
    if (targetTier >= callerTier) {
      return json(err(`Cannot target **${TIER_NAME[targetTier]}** — must be lower than your tier (**${TIER_NAME[callerTier]}**)`));
    }

    const callerRow = await getByDiscordId(env.DB, discord);
    const id = crypto.randomUUID();
    await queueCommand(env.DB, id, discord, callerRow?.roblox_username ?? discord, target, name, args);
    return json(ok(`**${name}** queued for **${target}**`));
  }

  // /sync — re-sync your own tier from your current Discord roles
  if (name === 'sync') {
    const row = await getByDiscordId(env.DB, discord);
    if (!row) return json(err('You have no linked Roblox account. Use `/whitelist edit` first (requires Premium)'));
    await upsertLink(env.DB, discord, row.roblox_username ?? '', row.roblox_user_id ?? '', callerTier);
    return json(ok(`Synced. Your tier is now **${TIER_NAME[callerTier]}**`));
  }

  // /players — list all players currently injected (seen in last 30s)
  if (name === 'players') {
    if (callerTier < TIER.Premium) return json(err('You need **Premium** or higher to use `/players`'));
    const online = await getOnlinePlayers(env.DB);
    if (online.length === 0) return json(embed('No players currently injected.', 0x5865f2));
    const lines = online.map(r => `• **${r.roblox_username ?? '?'}** — ${TIER_NAME[r.tier]}`);
    return json(embed(`**Injected players (${online.length})**\n${lines.join('\n')}`, 0x5865f2));
  }

  return json(err('Unknown command'));
}

