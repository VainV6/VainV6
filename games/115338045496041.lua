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
-- Manpower is read live from CountryRegistry.<country>.Manpower (same source the
-- rest of the file uses). Manpower is capped -- we find that cap from a sibling
-- value (MaxManpower / ManpowerCap / ManpowerMax / ...) or a country attribute; if
-- the game exposes no cap value, you can set a manual "treat as max" amount so the
-- module still works. When manpower reaches the cap it would otherwise be wasted,
-- so we deposit the overflow (manpower minus a keep-reserve) into the alliance bank.
--
-- The alliance deposit action is fired through the game's action remote. We don't
-- have a decompiled place file for this game, so instead of hardcoding one name we
-- try the plausible alliance-deposit action names AND fire any alliance-specific
-- RemoteEvent we can discover in ReplicatedStorage. The server validates the
-- deposit, so attempting a name it doesn't know is harmless.
run(function()
	local AutoAllianceBank
	local KeepReserve, ManualCap, Threshold, Interval, LearnDeposit, Notify

	-- read the manpower cap for a country: a sibling Value, then an attribute, then
	-- the manual override slider (in thousands). Returns nil if genuinely unknown.
	local function manpowerCap(country)
		local cf = countryFolder(country)
		if cf then
			for _, name in { 'MaxManpower', 'ManpowerCap', 'ManpowerMax', 'MaxManpwer', 'ManpowerLimit', 'MaxMP' } do
				local v = cf:FindFirstChild(name)
				if v and v.Value and v.Value > 0 then return v.Value end
			end
			for _, name in { 'MaxManpower', 'ManpowerCap', 'ManpowerMax', 'ManpowerLimit' } do
				local a = cf:GetAttribute(name)
				if type(a) == 'number' and a > 0 then return a end
			end
		end
		local manual = (ManualCap and ManualCap.Value or 0) * 1e3
		if manual > 0 then return manual end
		return nil
	end

	-- ── learned deposit call ──────────────────────────────────────────────────
	-- We can't verify a blind FireServer, so the reliable path is to LEARN the real
	-- call the game uses. When "Learn Deposit" is on we hook FireServer/InvokeServer
	-- and, the next time YOU manually deposit manpower into the alliance bank, we
	-- capture the exact remote + argument layout and replay it afterwards. The learned
	-- call is persisted to a file so it survives rejoins.
	local LEARN_FILE = 'vain/controleurope_alliance_deposit.txt'
	local learned      -- { remote = Instance, args = {...}, amountIndex = n }

	-- where in a captured arg list the deposited number sits, so we can swap our
	-- amount in. Picks the largest number that plausibly is a manpower figure.
	local function findAmountIndex(args)
		local bestI, bestV
		for i, a in ipairs(args) do
			if type(a) == 'number' and a >= 1 and (not bestV or a > bestV) then
				bestI, bestV = i, a
			end
		end
		return bestI
	end

	local function saveLearned()
		if not (learned and typeof(writefile) == 'function') then return end
		-- persist by remote full path + amount index + literal (non-instance) args
		local safeArgs = {}
		for i, a in ipairs(learned.args) do
			local t = type(a)
			if t == 'number' or t == 'boolean' then safeArgs[i] = { t, a }
			elseif t == 'string' then safeArgs[i] = { 'string', a }
			else safeArgs[i] = { 'skip' } end
		end
		local ok, blob = pcall(function()
			return game:GetService('HttpService'):JSONEncode({
				path = learned.remote:GetFullName(),
				amountIndex = learned.amountIndex,
				args = safeArgs,
			})
		end)
		if ok then pcall(writefile, LEARN_FILE, blob) end
	end

	local function resolveByPath(path)
		local node = game
		for part in string.gmatch(path, '[^%.]+') do
			if node == game then
				node = game:GetService(part) or game:FindFirstChild(part)
			else
				node = node and node:FindFirstChild(part)
			end
			if not node then return nil end
		end
		return node
	end

	local function loadLearned()
		if learned then return end
		if typeof(readfile) ~= 'function' then return end
		local ok, blob = pcall(readfile, LEARN_FILE)
		if not (ok and type(blob) == 'string' and #blob > 0) then return end
		local ok2, data = pcall(function() return game:GetService('HttpService'):JSONDecode(blob) end)
		if not (ok2 and type(data) == 'table' and data.path) then return end
		local remote = resolveByPath(data.path)
		if not remote then return end
		local args = {}
		for i, pair in ipairs(data.args or {}) do
			if pair[1] == 'skip' then args[i] = false else args[i] = pair[2] end
		end
		learned = { remote = remote, args = args, amountIndex = data.amountIndex }
	end

	-- install the learning hook (idempotent); active only while the toggle is on.
	-- classify a captured (remote, args) OFF the hook thread -- GetFullName / IsA are
	-- themselves namecalls, so doing them inside the hook would recurse. We only look
	-- at ones we know we fired ourselves? No -- we skip our own by a flag.
	local firingLearned = false
	local function classifyCapture(remote, args)
		if learned ~= nil then return end
		local okName, n = pcall(function() return (remote.Name or ''):lower() end)
		local full = ''
		pcall(function() full = remote:GetFullName():lower() end)
		if not (okName and (n:find('alliance') or full:find('alliance') or full:find('bank'))) then return end
		local ai = findAmountIndex(args)
		if not ai then return end
		learned = { remote = remote, args = args, amountIndex = ai }
		saveLearned()
		if vain and vain.CreateNotification then
			vain:CreateNotification('Auto Alliance Bank',
				'Learned deposit call: ' .. tostring(n) .. ' (amount = arg #' .. ai .. '). It will replay this automatically now.', 6, 'success')
		end
	end

	local learnHookInstalled = false
	local function installLearnHook()
		if learnHookInstalled then return end
		if type(hookmetamethod) ~= 'function' or type(getnamecallmethod) ~= 'function' then return end
		learnHookInstalled = true
		local oldNamecall
		oldNamecall = hookmetamethod(game, '__namecall', function(self, ...)
			-- keep the hook body free of any namecalls on `self` (they'd recurse).
			-- Only read the method + capture args here; classify on another thread.
			if learned == nil and not firingLearned and type(self) == 'userdata' then
				local method = getnamecallmethod()
				if method == 'FireServer' or method == 'InvokeServer' then
					local args = { ... }
					local remote = self
					task.spawn(classifyCapture, remote, args)
				end
			end
			return oldNamecall(self, ...)
		end)
	end

	-- replay the learned call with our amount swapped in. Returns true if it fired.
	local function fireLearned(amount)
		if not (learned and learned.remote and learned.remote.Parent) then return false end
		local args = {}
		for i, a in ipairs(learned.args) do args[i] = a end
		args[learned.amountIndex] = amount
		-- any skipped (instance) args we couldn't persist -> drop cleanly if false
		firingLearned = true
		local ok = pcall(function()
			if learned.remote:IsA('RemoteFunction') then
				learned.remote:InvokeServer(unpack(args))
			else
				learned.remote:FireServer(unpack(args))
			end
		end)
		firingLearned = false
		return ok
	end

	-- best-effort blind deposit for when nothing has been learned yet: try the
	-- plausible action names + any alliance-named remote. NOT verifiable.
	local allianceRemote
	local function getAllianceRemote()
		if allianceRemote and allianceRemote.Parent then return allianceRemote end
		for _, r in replicatedStorage:GetDescendants() do
			if (r:IsA('RemoteEvent') or r:IsA('RemoteFunction')) then
				local nm = r.Name:lower()
				if nm:find('alliance') and (nm:find('deposit') or nm:find('bank') or nm:find('donate') or nm:find('manpower')) then
					allianceRemote = r return r
				end
			end
		end
		for _, r in replicatedStorage:GetDescendants() do
			if (r:IsA('RemoteEvent') or r:IsA('RemoteFunction')) and r.Name:lower():find('alliance') then
				allianceRemote = r return r
			end
		end
		return nil
	end
	local function blindDeposit(amount)
		local fired = false
		for _, action in { 'DepositManpower', 'AllianceDeposit', 'DepositToAlliance', 'DonateManpower', 'AllianceBankDeposit', 'BankDeposit' } do
			if fireAction(action, 'Manpower', amount) then fired = true end
			fireAction(action, amount)
		end
		local ar = getAllianceRemote()
		if ar then
			pcall(function()
				if ar:IsA('RemoteEvent') then
					ar:FireServer('Deposit', 'Manpower', amount)
					ar:FireServer('DepositManpower', amount)
				else
					ar:InvokeServer('Deposit', 'Manpower', amount)
				end
			end)
			fired = true
		end
		return fired
	end

	-- deposit `amount`, then VERIFY by re-reading manpower. Returns the actual amount
	-- that left your reserve (0 if nothing moved), and whether the learned call was used.
	local function deposit(mine, amount)
		amount = math.floor(amount)
		if amount <= 0 then return 0, false end
		local before = select(2, getBalance(mine)) or 0
		local usedLearned = fireLearned(amount)
		if not usedLearned then blindDeposit(amount) end
		task.wait(0.35)   -- let the server replicate the new manpower value back
		local after = select(2, getBalance(mine)) or before
		local moved = math.max(0, before - after)
		return moved, usedLearned
	end

	local function sweep()
		local mine = lplr:GetAttribute('MyCountry')
		if not mine then return end
		local _, manpower = getBalance(mine)
		if not manpower then return end
		local cap = manpowerCap(mine)
		local keep = (KeepReserve and KeepReserve.Value or 0) * 1e3

		-- "at max" = manpower has reached the threshold fraction of the cap. If no cap
		-- is known, fall back to: deposit anything above the keep-reserve.
		local trigger
		if cap then
			trigger = manpower >= cap * ((Threshold and Threshold.Value or 98) / 100)
		else
			trigger = manpower > keep
		end
		if not trigger then return end

		local overflow = manpower - keep
		if overflow <= 0 then return end

		local moved = deposit(mine, overflow)
		if moved > 0 then
			if Notify.Enabled then
				notif('Alliance Bank', string.format('Deposited %s manpower (was at %s%s)',
					fmtNum(moved), fmtNum(manpower), cap and ('/' .. fmtNum(cap)) or ''), 4, 'success')
			end
		elseif not learned and Notify.Enabled then
			-- honest failure: we fired blind and manpower did NOT drop
			notif('Alliance Bank',
				"Couldn't deposit -- the game's deposit call isn't known. Turn on \"Learn Deposit\", then deposit once manually so it can capture the real call.",
				7, 'warning')
		end
	end

	AutoAllianceBank = vain.Categories.Utility:CreateModule({
		Name = 'Auto Alliance Bank',
		Tooltip = "Once your country's manpower hits its cap it stops growing and is wasted -- this deposits the overflow into your alliance bank automatically. It finds your manpower cap from CountryRegistry (or use the manual cap if the game exposes none), and always keeps your reserve. Requires you to actually be in an alliance.",
		Function = function(callback)
			if callback then
				loadLearned()
				if LearnDeposit.Enabled then installLearnHook() end
				local mine = lplr:GetAttribute('MyCountry')
				local _, mp = getBalance(mine)
				local cap = manpowerCap(mine)
				notif('Auto Alliance Bank', string.format(
					'%s | manpower %s | cap %s | deposit call: %s',
					getActionRemote() and 'Action OK' or 'NO REMOTE',
					mp and fmtNum(mp) or '?',
					cap and fmtNum(cap) or 'UNKNOWN (set Manual Cap)',
					learned and ('LEARNED (' .. learned.remote.Name .. ')')
						or (LearnDeposit.Enabled and 'not learned yet -- deposit once manually'
							or 'unknown -- enable Learn Deposit')),
					8, (getActionRemote() and mp and (cap or (ManualCap and ManualCap.Value > 0)) and learned) and nil or 'warning')
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
		Tooltip = 'Deposit once manpower reaches this percent of your cap (100% = only when completely full).' })
	ManualCap = AutoAllianceBank:CreateSlider({ Name = 'Manual Cap', Min = 0, Max = 5000, Default = 0, Suffix = 'K',
		Tooltip = 'Only used if the game exposes no manpower cap value. Set your known max manpower (in thousands) so the module knows when you are full. Leave at 0 to auto-detect.' })
	Interval = AutoAllianceBank:CreateSlider({ Name = 'Interval', Min = 1, Max = 60, Default = 5, Suffix = 'sec',
		Tooltip = 'How often to check whether manpower has hit the cap.' })
	LearnDeposit = AutoAllianceBank:CreateToggle({ Name = 'Learn Deposit', Default = true,
		Function = function(on) if on then installLearnHook() end end,
		Tooltip = "The exact alliance-deposit call isn't known for this game. With this on, deposit manpower into your alliance bank MANUALLY once -- it captures the real remote + arguments and replays them automatically forever after (saved across rejoins)." })
	Notify = AutoAllianceBank:CreateToggle({ Name = 'Notify', Default = true,
		Tooltip = 'Notify each time it deposits manpower into the alliance bank (verified -- only fires if your manpower actually dropped).' })
end)

run(function()
	-- ── Highlight Owned ───────────────────────────────────────────────────────
	-- The Formables / transformation menu (PlayerGui.MainUI ... Formables) lists
	-- every transformation as an entry with a `LOCKED` frame holding a `Lock` image.
	-- An entry you OWN has that LOCKED frame hidden (or absent). We stamp a green
	-- check + outline on every owned entry so you can see at a glance which ones you
	-- already have, and strip the mark off locked ones. The menu rebuilds itself, so
	-- we re-apply on a light poll while the module is on.
	local HighlightOwned
	local CHECK_ICON = 'rbxassetid://6031094667' -- material "check_circle"
	local MARK_NAME  = 'VainOwnedMark'
	local marked = {}

	-- an "entry" is a frame that has BOTH a NAME label and a LOCKED frame beneath it
	-- (that's the shape every formable/reward row shares in this game's UI).
	local function isEntry(f)
		if not (f and f:IsA('GuiObject')) then return false end
		local hasName = f:FindFirstChild('NAME')
		local locked = f:FindFirstChild('LOCKED')
		return hasName ~= nil and locked ~= nil
	end

	-- owned = you already have / have transformed into this formable. The game does
	-- NOT always signal that the same way: the LOCKED frame may be hidden, OR the
	-- entry may keep its lock but carry an ownership flag / a "completed"-style tint /
	-- a done marker (that's why some already-transformed ones weren't being caught).
	-- We accept ANY of these signals.
	local function isOwned(entry)
		-- 1) explicit attribute the game may stamp when you own/completed it
		for _, k in { 'Owned', 'Completed', 'Complete', 'Done', 'Unlocked', 'Claimed', 'Formed', 'Active' } do
			if entry:GetAttribute(k) == true then return true end
		end
		local locked = entry:FindFirstChild('LOCKED')
		-- 2) no LOCKED frame at all, or it's hidden -> owned
		if not locked then return true end
		if locked:IsA('GuiObject') and locked.Visible == false then return true end
		-- 3) LOCKED present but its Lock icon is faded out / an attribute marks it done
		local lock = locked:FindFirstChild('Lock')
		if lock then
			if lock:IsA('ImageLabel') and lock.ImageTransparency >= 1 then return true end
			if lock:IsA('GuiObject') and lock.Visible == false then return true end
		end
		if locked:IsA('GuiObject') then
			-- fully transparent LOCKED overlay = shown-but-cleared
			if locked.BackgroundTransparency >= 1 and (not lock or (lock:IsA('ImageLabel') and lock.ImageTransparency >= 1)) then
				return true
			end
			-- some builds swap the lock for a checkmark / tick child on owned rows
			for _, d in locked:GetDescendants() do
				local nm = d.Name:lower()
				if nm:find('check') or nm:find('tick') or nm:find('owned') or nm:find('done') or nm:find('complete') then
					if not (d:IsA('GuiObject')) or d.Visible then return true end
				end
			end
		end
		-- 4) a Done/Owned/Check marker anywhere directly in the entry
		for _, d in entry:GetChildren() do
			local nm = d.Name:lower()
			if (nm:find('owned') or nm:find('check') or nm:find('done') or nm:find('complete') or nm:find('tick'))
				and (not d:IsA('GuiObject') or d.Visible) then
				return true
			end
		end
		return false
	end

	local function clearMark(entry)
		local m = entry:FindFirstChild(MARK_NAME)
		if m then m:Destroy() end
		local stroke = entry:FindFirstChild('VainOwnedStroke')
		if stroke then stroke:Destroy() end
	end

	local function addMark(entry)
		if entry:FindFirstChild(MARK_NAME) then return end
		-- green corner check badge
		local badge = Instance.new('ImageLabel')
		badge.Name = MARK_NAME
		badge.AnchorPoint = Vector2.new(1, 0)
		badge.Position = UDim2.new(1, -4, 0, 4)
		badge.Size = UDim2.fromOffset(22, 22)
		badge.BackgroundTransparency = 1
		badge.Image = CHECK_ICON
		badge.ImageColor3 = Color3.fromRGB(80, 220, 110)
		badge.ZIndex = 50
		badge.Parent = entry
		-- green outline so it reads even at a glance
		local stroke = Instance.new('UIStroke')
		stroke.Name = 'VainOwnedStroke'
		stroke.Color = Color3.fromRGB(80, 220, 110)
		stroke.Thickness = 2
		stroke.Transparency = 0.15
		stroke.Parent = entry
	end

	local function refresh()
		if not (HighlightOwned and HighlightOwned.Enabled) then return end
		local pg = lplr:FindFirstChild('PlayerGui')
		local mainui = pg and pg:FindFirstChild('MainUI')
		if not mainui then return end
		for _, d in ipairs(mainui:GetDescendants()) do
			if isEntry(d) then
				marked[d] = true
				if isOwned(d) then addMark(d) else clearMark(d) end
			end
		end
	end

	HighlightOwned = vain.Categories.Utility:CreateModule({
		Name = 'Highlight Owned',
		Tooltip = 'Puts a green check + outline on every transformation (formable) you already OWN in the transformation menu, so you can tell owned from locked at a glance.',
		Function = function(callback)
			if callback then
				refresh()
				HighlightOwned:Clean(task.spawn(function()
					while HighlightOwned.Enabled do
						refresh()
						task.wait(0.5)
					end
				end))
			else
				-- strip every mark we added
				for entry in marked do
					if entry and entry.Parent then clearMark(entry) end
				end
				table.clear(marked)
			end
		end
	})
end)

-- ══════════════════════════════════════════════════════════════════════════════
--  AUTO TRANSFORM  (claim every formable the instant it becomes available)
-- ══════════════════════════════════════════════════════════════════════════════
-- The Formables menu (PlayerGui.MainUI ... Formables) lists each transformation as
-- an entry with a `NAME` label and a `LOCKED` frame. Three states:
--   * OWNED     -> LOCKED frame hidden/absent            (already have it, skip)
--   * AVAILABLE -> requirements met but not yet claimed   (CLAIM IT)
--   * LOCKED    -> requirements unmet                     (skip, wait)
-- The game wires each entry's own button to its transform handler, so instead of
-- guessing a remote name we ACTIVATE the entry's button directly (fire its
-- click/Activated signal). That routes through the game's real transform logic and
-- the server validates the requirements anyway, so we can safely attempt any entry
-- that looks available and let the server accept the legitimate ones.
run(function()
	local AutoTransform
	local Interval, OnlyReady, Notify
	local attempted = {}   -- entry -> last attempt tick (don't spam the same one)

	-- same entry shape as Highlight Owned
	local function isEntry(f)
		if not (f and f:IsA('GuiObject')) then return false end
		return f:FindFirstChild('NAME') ~= nil and f:FindFirstChild('LOCKED') ~= nil
	end

	-- OWNED = the LOCKED frame is hidden/absent (game removes it once you have it)
	local function isOwned(entry)
		local locked = entry:FindFirstChild('LOCKED')
		if not locked then return true end
		if locked:IsA('GuiObject') and locked.Visible == false then return true end
		local lock = locked:FindFirstChild('Lock')
		if lock and lock:IsA('ImageLabel') and lock.ImageTransparency >= 1 then return true end
		return false
	end

	-- AVAILABLE = requirements are MET but you don't own it yet. Formable UIs signal
	-- "claimable" by recolouring the entry / lock (green tint) or exposing a claim
	-- button. We treat an entry as available when it is NOT owned and shows any
	-- ready signal: a greenish lock/entry colour, a visible claim/transform button,
	-- or an explicit 'CanForm'/'Available'/'Ready' attribute set truthy.
	local function looksGreen(c)
		return c and c.G > 0.5 and c.G > c.R * 1.15 and c.G > c.B * 1.15
	end
	local function isAvailable(entry)
		-- explicit attribute wins if the game exposes one
		for _, k in { 'CanForm', 'Available', 'Ready', 'Claimable', 'Unlocked' } do
			local v = entry:GetAttribute(k)
			if v == true then return true end
			if v == false then return false end
		end
		-- a visible button literally labelled to claim/transform
		for _, d in entry:GetDescendants() do
			if (d:IsA('TextButton') or d:IsA('ImageButton')) and d.Visible then
				local t = (d:IsA('TextButton') and d.Text or ''):lower()
				if t:find('form') or t:find('transform') or t:find('claim') or t:find('unite') then
					return true
				end
			end
		end
		-- green tint on the LOCKED frame or its lock icon = requirements met
		local locked = entry:FindFirstChild('LOCKED')
		if locked and locked:IsA('GuiObject') then
			if looksGreen(locked.BackgroundColor3) then return true end
			local lock = locked:FindFirstChild('Lock')
			if lock and lock:IsA('ImageLabel') and looksGreen(lock.ImageColor3) then return true end
		end
		return false
	end

	-- find the clickable actuator inside an entry and fire it through the game's own
	-- handler. Prefer a real Button (fire its Activated / MouseButton1Click); fall
	-- back to a SelectionButton or the entry itself if it is a button.
	local function activate(entry)
		local btns = {}
		if entry:IsA('TextButton') or entry:IsA('ImageButton') then table.insert(btns, entry) end
		for _, d in entry:GetDescendants() do
			if (d:IsA('TextButton') or d:IsA('ImageButton')) and d.Visible then
				table.insert(btns, d)
			end
		end
		local fired = false
		for _, b in btns do
			-- firesignal / fireproximityprompt-style click on the button's events
			local ok = pcall(function()
				if type(firesignal) == 'function' then
					firesignal(b.MouseButton1Click)
					firesignal(b.Activated)
				elseif type(getconnections) == 'function' then
					for _, con in getconnections(b.MouseButton1Click) do
						if con.Fire then con:Fire() elseif con.Function then con.Function() end
					end
					for _, con in getconnections(b.Activated) do
						if con.Fire then con:Fire() elseif con.Function then con.Function() end
					end
				end
			end)
			if ok then fired = true end
		end
		return fired
	end

	local function formablesRoots()
		local pg = lplr:FindFirstChild('PlayerGui')
		local mainui = pg and pg:FindFirstChild('MainUI')
		if not mainui then return nil end
		return mainui
	end

	local function sweep()
		local root = formablesRoots()
		if not root then return 0, 0 end
		local now = tick()
		local claimed, seen = 0, 0
		for _, d in root:GetDescendants() do
			if isEntry(d) and not isOwned(d) then
				seen += 1
				local ready = isAvailable(d)
				-- OnlyReady off = also try locked ones (server rejects unmet, harmless)
				if ready or not OnlyReady.Enabled then
					if not attempted[d] or (now - attempted[d]) > 5 then
						attempted[d] = now
						if activate(d) then
							claimed += 1
							if Notify.Enabled then
								local nm = d:FindFirstChild('NAME')
								local label = (nm and nm:IsA('TextLabel') and nm.Text) or d.Name
								notif('Auto Transform', 'Claiming ' .. tostring(label), 3, 'success')
							end
							task.wait(0.25)
						end
					end
				end
			end
		end
		return claimed, seen
	end

	AutoTransform = vain.Categories.Utility:CreateModule({
		Name = 'Auto Transform',
		Tooltip = 'Automatically claims every transformation (formable) the instant it becomes available -- it watches the transformation menu and activates any formable whose requirements you have met but that you have not yet unlocked. Leave "Only When Ready" on so it only claims ones actually available; turn it off to also attempt locked ones (the server just ignores unmet requirements).',
		Function = function(callback)
			if callback then
				local root = formablesRoots()
				local _, seen = sweep()
				notif('Auto Transform', string.format(
					'%s | unowned formables visible: %d%s',
					root and 'Menu OK' or 'OPEN THE TRANSFORM MENU',
					seen, root and '' or ' (open it once so the entries load)'),
					7, root and nil or 'warning')
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
	OnlyReady = AutoTransform:CreateToggle({ Name = 'Only When Ready', Default = true,
		Tooltip = 'Only claim formables the UI shows as available (requirements met). Turn OFF to also attempt locked ones -- the server ignores any whose requirements you have not met.' })
	Notify = AutoTransform:CreateToggle({ Name = 'Notify', Default = true,
		Tooltip = 'Notify when it claims a transformation.' })
end)
