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

local function applyModuleIndicators()
	pcall(function()
		local content
		if isfile('newvain/changed_modules.txt') then
			content = readfile('newvain/changed_modules.txt')
		elseif isfile('newvain/profiles/commit.txt') then
			local res = game:HttpGet('https://raw.githubusercontent.com/VainV6/Vain/'..readfile('newvain/profiles/commit.txt')..'/changed_modules.txt', true)
			if res ~= '404: Not Found' then content = res end
		end
		if not content or not vain then return end
		for line in content:gmatch('[^\n]+') do
			local tag, name = line:match('^([A-Z]+):(.+)$')
			if tag and name then
				local mod = vain.Modules[name]
				if mod then
					local t = tag
					mod.ExtraText = function() return t end
					if mod.Object then
						mod.Object.RichText = true
						local tagColor = tag == 'NEW' and '#5AFF5A' or '#FFD95A'
						mod.Object.Text = mod.Object.Text.." <font color='"..tagColor.."' size='11'>["..tag.."]</font>"
					end
				end
			end
		end
	end)
end

local function finishLoading()
	vain.Init = nil
	applyModuleIndicators()
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
