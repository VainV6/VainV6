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

-- Live money + manpower for a country, read straight off ReplicatedStorage.
-- CountryRegistry.<country>.Money/.Manpower (the same values the topbar shows).
local countryRegistry
local function countryFolder(country)
	if not countryRegistry then
		countryRegistry = replicatedStorage:FindFirstChild('CountryRegistry')
	end
	return countryRegistry and countryRegistry:FindFirstChild(country) or nil
end
local function getBalance(country)
	local cf = countryFolder(country)
	if not cf then return nil, nil end
	local m = cf:FindFirstChild('Money')
	local p = cf:FindFirstChild('Manpower')
	return m and m.Value or nil, p and p.Value or nil
end

-- Exact per-LEVEL upgrade cost, replicated from the game's client-side
-- GetUpgradeTileCost (Line 939). DevelopTier maxes at 10, DefenceTier at 10.
--   base = DefaultPopulation * (1 + DevelopTier * mult)
--   Tier (develop) one level : money = base * 10 * DevelopTier^2
--   Def  (defence) one level : money = base * 25 * DefenceTier^2,
--                              manpower = DefenceTier^2 * 2000
local function tileCosts(tile)
	local pop = tile:GetAttribute('DefaultPopulation')
	if not pop or pop <= 0 then return nil end
	local devTier = tile:GetAttribute('DevelopTier') or 1
	local defTier = tile:GetAttribute('DefenceTier') or 1
	local mult = pop < 100000 and 0.415 or (pop < 200000 and 0.285 or (pop < 350000 and 0.215 or 0.1))
	local base = pop * (1 + devTier * mult)
	return {
		devTier = devTier,
		defTier = defTier,
		tierMoney = base * 10 * (devTier * devTier),
		defMoney = base * 25 * (defTier * defTier),
		defManpower = (defTier * defTier) * 2000,
	}
end

-- ══════════════════════════════════════════════════════════════════════════════
--  AUTO UPGRADE  (cheapest-first, affordability-checked, with money/manpower reserve)
-- ══════════════════════════════════════════════════════════════════════════════
run(function()
	local AutoUpgrade
	local UpTier, UpDefence, MoneyReserve, ManpowerReserve, Interval, Notify

	-- One sweep: build every affordable single-level upgrade across owned tiles,
	-- upgrade the CHEAPEST first, and never let money/manpower drop below reserve.
	local function sweep()
		local myCountry = lplr:GetAttribute('MyCountry')
		if not (myCountry and getActionRemote()) then return end

		local moneyReserve = (MoneyReserve.Value or 0) * 1e6
		local mpReserve = (ManpowerReserve.Value or 0) * 1e3

		-- collect candidate single-level upgrades with their exact cost
		local candidates = {}
		for _, tile in ownedTiles() do
			local c = tileCosts(tile)
			if c then
				if UpTier.Enabled and c.devTier < 10 then
					table.insert(candidates, { tile = tile, kind = 'Tier', money = c.tierMoney, mp = 0 })
				end
				if UpDefence.Enabled and c.defTier < 10 then
					table.insert(candidates, { tile = tile, kind = 'Def', money = c.defMoney, mp = c.defManpower })
				end
			end
		end
		-- cheapest first
		table.sort(candidates, function(a, b) return a.money < b.money end)

		local fired = 0
		for _, c in candidates do
			if not AutoUpgrade.Enabled then break end
			local money, mp = getBalance(myCountry)
			if not money then break end
			-- only fire if it still leaves the reserve untouched (affordability + reserve)
			if money - c.money >= moneyReserve and (mp or math.huge) - c.mp >= mpReserve then
				fireAction('DevelopTile', c.tile, c.kind)
				fired = fired + 1
				task.wait(0.12)
			end
		end
		if Notify.Enabled and fired > 0 then
			notif('Auto Upgrade', 'Upgraded ' .. fired .. ' levels (cheapest first)', 3)
		end
	end

	AutoUpgrade = vain.Categories.Utility:CreateModule({
		Name = 'Auto Upgrade',
		Function = function(callback)
			if callback then
				-- one-time diagnostic so a silent failure is obvious
				do
					local remote = getActionRemote()
					local tiles, myCountry = ownedTiles()
					local money = select(1, getBalance(myCountry))
					notif('Auto Upgrade',
						(remote and 'Remote OK' or 'REMOTE NOT FOUND')
						.. '  |  ' .. tostring(myCountry)
						.. '  |  tiles: ' .. #tiles
						.. '  |  money: ' .. (money and string.format('%.1fm', money / 1e6) or '?'),
						7, (remote and #tiles > 0) and nil or 'warning')
				end
				task.spawn(function()
					repeat
						sweep()
						task.wait(Interval and Interval.Value or 5)
					until not AutoUpgrade.Enabled
				end)
			end
		end,
		Tooltip = 'Upgrades the tax tier and defence of every tile you own, cheapest first, only when you can afford it -- and always keeps your money/manpower reserve untouched. New tiles from captured countries are included automatically.'
	})

	UpTier = AutoUpgrade:CreateToggle({
		Name = 'Tax Tier',
		Default = true,
		Tooltip = "Upgrade each owned tile's tax / develop tier (max 10)."
	})
	UpDefence = AutoUpgrade:CreateToggle({
		Name = 'Defence',
		Default = true,
		Tooltip = "Upgrade each owned tile's defence tier (max 10). Costs money + manpower."
	})
	MoneyReserve = AutoUpgrade:CreateSlider({
		Name = 'Money Reserve',
		Min = 0,
		Max = 500,
		Default = 5,
		Suffix = 'M',
		Tooltip = 'Never spend below this much money -- an upgrade is skipped if it would drop you under the reserve.'
	})
	ManpowerReserve = AutoUpgrade:CreateSlider({
		Name = 'Manpower Reserve',
		Min = 0,
		Max = 1000,
		Default = 20,
		Suffix = 'K',
		Tooltip = 'Never spend manpower below this -- defence upgrades are skipped if they would drop you under it.'
	})
	Interval = AutoUpgrade:CreateSlider({
		Name = 'Interval',
		Min = 1,
		Max = 30,
		Default = 5,
		Suffix = 'sec',
		Tooltip = 'How often to re-sweep -- catches newly captured tiles and continues upgrading once income tops you back up.'
	})
	Notify = AutoUpgrade:CreateToggle({
		Name = 'Notify',
		Default = false,
		Tooltip = 'Notify each sweep with how many levels were upgraded.'
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
