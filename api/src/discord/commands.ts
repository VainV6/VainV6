import { Env, TIER, TIER_NAME, ROLE_TIER_MAP, TierValue } from '../types';
import { getByDiscordId, getByRoblox, upsertLink, isBlacklisted, getOnlinePlayers } from '../db/queries';

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

async function resolveRobloxId(username: string): Promise<string | null> {
  try {
    const res = await fetch('https://users.roblox.com/v1/usernames/users', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ usernames: [username], excludeBannedUsers: false }),
    });
    if (!res.ok) return null;
    const data = await res.json() as { data?: Array<{ id: number }> };
    return data.data?.[0]?.id?.toString() ?? null;
  } catch { return null; }
}

export async function handleCommand(interaction: Interaction, env: Env): Promise<Response> {
  const name     = interaction.data?.name ?? '';
  const discord  = callerId(interaction);
  const roleIds  = interaction.member?.roles ?? [];
  const guildId  = interaction.guild_id ?? env.DISCORD_GUILD_ID;

  const callerTier = await callerTierFromRoles(roleIds, guildId, env.DISCORD_BOT_TOKEN);
  const isOwner    = callerTier >= TIER.Owner;
  const isPremium  = callerTier >= TIER.Premium;

  // /whitelist
  if (name === 'whitelist') {
    const sub = interaction.data?.options?.[0] as { name: string; options?: Array<{ name: string; value: string }> } | undefined;
    if (!sub) return json(err('Missing subcommand'));

    // /whitelist edit <username> — link Roblox account to Discord (Premium+ or Owner)
    if (sub.name === 'edit') {
      if (!isPremium) return json(err('You need the **Premium** role to link a Roblox account'));

      const username = sub.options?.find(o => o.name === 'username')?.value ?? '';
      if (!username) return json(err('Missing Roblox username'));

      const userId = await resolveRobloxId(username);
      if (!userId) return json(err(`Could not find Roblox user **${username}**`));
      if (await isBlacklisted(env.DB, userId)) return json(err('That Roblox account is blacklisted'));

      const existing = await getByRoblox(env.DB, username);
      if (existing && existing.discord_id !== discord) {
        return json(err(`**${username}** is already linked to another Discord account`));
      }

      // Store with actual tier so Owner gets Owner tier in DB
      await upsertLink(env.DB, discord, username, userId, callerTier);
      return json(ok(`Linked **${username}** to your Discord account (${TIER_NAME[callerTier]})`));
    }

    // /whitelist info <username> — anyone can check
    if (sub.name === 'info') {
      const username = sub.options?.find(o => o.name === 'username')?.value ?? '';
      if (!username) return json(err('Missing Roblox username'));
      const row = await getByRoblox(env.DB, username);
      if (!row) return json(embed(`**${username}** — Free (not whitelisted)`));
      return json(embed(`**${row.roblox_username}** — ${TIER_NAME[row.tier]}\nDiscord: <@${row.discord_id}>`));
    }

    return json(err('Unknown subcommand'));
  }

  // /players — list all injected players seen in last 30s (Premium+ or Owner)
  if (name === 'players') {
    if (!isPremium) return json(err('You need **Premium** to use `/players`'));
    const online = await getOnlinePlayers(env.DB);
    if (online.length === 0) return json(embed('No players currently injected.'));
    // Enrich each entry with their whitelist tier if they have one
    const lines = await Promise.all(online.map(async r => {
      const wl = await getByRoblox(env.DB, r.username);
      const tierLabel = wl ? TIER_NAME[wl.tier] : 'Free';
      return `• **${r.username}** — ${tierLabel}`;
    }));
    return json(embed(`**Injected (${online.length})**\n${lines.join('\n')}`));
  }

  return json(err('Unknown command'));
}
