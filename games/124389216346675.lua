-- Vain :: Control Europe (124389216346675)
-- Grand-strategy map game. Tiles/regions live in workspace.Regions; a tile is a
-- city if it has a CityInfo child, and is owned when its 'Country' attribute
-- equals the local player's 'MyCountry'. Tiles carry DevelopTier (tax/city tier)
-- and DefenceTier. Actions go through a single Network service obtained from
-- ReplicatedStorage.GetService("Network"); upgrades are
--   Network:FireServer("DevelopTile", tile, "Tier", true)  -- tax tier to max
--   Network:FireServer("DevelopTile", tile, "Def",  true)  -- defence to max
-- (decoded from the decompiled CityInfo / MultiUpgrade UI in the place file).

local run = function(func)
	local suc, err = pcall(func)
	if not suc then
		local vain = shared.vain
		if vain and vain.CreateNotification then
			vain:CreateNotification('Vain Control Europe', 'Failure executing function: ' .. tostring(err), 3)
		end
	end
end
local cloneref = cloneref or function(obj) return obj end

local playersService = cloneref(game:GetService('Players'))
local runService = cloneref(game:GetService('RunService'))
local replicatedStorage = cloneref(game:GetService('ReplicatedStorage'))

local lplr = playersService.LocalPlayer
local vain = shared.vain

local function notif(title, text, duration, kind)
	return vain:CreateNotification(title, text, duration or 4, kind)
end

-- The game's service locator: require(ReplicatedStorage.GetService)("Network")
-- returns the Network object that all client actions fire through. Resolve it
-- lazily and cache it so a slow load can't break the file.
local Network
local function getNetwork()
	if Network and typeof(Network) == 'table' then return Network end
	local ok, gs = pcall(function()
		return require(replicatedStorage:WaitForChild('GetService', 10))
	end)
	if ok and gs then
		local ok2, net = pcall(gs, 'Network')
		if ok2 then Network = net end
	end
	return Network
end

-- Every CITY tile the local player owns: in workspace.Regions, has a CityInfo
-- child, and its Country attribute matches the player's MyCountry. Re-evaluated
-- each sweep so cities from newly captured countries are picked up automatically.
local function ownedCities()
	local out = {}
	local regions = workspace:FindFirstChild('Regions')
	local myCountry = lplr:GetAttribute('MyCountry')
	if not (regions and myCountry) then return out end
	for _, tile in regions:GetChildren() do
		if tile:GetAttribute('Country') == myCountry and tile:FindFirstChild('CityInfo') then
			table.insert(out, tile)
		end
	end
	return out
end

-- ══════════════════════════════════════════════════════════════════════════════
--  AUTO UPGRADE  (max the tax tier + defence of every owned city)
-- ══════════════════════════════════════════════════════════════════════════════
run(function()
	local AutoUpgrade
	local UpTier, UpDefence, Interval, Notify

	AutoUpgrade = vain.Categories.Utility:CreateModule({
		Name = 'Auto Upgrade',
		Function = function(callback)
			if callback then
				task.spawn(function()
					repeat
						local net = getNetwork()
						if net and net.FireServer then
							local cities = ownedCities()
							if Notify.Enabled and #cities > 0 then
								notif('Auto Upgrade', 'Upgrading ' .. #cities .. ' cities...', 3)
							end
							for _, city in cities do
								if not AutoUpgrade.Enabled then break end
								-- fire "to max"; the server upgrades as much as you can
								-- afford and ignores it once a city is already maxed, so
								-- re-sweeping continues progress as money comes in.
								if UpTier.Enabled then
									pcall(function() net:FireServer('DevelopTile', city, 'Tier', true) end)
								end
								if UpDefence.Enabled then
									pcall(function() net:FireServer('DevelopTile', city, 'Def', true) end)
								end
								task.wait(0.08)
							end
						end
						task.wait(Interval and Interval.Value or 5)
					until not AutoUpgrade.Enabled
				end)
			end
		end,
		Tooltip = 'Automatically upgrades the tax tier and defence of every city you own to max (as fast as you can afford). Cities from countries you capture are picked up automatically on the next sweep.'
	})

	UpTier = AutoUpgrade:CreateToggle({
		Name = 'Tax Tier',
		Default = true,
		Tooltip = "Upgrade each owned city's tax / city tier to max."
	})
	UpDefence = AutoUpgrade:CreateToggle({
		Name = 'Defence',
		Default = true,
		Tooltip = "Upgrade each owned city's defence tier to max."
	})
	Interval = AutoUpgrade:CreateSlider({
		Name = 'Interval',
		Min = 1,
		Max = 30,
		Default = 5,
		Suffix = 'sec',
		Tooltip = 'How often to re-sweep your cities -- catches newly captured cities and continues upgrades once you can afford more.'
	})
	Notify = AutoUpgrade:CreateToggle({
		Name = 'Notify',
		Default = false,
		Tooltip = 'Show a notification each sweep with how many cities are being upgraded.'
	})
end)

-- ══════════════════════════════════════════════════════════════════════════════
--  AUTO CAPTURE  (toggle the game's built-in auto-capture)
-- ══════════════════════════════════════════════════════════════════════════════
run(function()
	local AutoCapture
	AutoCapture = vain.Categories.Utility:CreateModule({
		Name = 'Auto Capture',
		Function = function(callback)
			local net = getNetwork()
			if net and net.FireServer then
				-- the game exposes a ToggleAutoCapture action; pass the desired state
				pcall(function() net:FireServer('ToggleAutoCapture', callback) end)
			end
		end,
		Tooltip = "Toggles the game's built-in auto-capture (keeps expanding into adjacent tiles). If it behaves like a pure toggle in-game, flip it once to sync."
	})
end)
