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
--  AUTO CAPTURE  (enable auto-capture on every one of your soldiers)
-- ══════════════════════════════════════════════════════════════════════════════
run(function()
	local AutoCapture, Mode

	-- find the workspace folder that holds soldier models
	local function soldierCountry(m) return m:GetAttribute('Country') or m:GetAttribute('COUNTRY') end
	local function isSoldier(m)
		return m:IsA('Model') and soldierCountry(m) ~= nil
			and (m:GetAttribute('Type') ~= nil or m:GetAttribute('MOVING') ~= nil
				or m:GetAttribute('Fighting') ~= nil or m:FindFirstChildWhichIsA('Humanoid') ~= nil)
	end
	local soldierContainer = nil
	local function getSoldierContainer()
		if soldierContainer and soldierContainer.Parent then return soldierContainer end
		for _, name in {'Misc', 'WorldCenter', 'Units', 'Soldiers', 'Armies', 'Military'} do
			local f = workspace:FindFirstChild(name)
			if f then
				for _, m in f:GetChildren() do
					if isSoldier(m) then soldierContainer = f return f end
				end
			end
		end
		for _, m in workspace:GetDescendants() do
			if isSoldier(m) then soldierContainer = m.Parent return m.Parent end
		end
		return nil
	end

	local function toggleAll(state)
		local mine = lplr:GetAttribute('MyCountry')
		if not mine then return end
		local cont = getSoldierContainer()
		if not cont then return end
		local modeVal = (Mode and Mode.Value) or 'Capture'
		for _, m in cont:GetChildren() do
			if soldierCountry(m) == mine then
				if modeVal == 'Attack' then
					fireAction('ToggleAutoCapture', m, state, 'Attack')
				else
					fireAction('ToggleAutoCapture', m, state)
				end
				task.wait(0.05)
			end
		end
	end

	AutoCapture = vain.Categories.Utility:CreateModule({
		Name = 'Auto Capture',
		Function = function(callback)
			if callback then
				local mine = lplr:GetAttribute('MyCountry')
				local cont = getSoldierContainer()
				local count = 0
				if cont then
					for _, m in cont:GetChildren() do
						if soldierCountry(m) == mine then count += 1 end
					end
				end
				notif('Auto Capture', string.format('Remote: %s | Soldiers found: %d',
					getActionRemote() and 'OK' or 'NOT FOUND', count), 5,
					(getActionRemote() and count > 0) and nil or 'warning')
				toggleAll(true)
				-- re-apply every 10s to catch newly spawned soldiers
				task.spawn(function()
					repeat task.wait(10) if AutoCapture.Enabled then toggleAll(true) end
					until not AutoCapture.Enabled
				end)
			else
				toggleAll(false)
			end
		end,
		Tooltip = 'Enables auto-capture on all your soldiers so they keep expanding into adjacent tiles automatically. Re-applies every 10s to catch new units.'
	})
	Mode = AutoCapture:CreateDropdown({
		Name = 'Mode',
		List = { 'Capture', 'Attack' },
		Tooltip = 'Capture - expand into neutral/owned tiles\nAttack - also attack enemy tiles'
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
--  AUTO DEFENSE  (adaptive, threat-scored defence of your whole country)
-- ══════════════════════════════════════════════════════════════════════════════
-- Confirmed from the place file / previous build:
--   * tiles live in workspace.Regions (cached as _G.regionsChildren). Owned when
--     GetAttribute('Country') == MyCountry. CANNOT spawn on a tile whose
--     'OccupiedFrom' attribute is set (server rejects it -> "occupied territory").
--   * geometry is the tile's GeneratedRegion model (pivot = tile centre).
--   * soldiers live in workspace.SoldiersFolder, each has a 'Country' attribute, a
--     'LastFightTick' that updates in combat, and (usually) an 'Amount'/'Count'/'Size'
--     attribute for how many men the stack holds.
--   * spawn troops : Network:FireServer('CreateArmyOnTile', tile, unitTypeString, count)
--   * harden tile  : Network:FireServer('DevelopTile', tile, 'Def')      (raise DefenceTier)
--   * hold soldier : Network:FireServer('ToggleAutoCapture', soldier, false)  (stop advancing)
--
-- Unlike a flat garrison, this build SCORES every frontier tile by the enemy
-- pressure against it (nearby hostile manpower + the adjacent enemy tile's
-- DefenceTier + whether it is actively in combat) and spends its budget on the
-- most-threatened tiles first, hardens the hottest borders, protects your capital
-- first, and can pull your soldiers back from a fight they're losing.
run(function()
	local AutoDefense
	local UnitType, DefendBattles, HardenBorders, HoldWhenLosing, ProtectCapital
	local BaseGarrison, BattleMultiplier, HardenThreshold, CapitalGarrison
	local MoneyReserve, ManpowerReserve, MaxSpendPct, Interval, Notify

	local function regionTiles()
		if type(_G.regionsChildren) == 'table' and #_G.regionsChildren > 0 then
			return _G.regionsChildren
		end
		local r = workspace:FindFirstChild('Regions')
		return r and r:GetChildren() or {}
	end
	local function soldiersFolder() return workspace:FindFirstChild('SoldiersFolder') end

	-- how many men a soldier stack represents (best-effort across attribute names)
	local function soldierAmount(s)
		return s:GetAttribute('Amount') or s:GetAttribute('Count')
			or s:GetAttribute('Size') or s:GetAttribute('Troops') or 1
	end
	local function soldierPos(s)
		local ok, p = pcall(function() return s:GetPivot().Position end)
		if ok and p then return p end
		local bp = s:IsA('Model') and s:FindFirstChildWhichIsA('BasePart', true)
		return bp and bp.Position or nil
	end

	local function tilePos(t)
		local geo = t:FindFirstChild('GeneratedRegion') or t
		local ok, p = pcall(function() return geo:GetPivot().Position end)
		if ok and p then return p end
		local bp = (geo:IsA('BasePart') and geo) or geo:FindFirstChildWhichIsA('BasePart', true)
		return bp and bp.Position or nil
	end
	-- I own it and it is not occupied (occupied tiles reject spawns)
	local function spawnable(t, mine)
		return t:GetAttribute('Country') == mine and t:GetAttribute('OccupiedFrom') == nil
	end

	-- typical tile spacing = median nearest-neighbour distance, cached; the
	-- adjacency threshold for "these two tiles touch".
	local adjDist
	local function adjacencyDist(snapshot)
		if adjDist then return adjDist end
		local nn = {}
		for i = 1, #snapshot do
			local best
			for j = 1, #snapshot do
				if i ~= j then
					local d = (snapshot[i].pos - snapshot[j].pos).Magnitude
					if not best or d < best then best = d end
				end
			end
			if best then table.insert(nn, best) end
		end
		if #nn == 0 then return 60 end
		table.sort(nn)
		adjDist = nn[math.ceil(#nn / 2)]
		return adjDist
	end

	-- snapshot every tile once per sweep
	local function snapshotTiles(mine)
		local all = {}
		for _, t in regionTiles() do
			local p = tilePos(t)
			if p then
				table.insert(all, {
					tile = t, pos = p,
					country = t:GetAttribute('Country'),
					mine = t:GetAttribute('Country') == mine,
					canSpawn = spawnable(t, mine),
					pop = t:GetAttribute('DefaultPopulation') or 0,
					defTier = t:GetAttribute('DefenceTier') or 1,
				})
			end
		end
		return all
	end

	-- index enemy soldiers once per sweep: {pos, amount, fighting}
	local function enemyForces(mine)
		local sf = soldiersFolder()
		local out = {}
		if not sf then return out end
		local now = tick()
		for _, s in sf:GetChildren() do
			local sc = s:GetAttribute('Country')
			if sc and sc ~= mine then
				local p = soldierPos(s)
				if p then
					local lf = s:GetAttribute('LastFightTick')
					table.insert(out, {
						pos = p,
						amount = tonumber(soldierAmount(s)) or 1,
						fighting = type(lf) == 'number' and (now - lf) < 6,
					})
				end
			end
		end
		return out
	end

	-- my own soldiers, with their stack, so we can pull them back if losing
	local function myForces(mine)
		local sf = soldiersFolder()
		local out = {}
		if not sf then return out end
		for _, s in sf:GetChildren() do
			if s:GetAttribute('Country') == mine then
				local p = soldierPos(s)
				if p then table.insert(out, { inst = s, pos = p, amount = tonumber(soldierAmount(s)) or 1 }) end
			end
		end
		return out
	end

	-- Score each spawnable frontier tile by the ENEMY PRESSURE bearing on it:
	--   pressure = sum(enemy manpower within ~1.5 tiles, distance-weighted)
	--            + (adjacent enemy tile's DefenceTier * 500)
	--            + (in active combat ? big flat bonus)
	-- Returns a sorted-by-pressure list of { tile, pressure, contested, myNear }.
	local function scoreFrontier(all, enemies, mine)
		local thresh = adjacencyDist(all)
		local myTroopsNear = {}   -- tile -> my manpower sitting on/near it
		for _, f in myForces(mine) do
			for _, o in all do
				if o.canSpawn and (o.pos - f.pos).Magnitude <= thresh * 0.75 then
					myTroopsNear[o.tile] = (myTroopsNear[o.tile] or 0) + f.amount
				end
			end
		end

		local scored = {}
		for _, o in all do
			if o.canSpawn then
				local pressure, contested = 0, false
				-- enemy soldiers bearing on this tile
				for _, e in enemies do
					local d = (o.pos - e.pos).Magnitude
					if d <= thresh * 1.5 then
						local w = 1 - (d / (thresh * 1.5)) * 0.6   -- closer = heavier
						pressure += e.amount * w
						if e.fighting and d <= thresh then contested = true end
					end
				end
				-- adjacency to a strong enemy tile is standing pressure even with no
				-- soldiers currently on the map
				for _, x in all do
					if not x.mine and x.country ~= nil and (o.pos - x.pos).Magnitude <= thresh * 1.5 then
						pressure += x.defTier * 300
					end
				end
				if pressure > 0 or contested then
					if contested then pressure += 5000 end
					table.insert(scored, {
						tile = o.tile, pressure = pressure, contested = contested,
						defTier = o.defTier, pop = o.pop,
						myNear = myTroopsNear[o.tile] or 0,
					})
				end
			end
		end
		table.sort(scored, function(a, b) return a.pressure > b.pressure end)
		return scored
	end

	-- highest-population spawnable tiles = your heartland/capital, defended first
	local function capitalTiles(all, n)
		local mineSpawn = {}
		for _, o in all do if o.canSpawn then table.insert(mineSpawn, o) end end
		table.sort(mineSpawn, function(a, b) return a.pop > b.pop end)
		local out = {}
		for i = 1, math.min(n, #mineSpawn) do table.insert(out, mineSpawn[i]) end
		return out
	end

	local lastSpawn = {}   -- anti-spam per tile
	local lastHarden = {}

	local function sweep()
		local mine = lplr:GetAttribute('MyCountry')
		if not (mine and getActionRemote()) then return end

		local moneyReserve = (MoneyReserve.Value or 0) * 1e6
		local mpReserve    = (ManpowerReserve.Value or 0) * 1e3
		local unit    = (UnitType and UnitType.Value) or 'Soldier'
		local baseGar = math.floor(BaseGarrison.Value)
		local battleX = BattleMultiplier.Value or 2
		local capGar  = math.floor(CapitalGarrison.Value)

		-- adaptive budget: at most MaxSpendPct of spendable money this sweep
		local money0, mp0 = getBalance(mine)
		money0 = money0 or 0
		mp0 = mp0 or math.huge
		local spendable = math.max(0, money0 - moneyReserve)
		local budget = spendable * ((MaxSpendPct.Value or 50) / 100)
		local spent = 0

		local reinforced, garrisoned, hardened, held = 0, 0, 0, 0

		local function canSpend(estCost)
			if spent + estCost > budget then return false end
			local m, p = getBalance(mine)
			if m and (m - estCost) <= moneyReserve then return false end
			if p and p <= mpReserve then return false end
			return true
		end

		-- rough per-unit money cost (defensive spawns are cheap vs upgrades; we bias
		-- the estimate high so the reserve is genuinely protected)
		local function spawnCost(count) return count * 250 end

		local function spawn(tile, count, force)
			if count <= 0 then return false end
			local now = tick()
			if not force and lastSpawn[tile] and (now - lastSpawn[tile]) < (Interval.Value or 8) then
				return false
			end
			local est = spawnCost(count)
			if not canSpend(est) then return false end
			lastSpawn[tile] = now
			spent += est
			fireAction('CreateArmyOnTile', tile, unit, count)
			task.wait(0.14)
			return true
		end

		local all     = snapshotTiles(mine)
		local enemies  = enemyForces(mine)
		local scored   = scoreFrontier(all, enemies, mine)

		-- 1) CAPITAL FIRST -- always keep the heartland stocked
		if ProtectCapital.Enabled then
			for _, o in capitalTiles(all, 3) do
				if not AutoDefense.Enabled then break end
				if spawn(o.tile, capGar, false) then garrisoned += 1 end
			end
		end

		-- 2) THREAT-SCORED FRONTIER -- spend on the hottest borders first, sizing the
		--    garrison to the pressure and to what I already have sitting there.
		for _, s in scored do
			if not AutoDefense.Enabled then break end
			-- target strength scales with pressure; contested tiles get the multiplier
			local want = baseGar + math.floor(math.min(s.pressure, 20000) / 1000) * baseGar
			if s.contested and DefendBattles.Enabled then want = math.floor(want * battleX) end
			local deficit = want - s.myNear
			if deficit > 0 then
				if spawn(s.tile, deficit, s.contested) then
					if s.contested then reinforced += 1 else garrisoned += 1 end
				end
			end

			-- 3) HARDEN the very hottest borders (raise DefenceTier) when they're
			--    under sustained pressure and not already maxed.
			if HardenBorders.Enabled and s.defTier < 10 and s.pressure >= (HardenThreshold.Value or 3000) then
				local now = tick()
				if not lastHarden[s.tile] or (now - lastHarden[s.tile]) > 15 then
					local c = tileCosts(s.tile)
					if c and canSpend(c.defMoney) and (mp0 - c.defManpower) > mpReserve then
						lastHarden[s.tile] = now
						spent += c.defMoney
						fireAction('DevelopTile', s.tile, 'Def')
						hardened += 1
						task.wait(0.14)
					end
				end
			end
		end

		-- 4) HOLD WHEN LOSING -- if a frontier fight is badly outnumbered, stop my
		--    soldiers there from advancing so they consolidate instead of trickling in.
		if HoldWhenLosing.Enabled then
			local thresh = adjacencyDist(all)
			for _, f in myForces(mine) do
				if not AutoDefense.Enabled then break end
				local enemyNear, mineNear = 0, f.amount
				for _, e in enemies do
					if (f.pos - e.pos).Magnitude <= thresh then enemyNear += e.amount end
				end
				for _, g in myForces(mine) do
					if g.inst ~= f.inst and (f.pos - g.pos).Magnitude <= thresh then mineNear += g.amount end
				end
				-- outnumbered 2:1 or worse -> hold position
				if enemyNear >= mineNear * 2 and enemyNear > 0 then
					fireAction('ToggleAutoCapture', f.inst, false)
					held += 1
					task.wait(0.05)
				end
			end
		end

		if Notify.Enabled and (reinforced + garrisoned + hardened + held) > 0 then
			notif('Auto Defense', string.format(
				'reinforced %d | garrisoned %d | hardened %d | held %d  ($%s spent)',
				reinforced, garrisoned, hardened, held, fmtNum(spent)), 4)
		end
	end

	AutoDefense = vain.Categories.Utility:CreateModule({
		Name = 'Auto Defense',
		Function = function(callback)
			if callback then
				local mine    = lplr:GetAttribute('MyCountry')
				local all     = snapshotTiles(mine)
				local enemies = enemyForces(mine)
				local scored  = scoreFrontier(all, enemies, mine)
				local spawnCnt = 0
				for _, o in all do if o.canSpawn then spawnCnt += 1 end end
				notif('Auto Defense', string.format(
					'%s | tiles %d | spawnable %d | frontier %d | enemy stacks %d | soldiers %s',
					getActionRemote() and 'Remote OK' or 'NO REMOTE',
					#all, spawnCnt, #scored, #enemies,
					soldiersFolder() and 'OK' or 'MISSING'), 8,
					(getActionRemote() and mine and spawnCnt > 0) and nil or 'warning')
				AutoDefense:Clean(task.spawn(function()
					repeat
						sweep()
						task.wait(Interval and Interval.Value or 8)
					until not AutoDefense.Enabled
				end))
			end
		end,
		Tooltip = 'Adaptive whole-country defence. Scores every frontier tile by the enemy pressure against it (nearby hostile troops + adjacent enemy defence + active combat) and spends first on the most-threatened borders, hardens the hottest tiles, always keeps your capital garrisoned, and can pull soldiers back from a fight they are losing. Respects money/manpower reserves and a per-sweep spend cap.'
	})

	UnitType = AutoDefense:CreateDropdown({ Name = 'Unit',
		List = { 'Soldier', 'Tank', 'Artillery', 'AntiAircraft' }, Default = 'Soldier',
		Tooltip = 'Which unit type to spawn when garrisoning/reinforcing.' })
	BaseGarrison = AutoDefense:CreateSlider({ Name = 'Base Garrison', Min = 1, Max = 500, Default = 15,
		Tooltip = 'Baseline troops per frontier tile. The real target scales UP with how much enemy pressure that tile is under.' })
	BattleMultiplier = AutoDefense:CreateSlider({ Name = 'Battle Multiplier', Min = 1, Max = 6, Default = 2,
		Tooltip = 'A tile in active combat gets its target garrison multiplied by this.' })
	CapitalGarrison = AutoDefense:CreateSlider({ Name = 'Capital Garrison', Min = 0, Max = 1000, Default = 40,
		Tooltip = 'Troops to keep on each of your 3 highest-population (capital) tiles, defended before anything else.' })
	DefendBattles = AutoDefense:CreateToggle({ Name = 'Reinforce Battles', Default = true,
		Tooltip = 'Rush extra troops (with the battle multiplier) to any owned tile with active enemy combat on it.' })
	HardenBorders = AutoDefense:CreateToggle({ Name = 'Harden Borders', Default = true,
		Tooltip = "Auto-raise DefenceTier on the hottest frontier tiles once they cross the harden threshold (costs money + manpower)." })
	HardenThreshold = AutoDefense:CreateSlider({ Name = 'Harden Threshold', Min = 500, Max = 20000, Default = 3000,
		Tooltip = 'Enemy-pressure score a tile must reach before its defence is upgraded. Lower = hardens more tiles, more spending.' })
	ProtectCapital = AutoDefense:CreateToggle({ Name = 'Protect Capital', Default = true,
		Tooltip = 'Always garrison your 3 highest-population tiles first, even if the frontier is quiet.' })
	HoldWhenLosing = AutoDefense:CreateToggle({ Name = 'Hold When Losing', Default = true,
		Tooltip = 'If your soldiers in a fight are outnumbered 2:1 or worse, stop them auto-advancing so they consolidate instead of feeding the fight piecemeal.' })
	MoneyReserve = AutoDefense:CreateSlider({ Name = 'Money Reserve', Min = 0, Max = 500, Default = 5, Suffix = 'M',
		Tooltip = 'Never let money drop below this.' })
	ManpowerReserve = AutoDefense:CreateSlider({ Name = 'Manpower Reserve', Min = 0, Max = 1000, Default = 20, Suffix = 'K',
		Tooltip = 'Never let manpower drop below this.' })
	MaxSpendPct = AutoDefense:CreateSlider({ Name = 'Max Spend / Sweep', Min = 5, Max = 100, Default = 50, Suffix = '%',
		Tooltip = 'Cap how much of your spendable money (money minus reserve) a single sweep may use, so a huge front cannot bankrupt you at once.' })
	Interval = AutoDefense:CreateSlider({ Name = 'Interval', Min = 1, Max = 60, Default = 6, Suffix = 'sec',
		Tooltip = 'How often to re-scan the front and re-defend.' })
	Notify = AutoDefense:CreateToggle({ Name = 'Notify', Default = false,
		Tooltip = 'Notify each sweep with what it reinforced / garrisoned / hardened / held.' })
end)

-- ══════════════════════════════════════════════════════════════════════════════
--  AUTO ALLIANCE BANK  (dump overflow manpower into the alliance bank when full)
-- ══════════════════════════════════════════════════════════════════════════════
-- CONFIRMED from the decompiled place file (Alliance menu, Line 3522):
--   the "Add" button on the Manpower box fires
--     Network:FireServer("AddToGuildBank", <resource>, <amount>)
--   where <resource> is the box's parent name -- literally "Manpower" (or "Money")
--   -- and <amount> is a plain number. The client reads the country's live balance
--   from CountryRegistry[MyCountry].<resource>.Value and refuses to send more than
--   it has. There is NO client-side manpower cap constant (growth is capped
--   server-side), so "full" is detected by manpower plateauing, with an optional
--   manual cap for an exact percentage trigger.
run(function()
	local AutoAllianceBank
	local KeepReserve, ManualCap, Threshold, Interval, Notify

	-- optional manpower cap: the game exposes none client-side, so this is either a
	-- sibling Value if a future update adds one, or the manual override slider.
	local function manpowerCap(country)
		local cf = countryFolder(country)
		if cf then
			for _, name in { 'MaxManpower', 'ManpowerCap', 'ManpowerMax', 'ManpowerLimit', 'MaxMP' } do
				local v = cf:FindFirstChild(name)
				if v and v.Value and v.Value > 0 then return v.Value end
			end
		end
		local manual = (ManualCap and ManualCap.Value or 0) * 1e3
		if manual > 0 then return manual end
		return nil
	end

	-- fire the confirmed deposit call and VERIFY by re-reading manpower afterwards.
	-- Returns the amount that actually left your balance (0 if nothing moved).
	local function deposit(mine, amount)
		amount = math.floor(amount)
		if amount <= 0 then return 0 end
		local before = select(2, getBalance(mine)) or 0
		fireAction('AddToGuildBank', 'Manpower', amount)
		task.wait(0.35)   -- let the server replicate the new manpower value back
		local after = select(2, getBalance(mine)) or before
		return math.max(0, before - after)
	end

	-- track manpower over time so we can detect "it stopped growing" = at cap, even
	-- without a cap constant. If manpower hasn't risen across two checks and is above
	-- the reserve, treat it as full.
	local lastManpower, plateaus = nil, 0

	local function sweep()
		local mine = lplr:GetAttribute('MyCountry')
		if not mine then return end
		local _, manpower = getBalance(mine)
		if not manpower then return end
		local cap = manpowerCap(mine)
		local keep = (KeepReserve and KeepReserve.Value or 0) * 1e3

		-- decide whether we're "at max"
		local trigger
		if cap then
			-- exact: manpower reached the threshold fraction of a known cap
			trigger = manpower >= cap * ((Threshold and Threshold.Value or 98) / 100)
		else
			-- no cap constant: treat as full once manpower stops climbing (plateau)
			if lastManpower and manpower <= lastManpower + 1 then
				plateaus = plateaus + 1
			else
				plateaus = 0
			end
			lastManpower = manpower
			trigger = manpower > keep and plateaus >= 1
		end
		if not trigger then return end

		local overflow = manpower - keep
		if overflow <= 0 then return end

		local moved = deposit(mine, overflow)
		if moved > 0 then
			plateaus = 0
			lastManpower = select(2, getBalance(mine)) or (manpower - moved)
			if Notify.Enabled then
				notif('Alliance Bank', string.format('Deposited %s manpower (was at %s%s)',
					fmtNum(moved), fmtNum(manpower), cap and ('/' .. fmtNum(cap)) or ''), 4, 'success')
			end
		elseif Notify.Enabled then
			-- honest failure: the call fired but manpower didn't drop
			notif('Alliance Bank',
				"Deposit didn't go through -- are you actually in an alliance? (Nothing left your manpower.)",
				6, 'warning')
		end
	end

	AutoAllianceBank = vain.Categories.Utility:CreateModule({
		Name = 'Auto Alliance Bank',
		Tooltip = "Once your country's manpower stops growing it's wasted -- this deposits the overflow into your alliance bank automatically (via the game's AddToGuildBank call). Detects 'full' by manpower plateauing, or exactly against a Manual Cap if you set one, and always keeps your reserve. You must actually be in an alliance.",
		Function = function(callback)
			if callback then
				lastManpower, plateaus = nil, 0
				local mine = lplr:GetAttribute('MyCountry')
				local _, mp = getBalance(mine)
				local cap = manpowerCap(mine)
				notif('Auto Alliance Bank', string.format(
					'%s | manpower %s | cap %s',
					getActionRemote() and 'Remote OK' or 'NO REMOTE',
					mp and fmtNum(mp) or '?',
					cap and fmtNum(cap) or 'auto (plateau detect)'),
					6, (getActionRemote() and mp) and nil or 'warning')
				AutoAllianceBank:Clean(task.spawn(function()
					while AutoAllianceBank.Enabled do
						sweep()
						task.wait(Interval and Interval.Value or 5)
					end
				end))
			end
		end
	})

	KeepReserve = AutoAllianceBank:CreateSlider({ Name = 'Keep Reserve', Min = 0, Max = 1000, Default = 50, Suffix = 'K',
		Tooltip = 'Always keep at least this much manpower for yourself -- only the amount above it is deposited.' })
	Threshold = AutoAllianceBank:CreateSlider({ Name = 'Deposit At', Min = 50, Max = 100, Default = 98, Suffix = '%',
		Tooltip = 'Only used with a Manual Cap: deposit once manpower reaches this percent of that cap (100% = only when completely full).' })
	ManualCap = AutoAllianceBank:CreateSlider({ Name = 'Manual Cap', Min = 0, Max = 5000, Default = 0, Suffix = 'K',
		Tooltip = "Optional. The game has no client-side manpower cap, so by default 'full' is detected when manpower stops rising. Set your known max here (in thousands) for an exact percentage trigger instead. Leave at 0 for auto plateau-detection." })
	Interval = AutoAllianceBank:CreateSlider({ Name = 'Interval', Min = 1, Max = 60, Default = 5, Suffix = 'sec',
		Tooltip = 'How often to check whether manpower has hit the cap.' })
	Notify = AutoAllianceBank:CreateToggle({ Name = 'Notify', Default = true,
		Tooltip = 'Notify each deposit (verified -- only fires if your manpower actually dropped).' })
end)

run(function()
	-- ── Highlight Formables ─────────────────────────────────────────────────────
	-- CONFIRMED from the decompiled place file (BuildFormables, Line 3829):
	--   Formables are rendered under PlayerGui.MainUI ... Formables.Container, each a
	--   frame with a `Button` holding `NAME`, `IMG`, `EQ`, `LOCKED`, `REQ2`. The game
	--   does NOT keep a persistent "you owned this formable" flag on the entries --
	--   it only tracks the formable your country is CURRENTLY transformed into
	--   (CountryRegistry[MyCountry] attribute "TRANSFORMEDINTO", shown as a special
	--   "1RESET" revert entry) and, separately, aggregate milestone progress. So the
	--   meaningful, real states we can mark per entry are:
	--     * CURRENT  -> the "1RESET" entry = the formable you are transformed into now
	--     * READY    -> Button.EQ.NAME.Text == "Transform" and Button.LOCKED not shown
	--                   (you own every required region -- you can transform right now)
	--     * LOCKED   -> Button.LOCKED shown / no working EQ (requirements not met)
	--   We stamp a blue star on the current one and a green check + outline on every
	--   ready one, and (optionally) tint locked ones so the menu reads at a glance.
	local HighlightFormables
	local MarkReady, MarkCurrent, DimLocked
	local CHECK_ICON = 'rbxassetid://6031094667'  -- material "check_circle"
	local STAR_ICON  = 'rbxassetid://6031068421'  -- material "star"
	local marked = {}

	local function container()
		local pg = lplr:FindFirstChild('PlayerGui')
		local mainui = pg and pg:FindFirstChild('MainUI')
		if not mainui then return nil end
		local formables = mainui:FindFirstChild('Formables', true)
		return formables and (formables:FindFirstChild('Container') or formables) or nil
	end

	local function entryButton(entry)
		local btn = entry:FindFirstChild('Button')
		if btn and btn:FindFirstChild('NAME') then return btn end
		return nil
	end

	-- READY = a working Transform action was built (requirements met, not locked)
	local function isReady(btn)
		local locked = btn:FindFirstChild('LOCKED')
		if locked and locked:IsA('GuiObject') and locked.Visible then return false end
		local eq = btn:FindFirstChild('EQ')
		if not (eq and eq:IsA('GuiObject') and eq.Visible) then return false end
		local nm = eq:FindFirstChild('NAME')
		return nm and nm:IsA('TextLabel') and nm.Text:lower():find('transform') ~= nil
	end

	local function clearMark(target)
		local m = target:FindFirstChild('VainFormMark')
		if m then m:Destroy() end
		local s = target:FindFirstChild('VainFormStroke')
		if s then s:Destroy() end
	end

	local function stamp(target, icon, col)
		clearMark(target)
		local badge = Instance.new('ImageLabel')
		badge.Name = 'VainFormMark'
		badge.AnchorPoint = Vector2.new(1, 0)
		badge.Position = UDim2.new(1, -4, 0, 4)
		badge.Size = UDim2.fromOffset(24, 24)
		badge.BackgroundTransparency = 1
		badge.Image = icon
		badge.ImageColor3 = col
		badge.ZIndex = 50
		badge.Parent = target
		local stroke = Instance.new('UIStroke')
		stroke.Name = 'VainFormStroke'
		stroke.Color = col
		stroke.Thickness = 2
		stroke.Transparency = 0.15
		stroke.Parent = target
	end

	local GREEN = Color3.fromRGB(80, 220, 110)
	local BLUE  = Color3.fromRGB(65, 150, 255)

	local function refresh()
		if not (HighlightFormables and HighlightFormables.Enabled) then return end
		local cont = container()
		if not cont then return end
		for _, entry in cont:GetChildren() do
			if entry:IsA('GuiObject') then
				local btn = entryButton(entry)
				if btn then
					marked[entry] = true
					if entry.Name == '1RESET' then
						-- the current transform (revert entry)
						if MarkCurrent.Enabled then stamp(entry, STAR_ICON, BLUE) else clearMark(entry) end
					elseif isReady(btn) then
						if MarkReady.Enabled then stamp(entry, CHECK_ICON, GREEN) else clearMark(entry) end
						if btn:FindFirstChild('VainDim') then btn.VainDim:Destroy() end
					else
						clearMark(entry)
						-- optionally dim locked ones
						local existing = btn:FindFirstChild('VainDim')
						if DimLocked.Enabled then
							if not existing then
								local dim = Instance.new('Frame')
								dim.Name = 'VainDim'
								dim.Size = UDim2.fromScale(1, 1)
								dim.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
								dim.BackgroundTransparency = 0.55
								dim.BorderSizePixel = 0
								dim.ZIndex = 40
								dim.Parent = btn
							end
						elseif existing then
							existing:Destroy()
						end
					end
				end
			end
		end
	end

	HighlightFormables = vain.Categories.Utility:CreateModule({
		Name = 'Highlight Formables',
		Tooltip = "Marks up the transformation menu: a green check on every formable you can transform into RIGHT NOW (you own all required regions), and a blue star on the one you're currently transformed into. Note: this game does not keep a permanent 'owned' flag on formables you transformed into in the past -- only your current transform is tracked -- so past ones can't be marked as owned.",
		Function = function(callback)
			if callback then
				refresh()
				HighlightFormables:Clean(task.spawn(function()
					while HighlightFormables.Enabled do
						refresh()
						task.wait(0.5)
					end
				end))
			else
				for entry in marked do
					if entry and entry.Parent then
						clearMark(entry)
						local btn = entry:FindFirstChild('Button')
						if btn and btn:FindFirstChild('VainDim') then btn.VainDim:Destroy() end
					end
				end
				table.clear(marked)
			end
		end
	})

	MarkReady = HighlightFormables:CreateToggle({ Name = 'Mark Ready', Default = true,
		Tooltip = 'Green check + outline on every formable you can transform into right now.' })
	MarkCurrent = HighlightFormables:CreateToggle({ Name = 'Mark Current', Default = true,
		Tooltip = "Blue star on the formable your country is currently transformed into (the revert entry)." })
	DimLocked = HighlightFormables:CreateToggle({ Name = 'Dim Locked', Default = false,
		Tooltip = 'Darken formables whose requirements you have not met yet, so the ready ones stand out.' })
end)

-- ══════════════════════════════════════════════════════════════════════════════
--  AUTO TRANSFORM  (claim every formable the instant it becomes available)
-- ══════════════════════════════════════════════════════════════════════════════
-- CONFIRMED from the decompiled place file (Formables menu, Lines 3876 / 4059):
--   Each formable is an entry parented to PlayerGui.MainUI ... Formables.Container.
--   The entry has a `Button` frame with a `NAME` label and an `EQ` button. The game
--   builds that entry as AVAILABLE only when you already own every required region
--   (`#v468 == 0`) and it is not specially locked -- in that case it sets
--   Button.EQ.NAME.Text = "Transform" and Button.LOCKED is not shown. LOCKED
--   formables instead show Button.LOCKED / Button.REQ2 and have NO working EQ.
--   Claiming fires:  Network:FireServer("TransformInto", <formableId>)
--   where <formableId> is the entry's own Name (path 1: u452.Name) / the formable
--   key (path 2: i). We read availability from that exact UI signal, then fire the
--   confirmed remote directly (and click the EQ button as a fallback).
run(function()
	local AutoTransform
	local Interval, Notify
	local attempted = {}   -- formable id -> last attempt tick (don't spam)

	local function formablesContainer()
		local pg = lplr:FindFirstChild('PlayerGui')
		local mainui = pg and pg:FindFirstChild('MainUI')
		if not mainui then return nil end
		-- Formables.Container, wherever it sits under MainUI
		local formables = mainui:FindFirstChild('Formables', true)
		local container = formables and (formables:FindFirstChild('Container') or formables)
		return container, (mainui ~= nil)
	end

	-- an entry is any child that carries a Button with a NAME label (the formable row)
	local function entryButton(entry)
		local btn = entry:FindFirstChild('Button')
		if btn and btn:FindFirstChild('NAME') then return btn end
		return nil
	end

	-- AVAILABLE = the game built a working "Transform" action for it: Button.EQ exists
	-- with NAME.Text == "Transform", and Button.LOCKED is not shown. This is the exact
	-- rule the client uses (you own every required region), read straight off the UI.
	local function isAvailable(btn)
		local locked = btn:FindFirstChild('LOCKED')
		if locked and locked:IsA('GuiObject') and locked.Visible then return false end
		local eq = btn:FindFirstChild('EQ')
		if not (eq and eq:IsA('GuiObject') and eq.Visible) then return false end
		local nm = eq:FindFirstChild('NAME')
		if nm and nm:IsA('TextLabel') then
			return nm.Text:lower():find('transform') ~= nil
		end
		return false
	end

	-- the formable id to send. The transform remote takes the entry's Name; some
	-- locked entries are renamed "_<id>", so strip a leading underscore.
	local function formableId(entry)
		local n = entry.Name
		if n:sub(1, 1) == '_' then n = n:sub(2) end
		return n
	end

	-- claim it: fire the confirmed remote, and also click the EQ button so we hit the
	-- game's own handler (which sends the exact argument) as a belt-and-braces path.
	local function claim(entry, btn)
		local id = formableId(entry)
		fireAction('TransformInto', id)
		local eq = btn:FindFirstChild('EQ')
		if eq then
			pcall(function()
				if type(firesignal) == 'function' then
					firesignal(eq.MouseButton1Click)
				elseif type(getconnections) == 'function' then
					for _, con in getconnections(eq.MouseButton1Click) do
						if con.Fire then con:Fire() elseif con.Function then con.Function() end
					end
				end
			end)
		end
		return id
	end

	local function sweep()
		local container = formablesContainer()
		if not container then return 0, 0 end
		local now = tick()
		local claimed, avail = 0, 0
		for _, entry in container:GetChildren() do
			if entry:IsA('GuiObject') then
				local btn = entryButton(entry)
				if btn and isAvailable(btn) then
					avail += 1
					local id = formableId(entry)
					if not attempted[id] or (now - attempted[id]) > 8 then
						attempted[id] = now
						claim(entry, btn)
						claimed += 1
						if Notify.Enabled then
							local nm = btn:FindFirstChild('NAME')
							local label = (nm and nm:IsA('TextLabel') and nm.Text) or id
							notif('Auto Transform', 'Transforming into ' .. tostring(label), 3, 'success')
						end
						task.wait(0.3)
					end
				end
			end
		end
		return claimed, avail
	end

	AutoTransform = vain.Categories.Utility:CreateModule({
		Name = 'Auto Transform',
		Tooltip = "Automatically transforms your country into any formable the instant it becomes available. It reads the transformation menu for formables the game has marked ready (you own every required region) and fires the game's real TransformInto call. Keep the transform menu opened at least once so the entries exist.",
		Function = function(callback)
			if callback then
				local container, hasUI = formablesContainer()
				local _, avail = sweep()
				notif('Auto Transform', string.format(
					'%s | available formables: %d%s',
					getActionRemote() and (container and 'Ready' or 'open the Transform menu once')
						or 'NO REMOTE',
					avail, container and '' or ' (menu not loaded yet)'),
					7, (getActionRemote() and container) and nil or 'warning')
				AutoTransform:Clean(task.spawn(function()
					while AutoTransform.Enabled do
						sweep()
						task.wait(Interval and Interval.Value or 3)
					end
				end))
			end
		end
	})

	Interval = AutoTransform:CreateSlider({ Name = 'Check Interval', Min = 1, Max = 30, Default = 3, Suffix = 'sec',
		Tooltip = 'How often to re-scan the transformation menu for a newly-available formable.' })
	Notify = AutoTransform:CreateToggle({ Name = 'Notify', Default = true,
		Tooltip = 'Notify when it transforms your country into a formable.' })
end)
