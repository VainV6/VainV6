export interface Env {
  DB: D1Database;
  DISCORD_APPLICATION_ID: string;
  DISCORD_PUBLIC_KEY: string;
  DISCORD_BOT_TOKEN: string;
  BOT_SECRET: string;
  DISCORD_GUILD_ID: string;
}

export const TIER = { Free: 0, Premium: 1, Owner: 2 } as const;
export type TierValue = 0 | 1 | 2;

export const TIER_NAME: Record<number, string> = {
  0: 'Free',
  1: 'Premium',
  2: 'Owner',
};

// Discord role name → tier.
export const ROLE_TIER_MAP: Record<string, TierValue> = {
  'Premium': 1,
  'Owner':   2,
};

export interface WhitelistRow {
  discord_id: string;
  roblox_username: string | null;
  roblox_user_id: string | null;
  tier: TierValue;
  created_at: number;
  updated_at: number;
  last_seen: number | null;
}

