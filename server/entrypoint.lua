--[[
	Vain entrypoint (the ONLY script users receive).

	Put your key in VAIN_KEY below. This authenticates to the Vain delivery
	Worker with your key + this machine's HWID, then boots Vain. The actual
	source lives in a PRIVATE repo and is served only to authorized keys.

	It works by transparently redirecting every Vain file fetch
	(raw.githubusercontent.com/VainV6/Vain/...) to the Worker, injecting the
	key + HWID headers -- so the rest of Vain needs no changes.
]]

local VAIN_KEY = "PASTE-YOUR-KEY-HERE"
local WORKER   = "https://vain.YOURNAME.workers.dev" -- your Worker URL, no trailing slash

-- ── stable per-machine id ───────────────────────────────────────────────────
local function getHwid()
	local id
	local ok = pcall(function()
		if gethwid then id = gethwid()
		elseif get_hwid then id = get_hwid()
		elseif syn and syn.get_hwid then id = syn.get_hwid() end
	end)
	if (not ok or not id) then
		-- Fallback: RobloxLocked client id + player id. Weaker but stable per install.
		pcall(function()
			id = tostring(game:GetService("RbxAnalyticsService"):GetClientId())
		end)
	end
	if not id or id == "" then
		id = tostring(game:GetService("Players").LocalPlayer.UserId) .. "-nohwid"
	end
	return tostring(id)
end

local HWID = getHwid()
local req = (syn and syn.request) or (http and http.request) or request or (fluxus and fluxus.request)

-- Authenticated GET against the Worker. `refPath` is "<ref>/<path>" or "sha".
local function workerGet(refPath)
	if req then
		local ok, r = pcall(req, {
			Url = WORKER .. "/" .. refPath,
			Method = "GET",
			Headers = { ["X-Vain-Key"] = VAIN_KEY, ["X-Vain-Hwid"] = HWID },
		})
		if ok and r and (r.StatusCode == 200 or r.Success) then return r.Body end
		if ok and r and r.Body then return nil, r.Body end -- surface deny reason
		return nil
	end
	-- No request(): fall back to HttpGet with the creds in the query string.
	local ok, body = pcall(function()
		return game:HttpGet(WORKER .. "/" .. refPath ..
			(refPath:find("?") and "&" or "?") ..
			"key=" .. VAIN_KEY .. "&hwid=" .. HWID, true)
	end)
	if ok then return body end
	return nil
end

-- ── redirect Vain's raw fetches through the Worker ──────────────────────────
-- init.lua / game files call game:HttpGet("https://raw.githubusercontent.com/
-- VainV6/Vain/<ref>/<path>"). We hook HttpGet so those go to the Worker with the
-- key+HWID headers; every other HttpGet passes through untouched.
local RAW = "https://raw.githubusercontent.com/VainV6/Vain/"
local API_COMMITS = "https://api.github.com/repos/VainV6/Vain/commits/main"
local INFO_REFS = "https://github.com/VainV6/Vain/info/refs"

if not getgenv().__vainHttpHooked then
	getgenv().__vainHttpHooked = true
	local mt = getrawmetatable(game)
	local oldNamecall = mt.__namecall
	setreadonly(mt, false)
	mt.__namecall = newcclosure(function(self, ...)
		local method = getnamecallmethod()
		if self == game and (method == "HttpGet" or method == "HttpGetAsync") then
			local args = { ... }
			local u = args[1]
			if type(u) == "string" then
				if u:sub(1, #RAW) == RAW then
					local refPath = u:sub(#RAW + 1)         -- "<ref>/<path>"
					local body = workerGet(refPath)
					if body then return body end
					error("[Vain] authorized fetch failed for " .. refPath)
				elseif u:sub(1, #API_COMMITS) == API_COMMITS then
					-- SHA resolution -> Worker /sha (returns plain sha)
					local sha = workerGet("sha")
					if sha then return '"sha":"' .. sha .. '"' end
				elseif u:sub(1, #INFO_REFS) == INFO_REFS then
					local sha = workerGet("sha")
					if sha then return sha .. " refs/heads/main" end
				end
			end
		end
		return oldNamecall(self, ...)
	end)
	setreadonly(mt, true)
end

-- ── preflight the key, then boot ────────────────────────────────────────────
local boot, deny = workerGet("main/init.lua")
if not boot then
	warn("[Vain] " .. (deny or "could not reach the delivery server / key rejected"))
	return
end
loadstring(boot, "=vain/init")()
