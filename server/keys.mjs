#!/usr/bin/env node
/**
 * Vain key admin CLI. Talks to the Worker's /admin routes with ADMIN_TOKEN.
 *
 * Set once:
 *   export VAIN_WORKER=https://vain.YOURNAME.workers.dev
 *   export VAIN_ADMIN_TOKEN=xxxxx
 *
 * Usage:
 *   node keys.mjs new [--note "buyer name"] [--days 30]
 *   node keys.mjs new --key custom_key_123
 *   node keys.mjs info <key>
 *   node keys.mjs revoke <key>
 *   node keys.mjs reset-hwid <key>
 */

const WORKER = process.env.VAIN_WORKER;
const TOKEN = process.env.VAIN_ADMIN_TOKEN;
if (!WORKER || !TOKEN) {
	console.error("Set VAIN_WORKER and VAIN_ADMIN_TOKEN env vars first.");
	process.exit(1);
}

const H = { authorization: `Bearer ${TOKEN}`, "content-type": "application/json" };
const [, , cmd, ...rest] = process.argv;

function arg(name) {
	const i = rest.indexOf(`--${name}`);
	return i >= 0 ? rest[i + 1] : null;
}

async function main() {
	if (cmd === "new") {
		const body = {};
		if (arg("note")) body.note = arg("note");
		if (arg("key")) body.key = arg("key");
		if (arg("days")) body.expires = Date.now() + Number(arg("days")) * 86400000;
		const r = await fetch(`${WORKER}/admin/keys`, { method: "POST", headers: H, body: JSON.stringify(body) });
		console.log(JSON.stringify(await r.json(), null, 2));
	} else if (cmd === "info") {
		const r = await fetch(`${WORKER}/admin/keys/${rest[0]}`, { headers: H });
		console.log(JSON.stringify(await r.json(), null, 2));
	} else if (cmd === "revoke") {
		const r = await fetch(`${WORKER}/admin/keys/${rest[0]}`, { method: "DELETE", headers: H });
		console.log(JSON.stringify(await r.json(), null, 2));
	} else if (cmd === "reset-hwid") {
		const r = await fetch(`${WORKER}/admin/keys/${rest[0]}/reset-hwid`, { method: "POST", headers: H });
		console.log(JSON.stringify(await r.json(), null, 2));
	} else {
		console.log("commands: new | info <key> | revoke <key> | reset-hwid <key>");
	}
}
main();
