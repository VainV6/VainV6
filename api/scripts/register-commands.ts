// Run once: npm run register

async function main() {
  const APPLICATION_ID = process.env.DISCORD_APPLICATION_ID ?? '1512790996033736946';
  const BOT_TOKEN = process.env.DISCORD_BOT_TOKEN ?? '';
  const GUILD_ID = process.env.DISCORD_GUILD_ID ?? '';

  if (!BOT_TOKEN) { console.error('Set DISCORD_BOT_TOKEN'); process.exit(1); }

  const commands = [
    {
      name: 'whitelist',
      description: 'Link or manage your Vain whitelist entry',
      options: [
        {
          type: 1, name: 'edit',
          description: 'Link your Roblox account to your Discord',
          options: [{ type: 3, name: 'username', description: 'Your Roblox username', required: true }],
        },
        {
          type: 1, name: 'remove',
          description: 'Unlink a Roblox account (Owner can remove others)',
          options: [{ type: 3, name: 'username', description: 'Roblox username', required: true }],
        },
        {
          type: 1, name: 'info',
          description: 'View whitelist info for a user',
          options: [{ type: 3, name: 'username', description: 'Roblox username', required: true }],
        },
      ],
    },
    {
      name: 'settier',
      description: 'Set a Discord user\'s tier and sync their role (Owner only)',
      options: [
        { type: 6, name: 'user', description: 'Discord user', required: true },
        {
          type: 3, name: 'tier', description: 'Tier to assign', required: true,
          choices: [
            { name: 'Free',       value: 'Free' },
            { name: 'Premium',    value: 'Premium' },
            { name: 'Privileged', value: 'Privileged' },
            { name: 'Owner',      value: 'Owner' },
          ],
        },
      ],
    },
    ...(['kick','kill','freeze','crash','expose','fling','spin','loopkill','annoy','grief'] as const).map(cmd => ({
      name: cmd,
      description: `${cmd.charAt(0).toUpperCase() + cmd.slice(1)} a Vain user in-game (Premium+)`,
      options: [
        { type: 3, name: 'target', description: 'Target Roblox username', required: true },
      ],
    })),
    {
      name: 'notify',
      description: 'Send a notification to a Vain user in-game (Premium+)',
      options: [
        { type: 3, name: 'target',  description: 'Target Roblox username', required: true },
        { type: 3, name: 'message', description: 'Message to display',     required: true },
      ],
    },
    {
      name: 'sync',
      description: 'Re-sync your tier from your current Discord roles',
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
