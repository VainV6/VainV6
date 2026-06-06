import { Env, TIER, TIER_NAME } from '../types';
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

function subOpt(i: Interaction, name: string): string {
  const sub = i.data?.options?.[0] as { options?: Array<{ name: string; value: string }> } | undefined;
  return sub?.options?.find(o => o.name === name)?.value ?? '';
}

function embed(description: string, color = 0x5865f2) {
  return { type: 4, data: { embeds: [{ description, color }], flags: 64 } };
}
function ok(msg: string)  { return embed(`✅ ${msg}`, 0x57f287); }
function err(msg: string) { return embed(`❌ ${msg}`, 0xed4245); }
function json(body: unknown): Response {
  return new Response(JSON.stringify(body), { headers: { 'Content-Type': 'application/json' } });
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

function isPremium(i: Interaction, env: Env): boolean {
  // Premium is validated via DB (they must have run /whitelist edit)
  // For Discord commands, we check their DB row exists and has tier >= Premium
  // Actual check is done async below — this is just a stub
  return true;
}

export async function handleCommand(interaction: Interaction, env: Env): Promise<Response> {
  const name    = interaction.data?.name ?? '';
  const discord = callerId(interaction);

  // /whitelist
  if (name === 'whitelist') {
    const sub = interaction.data?.options?.[0] as { name: string; options?: Array<{ name: string; value: string }> } | undefined;
    if (!sub) return json(err('Missing subcommand'));

    // /whitelist edit <username> — link Roblox account to Discord
    if (sub.name === 'edit') {
      const callerRow = await getByDiscordId(env.DB, discord);
      if (!callerRow || callerRow.tier < TIER.Premium) {
        return json(err('You need the **Premium** role to link a Roblox account'));
      }

      const username = sub.options?.find(o => o.name === 'username')?.value ?? '';
      if (!username) return json(err('Missing Roblox username'));

      const userId = await resolveRobloxId(username);
      if (!userId) return json(err(`Could not find Roblox user **${username}**`));
      if (await isBlacklisted(env.DB, userId)) return json(err('That Roblox account is blacklisted'));

      const existing = await getByRoblox(env.DB, username);
      if (existing && existing.discord_id !== discord) {
        return json(err(`**${username}** is already linked to another Discord account`));
      }

      await upsertLink(env.DB, discord, username, userId, TIER.Premium);
      return json(ok(`Linked **${username}** to your Discord account`));
    }

    // /whitelist info <username>
    if (sub.name === 'info') {
      const username = sub.options?.find(o => o.name === 'username')?.value ?? '';
      if (!username) return json(err('Missing Roblox username'));
      const row = await getByRoblox(env.DB, username);
      if (!row) return json(embed(`**${username}** — Free (not whitelisted)`));
      return json(embed(`**${row.roblox_username}** — ${TIER_NAME[row.tier]}\nDiscord: <@${row.discord_id}>`));
    }

    return json(err('Unknown subcommand'));
  }

  // /players — list whitelisted players seen in last 30s
  if (name === 'players') {
    const callerRow = await getByDiscordId(env.DB, discord);
    if (!callerRow || callerRow.tier < TIER.Premium) {
      return json(err('You need **Premium** to use `/players`'));
    }
    const online = await getOnlinePlayers(env.DB);
    if (online.length === 0) return json(embed('No whitelisted players currently injected.'));
    const lines = online.map(r => `• **${r.roblox_username ?? '?'}** — ${TIER_NAME[r.tier]}`);
    return json(embed(`**Injected (${online.length})**\n${lines.join('\n')}`));
  }

  return json(err('Unknown command'));
}
