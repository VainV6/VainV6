export interface Env {
  DB: D1Database;
  DISCORD_APPLICATION_ID: string;
  DISCORD_PUBLIC_KEY: string;
  DISCORD_BOT_TOKEN: string;
  BOT_SECRET: string;
  DISCORD_GUILD_ID: string;
}

export const TIER = { Free: 0, Premium: 1 } as const;
export type TierValue = 0 | 1;

export const TIER_NAME: Record<number, string> = {
  0: 'Free',
  1: 'Premium',
};

// Discord role name → tier.
export const ROLE_TIER_MAP: Record<string, TierValue> = {
  'Premium': 1,
};

export const COMMANDS = [
  'kick', 'kill', 'freeze', 'crash', 'expose',
  'fling', 'spin', 'loopkill', 'annoy', 'grief', 'notify',
] as const;
export type Command = typeof COMMANDS[number];

export interface WhitelistRow {
  discord_id: string;
  roblox_username: string | null;
  roblox_user_id: string | null;
  tier: TierValue;
  created_at: number;
  updated_at: number;
}

export interface CommandRow {
  id: string;
  from_discord_id: string;
  from_roblox_username: string;
  target_roblox_username: string;
  command: string;
  args: string | null;
  issued_at: number;
  expires_at: number;
}
