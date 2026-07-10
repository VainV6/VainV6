/**
 * Vain delivery + auth Worker.
 *
 * Fronts the PRIVATE GitHub repo VainV6/Vain. The GitHub PAT lives only here
 * (as the GITHUB_PAT secret) and never reaches the client. Every request is
 * gated by a per-user key + HWID lock stored in the KEYS KV namespace.
 *
 * Client contract (the loadstring users run) sends the key + HWID on EVERY
 * request via headers (or query), because the executor makes many file fetches:
 *   X-Vain-Key : the user's key
 *   X-Vain-Hwid: a stable per-machine id (e.g. gethwid()/identifyexecutor hash)
 *
 * Path shape mirrors raw.githubusercontent.com so the Lua only swaps the host:
 *   GET https://<worker>/<ref>/<path...>     -> file at that ref
 *   GET https://<worker>/sha                  -> latest main commit sha (plain)
 * Admin (Bearer ADMIN_TOKEN):
 *   POST /admin/keys           {key?, note?, expires?}  -> create/return a key
 *   GET  /admin/keys/<key>                              -> inspect a key
 *   DELETE /admin/keys/<key>                            -> revoke a key
 *   POST /admin/keys/<key>/reset-hwid                   -> unbind HWID (transfer)
 */

const GH_API = "https://api.github.com";
const REPO = "VainV6/Vain";

function json(obj, status = 200, extra = {}) {
	return new Response(JSON.stringify(obj), {
		status,
		headers: { "content-type": "application/json; charset=utf-8", ...extra },
	});
}

// A Lua stub returned on auth failure so the executor shows a clear message
// instead of running garbage. loadstring() of this errors politely.
function denyLua(reason) {
	const safe = String(reason).replace(/([\\"'\n])/g, "\\$1");
	return new Response(
		`error("[Vain] access denied: ${safe}")\n`,
		{ status: 403, headers: { "content-type": "text/plain; charset=utf-8" } }
	);
}

async function ghFetch(env, path, { raw = false, ref = "main" } = {}) {
	// Contents API with raw accept returns the file body directly.
	const url = `${GH_API}/repos/${REPO}/contents/${path}?ref=${encodeURIComponent(ref)}`;
	const res = await fetch(url, {
		headers: {
			Authorization: `Bearer ${env.GITHUB_PAT}`,
			Accept: raw ? "application/vnd.github.raw" : "application/vnd.github+json",
			"User-Agent": "vain-worker",
		},
		cf: { cacheTtl: 30, cacheEverything: true },
	});
	return res;
}

async function latestSha(env) {
	const res = await fetch(`${GH_API}/repos/${REPO}/commits/main`, {
		headers: {
			Authorization: `Bearer ${env.GITHUB_PAT}`,
			Accept: "application/vnd.github+json",
			"User-Agent": "vain-worker",
		},
		cf: { cacheTtl: 15, cacheEverything: true },
	});
	if (!res.ok) return null;
	const data = await res.json();
	return data && data.sha ? data.sha : null;
}

// ---- key + HWID auth -------------------------------------------------------

function getCreds(req, url) {
	const key =
		req.headers.get("x-vain-key") ||
		url.searchParams.get("key") ||
		"";
	const hwid =
		req.headers.get("x-vain-hwid") ||
		url.searchParams.get("hwid") ||
		"";
	return { key: key.trim(), hwid: hwid.trim() };
}

// Returns { ok:true } or { ok:false, reason }
async function checkAuth(env, key, hwid) {
	if (!key) return { ok: false, reason: "no key" };
	const raw = await env.KEYS.get(`key:${key}`);
	if (!raw) return { ok: false, reason: "invalid key" };

	let rec;
	try { rec = JSON.parse(raw); } catch { return { ok: false, reason: "corrupt key record" }; }

	if (rec.revoked) return { ok: false, reason: "key revoked" };
	if (rec.expires && Date.now() > rec.expires) return { ok: false, reason: "key expired" };

	// HWID lock: bind on first use, enforce thereafter.
	if (!hwid) return { ok: false, reason: "no hwid" };
	if (!rec.hwid) {
		rec.hwid = hwid;
		rec.boundAt = Date.now();
		await env.KEYS.put(`key:${key}`, JSON.stringify(rec));
	} else if (rec.hwid !== hwid) {
		return { ok: false, reason: "hwid mismatch (key locked to another machine)" };
	}

	rec.lastSeen = Date.now();
	// Fire-and-forget lastSeen update (don't block the response).
	env.KEYS.put(`key:${key}`, JSON.stringify(rec));
	return { ok: true, rec };
}

// ---- admin -----------------------------------------------------------------

function randomKey() {
	const bytes = crypto.getRandomValues(new Uint8Array(18));
	const b64 = btoa(String.fromCharCode(...bytes)).replace(/[+/=]/g, "");
	return `vain_${b64}`;
}

async function handleAdmin(req, env, url) {
	const auth = req.headers.get("authorization") || "";
	if (auth !== `Bearer ${env.ADMIN_TOKEN}`) return json({ error: "unauthorized" }, 401);

	const parts = url.pathname.split("/").filter(Boolean); // ["admin","keys",...]
	const sub = parts[1];

	if (sub === "keys") {
		const key = parts[2];
		const action = parts[3];

		if (req.method === "POST" && !key) {
			// create a key
			let body = {};
			try { body = await req.json(); } catch {}
			const newKey = (body.key && String(body.key).trim()) || randomKey();
			const rec = {
				created: Date.now(),
				note: body.note || "",
				expires: body.expires ? Number(body.expires) : null,
				hwid: null,
				revoked: false,
			};
			await env.KEYS.put(`key:${newKey}`, JSON.stringify(rec));
			return json({ key: newKey, ...rec });
		}

		if (req.method === "GET" && key) {
			const raw = await env.KEYS.get(`key:${key}`);
			if (!raw) return json({ error: "not found" }, 404);
			return json({ key, ...JSON.parse(raw) });
		}

		if (req.method === "DELETE" && key) {
			const raw = await env.KEYS.get(`key:${key}`);
			if (!raw) return json({ error: "not found" }, 404);
			const rec = JSON.parse(raw);
			rec.revoked = true;
			await env.KEYS.put(`key:${key}`, JSON.stringify(rec));
			return json({ key, revoked: true });
		}

		if (req.method === "POST" && key && action === "reset-hwid") {
			const raw = await env.KEYS.get(`key:${key}`);
			if (!raw) return json({ error: "not found" }, 404);
			const rec = JSON.parse(raw);
			rec.hwid = null;
			rec.boundAt = null;
			await env.KEYS.put(`key:${key}`, JSON.stringify(rec));
			return json({ key, hwid: null });
		}
	}

	return json({ error: "bad admin request" }, 400);
}

// ---- main router -----------------------------------------------------------

export default {
	async fetch(req, env, ctx) {
		const url = new URL(req.url);

		if (url.pathname.startsWith("/admin/")) {
			return handleAdmin(req, env, url);
		}

		const { key, hwid } = getCreds(req, url);
		const auth = await checkAuth(env, key, hwid);
		if (!auth.ok) return denyLua(auth.reason);

		// /sha -> latest commit sha (plain text), used to pin downloads.
		if (url.pathname === "/sha" || url.pathname === "/sha/") {
			const sha = await latestSha(env);
			if (!sha) return new Response("main", { headers: { "content-type": "text/plain" } });
			return new Response(sha, { headers: { "content-type": "text/plain; charset=utf-8" } });
		}

		// /<ref>/<path...>  -> file body at that ref.
		const segs = url.pathname.split("/").filter(Boolean);
		if (segs.length < 2) return denyLua("bad path");
		const ref = segs[0];
		const path = segs.slice(1).join("/");

		const res = await ghFetch(env, path, { raw: true, ref });
		if (!res.ok) {
			return new Response(`-- [Vain] fetch failed (${res.status}) for ${path}\n`, {
				status: res.status,
				headers: { "content-type": "text/plain; charset=utf-8" },
			});
		}
		const body = await res.arrayBuffer();
		return new Response(body, {
			headers: {
				"content-type": "text/plain; charset=utf-8",
				"cache-control": "no-store",
			},
		});
	},
};
