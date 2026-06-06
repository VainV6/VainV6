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
    {
      name: 'players',
      description: 'List whitelisted players currently injected (Premium only)',
    },
  ];

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
