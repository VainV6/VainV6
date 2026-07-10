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

	-- The whitelist check, update detection, and the welcome notification each
	-- make blocking HTTP round-trips. Running them synchronously here froze the
	-- screen for seconds on inject, so defer them to a background thread; the
	-- GUI is already interactive by the time these finish.
	task.spawn(function()
		detectUpdates()
		if not shared.vainreload then
			if not vain.Categories then return end
			if vain.Categories.Main.Options['GUI bind indicator'].Enabled then
				vain:CreateNotification(
					'[VAIN] Finished Loading',
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
