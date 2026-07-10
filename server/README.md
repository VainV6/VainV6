# Vain delivery + access control

Serves the **private** `VainV6/Vain` repo through a Cloudflare Worker gated by a
per-user **key + HWID lock**. The GitHub PAT lives only in the Worker (as a
secret); users never see it. The only thing users get is `entrypoint.lua` with
their key filled in.

## How it fits together

```
user runs entrypoint.lua (key + HWID)
        │  hooks HttpGet: raw.githubusercontent.com/VainV6/Vain/*  ->  Worker
        ▼
Cloudflare Worker  ──(checks key+HWID in KV)──►  GitHub Contents API (PAT)
        │                                             │
        └───────── file body (or 403 stub) ◄──────────┘
```

Because the entrypoint transparently redirects Vain's existing raw fetches to
the Worker, **the rest of Vain needs no changes** — init.lua, guis, libraries
and per-game files keep their existing URLs.

## One-time deploy

1. **Make the repo private** on GitHub (Settings → Danger Zone → Change visibility).

2. **Fine-grained PAT** for the Worker: GitHub → Settings → Developer settings →
   Fine-grained tokens → only repository access = `VainV6/Vain`,
   Permissions → Repository → **Contents: Read-only**. Copy it.

3. **Install & log in** (from this `server/` dir):
   ```sh
   npm i -g wrangler        # or: npx wrangler ...
   wrangler login
   ```

4. **Create the KV namespace** and paste its id into `wrangler.toml`:
   ```sh
   wrangler kv namespace create KEYS
   # -> copy the id into [[kv_namespaces]] id = "..."
   ```

5. **Set secrets** (never commit these):
   ```sh
   wrangler secret put GITHUB_PAT      # paste the fine-grained PAT
   wrangler secret put ADMIN_TOKEN     # paste any long random string
   ```

6. **Deploy:**
   ```sh
   wrangler deploy
   # note the URL, e.g. https://vain.YOURNAME.workers.dev
   ```

7. Put that URL into `entrypoint.lua` (`WORKER = ...`).

## Managing keys

```sh
export VAIN_WORKER=https://vain.YOURNAME.workers.dev
export VAIN_ADMIN_TOKEN=the-admin-token-you-set

node keys.mjs new --note "buyer alice" --days 30   # -> prints a new key
node keys.mjs info   vain_xxxxx                     # inspect (hwid, expiry...)
node keys.mjs revoke vain_xxxxx                     # kill a key
node keys.mjs reset-hwid vain_xxxxx                 # let a buyer move machines
```

Give each buyer `entrypoint.lua` with their `VAIN_KEY` filled in. The key binds
to the first machine's HWID; a leaked key won't work elsewhere until you
`reset-hwid`.

## Honest limits

An executor must be handed runnable Lua, so someone hooking `loadstring` /
`HttpGet` can still dump the delivered source. This setup stops **public
readability** (private repo, no raw URLs) and **casual copying/sharing** (key +
HWID), and lets you **revoke** access. For stronger protection, run the served
Lua through an obfuscator in the Worker before returning it (add a transform in
`ghFetch`'s response path).
