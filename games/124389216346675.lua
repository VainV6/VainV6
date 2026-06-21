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
-- The game's Network:FireServer round-robins four reliable RemoteEvents that sit
-- directly in ReplicatedStorage (RemoteEvent_1 .. _4); firing ANY of them runs the
-- same server handler. We fire one of these directly instead of
-- require(GetService)("Network"), which doesn't resolve from the exploit context
-- (that's why it reported NETWORK NOT FOUND).
local actionRemote
local function getActionRemote()
	if actionRemote and actionRemote.Parent then return actionRemote end
	for i = 1, 4 do
		local r = replicatedStorage:FindFirstChild('RemoteEvent_' .. i)
		if r and r:IsA('RemoteEvent') then actionRemote = r return r end
	end
	for _, r in replicatedStorage:GetChildren() do
		if r:IsA('RemoteEvent') and r.Name:find('^RemoteEvent_') then actionRemote = r return r end
	end
	return nil
end

-- Fire a server action (e.g. "DevelopTile", tile, "Tier", true) through the game's
-- action remote. Returns true if a remote was available.
local function fireAction(...)
	local r = getActionRemote()
	if not r then return false end
	local args = {...}
	pcall(function() r:FireServer(unpack(args)) end)
	return true
end

-- Every tile/region the local player owns: in workspace.Regions with a Country
-- attribute equal to the player's MyCountry. (We do NOT require a CityInfo child
-- -- that's the UI panel, not something on the tile, so requiring it matched zero
-- tiles, which is why upgrades did nothing.) Each owned tile is developable: its
-- DevelopTier (tax) and DefenceTier are what we raise. Re-evaluated each sweep so
-- tiles from newly captured countries are picked up automatically.
local function ownedTiles()
	local out = {}
	local regions = workspace:FindFirstChild('Regions')
	local myCountry = lplr:GetAttribute('MyCountry')
	if not (regions and myCountry) then return out, myCountry end
	for _, tile in regions:GetChildren() do
		if tile:GetAttribute('Country') == myCountry then
			table.insert(out, tile)
		end
	end
	return out, myCountry
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
				-- one-time diagnostic so a silent failure is obvious: did we find the
				-- action remote, what country are we, and how many tiles do we own?
				do
					local remote = getActionRemote()
					local tiles, myCountry = ownedTiles()
					notif('Auto Upgrade',
						(remote and 'Remote OK' or 'REMOTE NOT FOUND')
						.. '  |  country: ' .. tostring(myCountry)
						.. '  |  owned tiles: ' .. #tiles,
						7, (remote and #tiles > 0) and nil or 'warning')
				end
				task.spawn(function()
					repeat
						if getActionRemote() then
							local cities = ownedTiles()
							if Notify.Enabled and #cities > 0 then
								notif('Auto Upgrade', 'Upgrading ' .. #cities .. ' tiles...', 3)
							end
							for _, city in cities do
								if not AutoUpgrade.Enabled then break end
								-- fire "to max"; the server upgrades as much as you can
								-- afford and ignores it once a city is already maxed, so
								-- re-sweeping continues progress as money comes in.
								if UpTier.Enabled then
									fireAction('DevelopTile', city, 'Tier', true)
								end
								if UpDefence.Enabled then
									fireAction('DevelopTile', city, 'Def', true)
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
			-- the game exposes a ToggleAutoCapture action; pass the desired state
			fireAction('ToggleAutoCapture', callback)
		end,
		Tooltip = "Toggles the game's built-in auto-capture (keeps expanding into adjacent tiles). If it behaves like a pure toggle in-game, flip it once to sync."
	})
end)
