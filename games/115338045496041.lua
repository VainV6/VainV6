-- Vain :: Control Europe (115338045496041)
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

-- ══════════════════════════════════════════════════════════════════════════════
--  shared helpers for intel / diplomacy
-- ══════════════════════════════════════════════════════════════════════════════
-- compact big-number formatting: 1.23B / 45.6M / 12.3K / 980
local function fmtNum(n)
	if not n then return '?' end
	local a = math.abs(n)
	if a >= 1e9 then return string.format('%.2fB', n / 1e9) end
	if a >= 1e6 then return string.format('%.2fM', n / 1e6) end
	if a >= 1e3 then return string.format('%.1fK', n / 1e3) end
	return tostring(math.floor(n))
end
local function cfValue(cf, name)
	local c = cf and cf:FindFirstChild(name)
	return c and c.Value or nil
end
-- every country's live stats (money/manpower/pop/tiles), sorted by money desc
local function allCountryStats()
	local reg = replicatedStorage:FindFirstChild('CountryRegistry')
	local list = {}
	if reg then
		for _, cf in reg:GetChildren() do
			table.insert(list, {
				name = cf.Name,
				money = cfValue(cf, 'Money') or 0,
				manpower = cfValue(cf, 'Manpower') or 0,
				population = cfValue(cf, 'Population') or 0,
				tiles = cfValue(cf, 'Tiles') or 0,
				atWar = cf:GetAttribute('AtWar'),
			})
		end
		table.sort(list, function(a, b) return a.money > b.money end)
	end
	return list
end

-- ══════════════════════════════════════════════════════════════════════════════
--  COUNTRY INTEL  (live ranked stats feed: top powers + your own standing)
-- ══════════════════════════════════════════════════════════════════════════════
run(function()
	local Intel, ShowMine, ShowTop, Interval

	local function report()
		local stats = allCountryStats()
		if #stats == 0 then
			notif('Country Intel', 'CountryRegistry not loaded yet.', 4, 'warning')
			return
		end
		local myCountry = lplr:GetAttribute('MyCountry')
		local dur = Interval and Interval.Value or 25

		if ShowTop.Enabled then
			local lines = {}
			for i = 1, math.min(5, #stats) do
				local s = stats[i]
				table.insert(lines, string.format('%d. %s  $%s  pop %s  %s tiles',
					i, s.name, fmtNum(s.money), fmtNum(s.population), fmtNum(s.tiles)))
			end
			notif('Top Powers', table.concat(lines, '\n'), dur)
		end

		if ShowMine.Enabled and myCountry then
			local rank, mine
			for i, s in stats do
				if s.name == myCountry then rank = i mine = s break end
			end
			if mine then
				notif('My Country (' .. myCountry .. ')', string.format(
					'Rank #%d by money\n$%s  |  %s manpower\npop %s  |  %s tiles%s',
					rank or 0, fmtNum(mine.money), fmtNum(mine.manpower), fmtNum(mine.population),
					fmtNum(mine.tiles), mine.atWar and '\nAT WAR' or ''), dur)
			end
		end
	end

	Intel = vain.Categories.Utility:CreateModule({
		Name = 'Country Intel',
		Function = function(callback)
			if callback then
				task.spawn(function()
					repeat
						report()
						task.wait(Interval and Interval.Value or 25)
					until not Intel.Enabled
				end)
			end
		end,
		Tooltip = 'Live strategic intel from CountryRegistry: the strongest powers (money / population / tiles) and your own standing & rank. Refreshes on an interval.'
	})
	ShowTop = Intel:CreateToggle({ Name = 'Top Powers', Default = true, Tooltip = 'Show the 5 strongest countries by money.' })
	ShowMine = Intel:CreateToggle({ Name = 'My Stats', Default = true, Tooltip = 'Show your country: money / manpower / population / tiles and global money rank.' })
	Interval = Intel:CreateSlider({ Name = 'Refresh', Min = 5, Max = 120, Default = 25, Suffix = 'sec', Tooltip = 'How often to refresh the intel feed.' })
end)

-- ══════════════════════════════════════════════════════════════════════════════
--  AUTO WAR  (justify + declare war on the countries you list)
-- ══════════════════════════════════════════════════════════════════════════════
run(function()
	local AutoWar, Targets, AutoDeclare, Interval

	local function atWarWith(name)
		-- best-effort: the target's AtWar attribute flips once a war involving it begins
		local reg = replicatedStorage:FindFirstChild('CountryRegistry')
		local cf = reg and reg:FindFirstChild(name)
		return (cf and cf:GetAttribute('AtWar') == true) or false
	end

	AutoWar = vain.Categories.Utility:CreateModule({
		Name = 'Auto War',
		Function = function(callback)
			if callback then
				task.spawn(function()
					repeat
						if getActionRemote() then
							for _, name in (Targets and Targets.ListEnabled or {}) do
								if not AutoWar.Enabled then break end
								if name ~= '' and not atWarWith(name) then
									fireAction('JustifyWar', name)
									task.wait(0.3)
									if AutoDeclare.Enabled then
										fireAction('DeclareWar', name)
									end
								end
							end
						end
						task.wait(Interval and Interval.Value or 8)
					until not AutoWar.Enabled
				end)
			end
		end,
		Tooltip = 'List exact country names to war. Auto War keeps justifying (and, if enabled, declaring) on each until you are at war with them. Justification still takes the normal in-game time.'
	})
	Targets = AutoWar:CreateTextList({ Name = 'Targets', Tooltip = 'Exact country names to declare war on (one per entry), e.g. Poland, France.' })
	AutoDeclare = AutoWar:CreateToggle({ Name = 'Auto Declare', Default = true, Tooltip = 'Also fire DeclareWar once justification allows it. Off = justify only.' })
	Interval = AutoWar:CreateSlider({ Name = 'Retry', Min = 2, Max = 60, Default = 8, Suffix = 'sec', Tooltip = 'How often to retry justify/declare until you are at war.' })
end)

-- ══════════════════════════════════════════════════════════════════════════════
--  AUTO DEFENSE  (garrison borders + reinforce tiles under attack -- never attacks)
-- ══════════════════════════════════════════════════════════════════════════════
-- Spawns troops via FireServer("CreateArmyOnTile", tile, unitType, count) ONLY on
-- tiles you own. Border tiles are found by position (an owned tile next to a
-- non-owned one), and tiles under attack are detected by the tile's "Fighting"
-- attribute (the red-outline combat you screenshotted). It never moves onto enemy
-- land and never declares war -- purely defensive.
run(function()
	local AutoDefense, UnitType, Garrison, DefendBattles, MoneyReserve, ManpowerReserve, Interval, Notify

	local function tilePos(t)
		-- region tiles are Folders; their geometry sits in a GeneratedRegion Model
		local geo = t:FindFirstChild('GeneratedRegion') or t
		local ok, p = pcall(function() return geo:GetPivot().Position end)
		if ok and p then return p end
		if geo:IsA('BasePart') then return geo.Position end
		local pp = geo:FindFirstChildWhichIsA('BasePart', true)
		return pp and pp.Position or nil
	end

	-- owned tiles that sit next to a non-owned tile (your frontier)
	local function borderTiles(myCountry)
		local regions = workspace:FindFirstChild('Regions')
		if not (regions and myCountry) then return {} end
		local all = {}
		for _, t in regions:GetChildren() do
			local p = tilePos(t)
			if p then
				table.insert(all, { tile = t, pos = p, mine = t:GetAttribute('Country') == myCountry })
			end
		end
		local borders = {}
		for _, o in all do
			if o.mine then
				-- nearest neighbour of any ownership vs nearest ENEMY neighbour:
				-- if an enemy tile is about as close as our closest neighbour, we border it
				local dAny, dEnemy = math.huge, math.huge
				for _, x in all do
					if x ~= o then
						local d = (o.pos - x.pos).Magnitude
						if d < dAny then dAny = d end
						if not x.mine and d < dEnemy then dEnemy = d end
					end
				end
				if dEnemy <= dAny * 1.5 then table.insert(borders, o.tile) end
			end
		end
		return borders
	end

	-- ── my soldiers ──────────────────────────────────────────────────────────
	-- Combat is flagged on the SOLDIER model ("Fighting"), not the tile. Soldier
	-- models carry a Country/COUNTRY attribute; we locate their workspace container
	-- once and cache it.
	local function soldierCountry(m) return m:GetAttribute('Country') or m:GetAttribute('COUNTRY') end
	local function isSoldier(m)
		return m:IsA('Model') and soldierCountry(m) ~= nil
			and (m:GetAttribute('Type') ~= nil or m:GetAttribute('TYPE') ~= nil
				or m:GetAttribute('MOVING') ~= nil or m:GetAttribute('Fighting') ~= nil
				or m:FindFirstChildWhichIsA('Humanoid') ~= nil)
	end
	local soldierContainer, lastContainerScan = nil, 0
	local function findSoldierContainer()
		if soldierContainer and soldierContainer.Parent then return soldierContainer end
		for _, name in { 'Misc', 'WorldCenter', 'Units', 'Soldiers', 'Armies', 'Military' } do
			local f = workspace:FindFirstChild(name)
			if f then
				for _, m in f:GetChildren() do
					if isSoldier(m) then soldierContainer = f return f end
				end
			end
		end
		-- expensive fallback, throttled to once every 15s
		if tick() - lastContainerScan >= 15 then
			lastContainerScan = tick()
			for _, m in workspace:GetDescendants() do
				if isSoldier(m) then soldierContainer = m.Parent return m.Parent end
			end
		end
		return nil
	end
	local function mySoldiers(myCountry)
		local cont = findSoldierContainer()
		local out = {}
		if cont then
			for _, m in cont:GetChildren() do
				if soldierCountry(m) == myCountry then table.insert(out, m) end
			end
		end
		return out
	end

	-- owned tiles where one of my soldiers is currently in combat
	local function attackedTiles(myCountry)
		local out, seen = {}, {}
		local regions = workspace:FindFirstChild('Regions')
		if not (regions and myCountry) then return out end
		local owned = {}
		for _, t in regions:GetChildren() do
			if t:GetAttribute('Country') == myCountry then
				local p = tilePos(t)
				if p then table.insert(owned, { tile = t, pos = p }) end
			end
		end
		for _, s in mySoldiers(myCountry) do
			if s:GetAttribute('Fighting') == true then
				local ok, sp = pcall(function() return s:GetPivot().Position end)
				if ok and sp then
					local best, bestD
					for _, o in owned do
						local d = (o.pos - sp).Magnitude
						if not bestD or d < bestD then bestD, best = d, o.tile end
					end
					if best and not seen[best] then seen[best] = true table.insert(out, best) end
				end
			end
		end
		return out
	end

	local function sweep()
		local myCountry = lplr:GetAttribute('MyCountry')
		if not (myCountry and getActionRemote()) then return end
		local moneyReserve = (MoneyReserve.Value or 0) * 1e6
		local mpReserve = (ManpowerReserve.Value or 0) * 1e3
		local unit = (UnitType and UnitType.Value) or 'Infantry'
		local garrison = math.floor(Garrison.Value)
		local reinforced, garrisoned = 0, 0

		local function canSpend()
			local m, p = getBalance(myCountry)
			if m and m <= moneyReserve then return false end
			if p and p <= mpReserve then return false end
			return true
		end
		local function spawn(tile, count)
			if tile:GetAttribute('SpawningArmy') ~= nil then return false end
			if not canSpend() then return false end
			fireAction('CreateArmyOnTile', tile, unit, count)
			task.wait(0.15)
			return true
		end

		-- 1) emergency: reinforce any owned tile under attack
		if DefendBattles.Enabled then
			for _, t in fightingTiles(myCountry) do
				if not AutoDefense.Enabled then break end
				if spawn(t, garrison) then reinforced = reinforced + 1 end
			end
		end
		-- 2) garrison the frontier
		for _, t in borderTiles(myCountry) do
			if not AutoDefense.Enabled then break end
			if spawn(t, garrison) then garrisoned = garrisoned + 1 end
		end

		if Notify.Enabled and (reinforced + garrisoned) > 0 then
			notif('Auto Defense', string.format('Reinforced %d battle(s), garrisoned %d border tile(s)',
				reinforced, garrisoned), 4)
		end
	end

	AutoDefense = vain.Categories.Utility:CreateModule({
		Name = 'Auto Defense',
		Function = function(callback)
			if callback then
				do
					local myCountry = lplr:GetAttribute('MyCountry')
					notif('Auto Defense', string.format('%s  |  border tiles: %d  |  under attack: %d',
						getActionRemote() and 'Remote OK' or 'NO REMOTE',
						#borderTiles(myCountry), #fightingTiles(myCountry)), 7,
						(getActionRemote() and myCountry) and nil or 'warning')
				end
				task.spawn(function()
					repeat
						sweep()
						task.wait(Interval and Interval.Value or 12)
					until not AutoDefense.Enabled
				end)
			end
		end,
		Tooltip = 'Purely defensive: garrisons your border tiles and emergency-reinforces any tile under attack. Only ever spawns troops on tiles you own -- never moves onto enemy land and never declares war. Respects your money/manpower reserve.'
	})
	UnitType = AutoDefense:CreateDropdown({
		Name = 'Unit', List = { 'Infantry', 'Tank', 'Artillery', 'AntiAircraft' }, Default = 'Infantry',
		Tooltip = 'Which unit to defend with. Infantry is cheapest; Tank/Artillery hit harder but cost more.'
	})
	Garrison = AutoDefense:CreateSlider({ Name = 'Garrison Size', Min = 1, Max = 50, Default = 5, Tooltip = 'How many units to (re)spawn per tile each pass.' })
	DefendBattles = AutoDefense:CreateToggle({ Name = 'Reinforce Battles', Default = true, Tooltip = 'Emergency-spawn troops on any owned tile currently being fought over.' })
	MoneyReserve = AutoDefense:CreateSlider({ Name = 'Money Reserve', Min = 0, Max = 500, Default = 5, Suffix = 'M', Tooltip = 'Never spend money below this.' })
	ManpowerReserve = AutoDefense:CreateSlider({ Name = 'Manpower Reserve', Min = 0, Max = 1000, Default = 20, Suffix = 'K', Tooltip = 'Never spend manpower below this.' })
	Interval = AutoDefense:CreateSlider({ Name = 'Interval', Min = 2, Max = 60, Default = 12, Suffix = 'sec', Tooltip = 'How often to reinforce borders and battles.' })
	Notify = AutoDefense:CreateToggle({ Name = 'Notify', Default = false, Tooltip = 'Notify each pass how many tiles were reinforced/garrisoned.' })
end)
