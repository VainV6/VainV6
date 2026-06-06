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

local function downloadFile(path, func)
	if not isfile(path) then
		local suc, res = pcall(function()
			return game:HttpGet('https://raw.githubusercontent.com/VainV6/Vain/'..readfile('newvain/profiles/commit.txt')..'/'..select(1, path:gsub('newvain/', '')), true)
		end)
		if not suc or res == '404: Not Found' then
			error(res)
		end
		if path:find('.lua') then
			res = '--This watermark is used to delete the file if its cached, remove it to make the file persist after vain updates.\n'..res
		end
		writefile(path, res)
	end
	return (func or readfile)(path)
end

-- Build a map of line number → module display name for a file's content
local function buildLineModuleMap(content)
	local allLines = {}
	for line in content:gmatch('[^\n]+') do
		table.insert(allLines, line)
	end

	-- First pass: find every CreateModule and its display Name
	local moduleStarts = {}
	for i, line in ipairs(allLines) do
		if line:find(':CreateModule%(') then
			for j = i, math.min(i + 8, #allLines) do
				local name = allLines[j]:match("Name%s*=%s*'([^']+)'")
				          or allLines[j]:match('Name%s*=%s*"([^"]+)"')
				if name then
					table.insert(moduleStarts, { line = i, name = name })
					break
				end
			end
		end
	end

	-- Second pass: each line belongs to the nearest preceding module declaration
	table.sort(moduleStarts, function(a, b) return a.line < b.line end)
	local lineModules = {}
	local mi = 1
	for i = 1, #allLines do
		while mi < #moduleStarts and i >= moduleStarts[mi + 1].line do
			mi = mi + 1
		end
		if moduleStarts[mi] and i >= moduleStarts[mi].line then
			lineModules[i] = moduleStarts[mi].name
		end
	end

	return lineModules, moduleStarts
end

-- Parse @@ hunk headers from a patch to get new-file line ranges
local function parsePatchRanges(patch)
	local ranges = {}
	for newStart, newCount in patch:gmatch('@@ %-%d+,%d+ %+(%d+),(%d+) @@') do
		local s = tonumber(newStart)
		local c = tonumber(newCount)
		if s and c and c > 0 then
			table.insert(ranges, { s, s + c - 1 })
		end
	end
	-- Also handle hunks like @@ -1 +1 @@ (no count means count=1)
	for newStart in patch:gmatch('@@ %-%d+ %+(%d+) @@') do
		local s = tonumber(newStart)
		if s then table.insert(ranges, { s, s }) end
	end
	return ranges
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

local function detectUpdates()
	pcall(function()
		if not isfile('newvain/profiles/commit.txt') then return end
		local commit = readfile('newvain/profiles/commit.txt'):match('^%s*(.-)%s*$')

		local prevCommit = isfile('newvain/profiles/prev_commit.txt')
		                   and readfile('newvain/profiles/prev_commit.txt'):match('^%s*(.-)%s*$')
		                   or nil

		-- Always record this commit as the last-seen one for next session
		writefile('newvain/profiles/prev_commit.txt', commit)

		-- First run or already up to date — nothing to do
		if not prevCommit or prevCommit == '' or prevCommit == commit then return end

		-- ── Fetch GitHub compare ─────────────────────────────────────────────
		local compareUrl = 'https://api.github.com/repos/VainV6/Vain/compare/'
		                   ..prevCommit..'...'..commit
		local ok, res = pcall(game.HttpGet, game, compareUrl, true)
		if not ok or not res or res:sub(1, 1) ~= '{' then return end

		local parsed
		ok, parsed = pcall(httpService.JSONDecode, httpService, res)
		if not ok or not parsed then return end

		-- ── Detect changed modules ────────────────────────────────────────────
		local changed = {}

		if parsed.files then
			for _, file in ipairs(parsed.files) do
				if not file.filename:match('^games/') then continue end
				if not file.patch then continue end

				local rawUrl = 'https://raw.githubusercontent.com/VainV6/Vain/'
				               ..commit..'/'..file.filename
				local fileOk, fileContent = pcall(game.HttpGet, game, rawUrl, true)
				if not fileOk or not fileContent or fileContent == '404: Not Found' then continue end

				local lineModules = buildLineModuleMap(fileContent)
				local newMods = detectNewModulesFromPatch(file.patch)
				local ranges = parsePatchRanges(file.patch)

				for _, range in ipairs(ranges) do
					for lineNum = range[1], range[2] do
						local modName = lineModules[lineNum]
						if modName then
							local tag = newMods[modName] and 'NEW' or 'UPD'
							if not changed[modName] or tag == 'NEW' then
								changed[modName] = tag
							end
						end
					end
				end
			end
		end

		applyBadges(changed)

		-- ── Update notification (after module detection so we have counts) ────
		if not vain then return end
		local numCommits = parsed.commits and #parsed.commits or 0
		local newCount, updCount = 0, 0
		for _, tag in changed do
			if tag == 'NEW' then newCount += 1 else updCount += 1 end
		end

		-- Headline: latest commit message (first line only)
		local headline = ''
		if numCommits > 0 then
			local latest = parsed.commits[numCommits]
			headline = (latest and latest.commit and latest.commit.message or ''):match('^([^\n]+)') or ''
		end

		-- Build notification body
		local parts = {}
		if headline ~= '' then table.insert(parts, headline) end
		if numCommits > 1 then
			table.insert(parts, numCommits..' commits since last session')
		end
		if newCount > 0 or updCount > 0 then
			local modLine = ''
			if newCount > 0 then modLine = newCount..' new module'..(newCount > 1 and 's' or '') end
			if updCount > 0 then
				if modLine ~= '' then modLine = modLine..', ' end
				modLine = modLine..updCount..' updated'
			end
			table.insert(parts, modLine)
		end

		local body = table.concat(parts, '\n')
		if body == '' then body = 'See GitHub for details' end
		vain:CreateNotification('Vain Updated', body, 18)
	end)
end

local function finishLoading()
	vain.Init = nil
	detectUpdates()
	vain:Load()
	task.spawn(function()
		repeat
			vain:Save()
			task.wait(10)
		until not vain.Loaded
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

	if not shared.vainreload then
		if not vain.Categories then return end
		if vain.Categories.Main.Options['GUI bind indicator'].Enabled then
			vain:CreateNotification('Finished Loading', 'Press '..table.concat(vain.Keybind, ' + '):upper()..' to open GUI', 5)
		end
	end
end

if not isfile('newvain/profiles/gui.txt') then
	writefile('newvain/profiles/gui.txt', 'new')
end
local gui = 'new'

if not isfolder('newvain/assets/'..gui) then
	makefolder('newvain/assets/'..gui)
end
local guiLoader = loadstring(downloadFile('newvain/guis/'..gui..'.lua'), 'gui')
vain = guiLoader and guiLoader()
shared.vain = vain

if not shared.VainIndependent then
	local universalLoader = loadstring(downloadFile('newvain/games/universal.lua'), 'universal')
	if universalLoader then universalLoader() end
	if isfile('newvain/games/'..game.PlaceId..'.lua') then
		local gameLoader = loadstring(readfile('newvain/games/'..game.PlaceId..'.lua'), tostring(game.PlaceId))
		if gameLoader then gameLoader() end
	else
		if not shared.VainDeveloper then
			local suc, res = pcall(function()
				return game:HttpGet('https://raw.githubusercontent.com/VainV6/Vain/'..readfile('newvain/profiles/commit.txt')..'/games/'..game.PlaceId..'.lua', true)
			end)
			if suc and res ~= '404: Not Found' then
				local gameLoader = loadstring(downloadFile('newvain/games/'..game.PlaceId..'.lua'), tostring(game.PlaceId))
				if gameLoader then gameLoader() end
			end
		end
	end
	finishLoading()
else
	vain.Init = finishLoading
	return vain
end
