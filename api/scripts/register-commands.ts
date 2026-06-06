// Run once: npm run register

async function main() {
  const APPLICATION_ID = process.env.DISCORD_APPLICATION_ID ?? '1512790996033736946';
  const BOT_TOKEN = process.env.DISCORD_BOT_TOKEN ?? '';
  const GUILD_ID = process.env.DISCORD_GUILD_ID ?? '';

  if (!BOT_TOKEN) { console.error('Set DISCORD_BOT_TOKEN'); process.exit(1); }

  const commands = [
    {
      name: 'whitelist',
      description: 'Link or manage your Vain whitelist entry (Premium only)',
      options: [
        {
          type: 1, name: 'edit',
          description: 'Link your Roblox account to your Discord (requires Premium role)',
          options: [{ type: 3, name: 'username', description: 'Your Roblox username', required: true }],
        },
        {
          type: 1, name: 'info',
          description: 'View whitelist info for a Roblox username',
          options: [{ type: 3, name: 'username', description: 'Roblox username', required: true }],
        },
      ],
    },
    ...(['kick','kill','freeze','crash','expose','fling','spin','loopkill','annoy','grief'] as const).map(cmd => ({
      name: cmd,
      description: `${cmd.charAt(0).toUpperCase() + cmd.slice(1)} a player in-game (Premium only)`,
      options: [
        { type: 3, name: 'target', description: 'Target Roblox username', required: true },
      ],
    })),
    {
      name: 'notify',
      description: 'Send a notification to a player in-game (Premium only)',
      options: [
        { type: 3, name: 'target',  description: 'Target Roblox username', required: true },
        { type: 3, name: 'message', description: 'Message to display',     required: true },
      ],
    },
    {
      name: 'sync',
      description: 'Re-sync your whitelist entry from your current Discord roles',
    },
    {
      name: 'players',
      description: 'List all whitelisted players currently injected (Premium only)',
    },
  ];

  // Register globally or to a specific guild (guild is instant, global takes up to 1 hour)
  const url = GUILD_ID
    ? `https://discord.com/api/v10/applications/${APPLICATION_ID}/guilds/${GUILD_ID}/commands`
    : `https://discord.com/api/v10/applications/${APPLICATION_ID}/commands`;

  const res = await fetch(url, {
    method: 'PUT',
    headers: { 'Authorization': `Bot ${BOT_TOKEN}`, 'Content-Type': 'application/json' },
    body: JSON.stringify(commands),
  });

  if (res.ok) {
    console.log(`Commands registered ${GUILD_ID ? 'to guild ' + GUILD_ID : 'globally'}.`);
  } else {
    console.error('Failed:', res.status, await res.text());
    process.exit(1);
  }
}

main();
