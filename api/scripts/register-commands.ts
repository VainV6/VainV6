// Run once: npm run register

async function main() {
  const APPLICATION_ID = process.env.DISCORD_APPLICATION_ID ?? '1512790996033736946';
  const BOT_TOKEN = process.env.DISCORD_BOT_TOKEN ?? '';
  const GUILD_ID = process.env.DISCORD_GUILD_ID ?? '';

  if (!BOT_TOKEN) { console.error('Set DISCORD_BOT_TOKEN'); process.exit(1); }

  const commands = [
    {
      name: 'whitelist',
      description: 'Manage your Vain whitelist entry',
      options: [
        {
          type: 1, name: 'edit',
          description: 'Link your Roblox account to your Discord (Premium only)',
          options: [{ type: 3, name: 'username', description: 'Your Roblox username', required: true }],
        },
        {
          type: 1, name: 'info',
          description: 'Look up whitelist info for a Roblox username',
          options: [{ type: 3, name: 'username', description: 'Roblox username', required: true }],
        },
      ],
    },
  ];

  const headers = { 'Authorization': `Bot ${BOT_TOKEN}`, 'Content-Type': 'application/json' };
  const guildUrl  = `https://discord.com/api/v10/applications/${APPLICATION_ID}/guilds/${GUILD_ID}/commands`;
  const globalUrl = `https://discord.com/api/v10/applications/${APPLICATION_ID}/commands`;

  // A PUT fully REPLACES the command set at a scope. In the past commands got
  // registered to BOTH the guild and global scopes, so Discord showed every
  // command twice and left orphans (e.g. an old /players the bot no longer
  // handles) lingering in whichever scope wasn't re-PUT. Fix + prevent recurrence
  // by owning both scopes every run: put the real commands on the guild (updates
  // instantly, right for a single-server bot) and wipe the global scope to [].
  if (!GUILD_ID) {
    console.error('Set DISCORD_GUILD_ID (commands are registered guild-scoped).');
    process.exit(1);
  }

  const guildRes = await fetch(guildUrl, { method: 'PUT', headers, body: JSON.stringify(commands) });
  if (!guildRes.ok) {
    console.error('Guild register failed:', guildRes.status, await guildRes.text());
    process.exit(1);
  }
  console.log(`Registered ${commands.length} command(s) to guild ${GUILD_ID}.`);

  // Wipe any stale GLOBAL commands (removes duplicates + orphaned /players).
  const globalRes = await fetch(globalUrl, { method: 'PUT', headers, body: JSON.stringify([]) });
  if (!globalRes.ok) {
    console.error('Global wipe failed:', globalRes.status, await globalRes.text());
    process.exit(1);
  }
  console.log('Cleared global command scope (removed duplicates / orphaned commands).');
}

main();
