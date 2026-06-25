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
--  AUTO WAR  (justify + declare war on the countries you list, or everyone)
-- ══════════════════════════════════════════════════════════════════════════════
run(function()
	local AutoWar, Targets, TargetAll, AutoDeclare, Interval

	local myCountry = lplr:GetAttribute('MyCountry')

	-- Check if WE are already at war with a specific country by looking at our
	-- own JustifyingWars / InWarWith data on the CountryRegistry entry for us.
	-- Fallback: if our country entry has an InWarWith child listing them, or their
	-- entry lists us. If nothing found, assume not at war so we keep trying.
	local function atWarWith(name)
		local reg = replicatedStorage:FindFirstChild('CountryRegistry')
		if not reg then return false end
		-- check our own entry's war list
		local myCf = reg:FindFirstChild(myCountry or '')
		if myCf then
			local inWarWith = myCf:FindFirstChild('InWarWith')
			if inWarWith then
				for _, v in inWarWith:GetChildren() do
					if v.Value == name or v.Name == name then return true end
				end
			end
			-- some versions store it as an attribute table
			local attr = myCf:GetAttribute('InWarWith')
			if type(attr) == 'string' and attr:find(name) then return true end
		end
		-- check their entry
		local theirCf = reg:FindFirstChild(name)
		if theirCf then
			local inWarWith = theirCf:FindFirstChild('InWarWith')
			if inWarWith then
				for _, v in inWarWith:GetChildren() do
					if v.Value == myCountry or v.Name == myCountry then return true end
				end
			end
		end
		return false
	end

	-- countries that still have at least one tile NOT owned by us (i.e. not conquered)
	local function allCountries()
		local reg = replicatedStorage:FindFirstChild('CountryRegistry')
		local out = {}
		if not reg then return out end
		local mine = lplr:GetAttribute('MyCountry')
		local regions = workspace:FindFirstChild('Regions')
		-- build a set of countries that still own at least one tile
		local stillExist = {}
		if regions then
			for _, tile in regions:GetChildren() do
				local c = tile:GetAttribute('Country')
				if c and c ~= mine then stillExist[c] = true end
			end
		end
		for _, cf in reg:GetChildren() do
			if cf.Name ~= mine and stillExist[cf.Name] then
				table.insert(out, cf.Name)
			end
		end
		return out
	end

	local function sweep()
		if not getActionRemote() then return end
		myCountry = lplr:GetAttribute('MyCountry')
		local targets = TargetAll and TargetAll.Enabled
			and allCountries()
			or (Targets and Targets.ListEnabled or {})

		for _, name in targets do
			if not AutoWar.Enabled then break end
			if name == '' or name == myCountry then continue end
			if atWarWith(name) then continue end
			fireAction('JustifyWar', name)
			task.wait(0.4)
			if AutoDeclare and AutoDeclare.Enabled then
				fireAction('DeclareWar', name)
				task.wait(0.4)
			end
		end
	end

	AutoWar = vain.Categories.Utility:CreateModule({
		Name = 'Auto War',
		Function = function(callback)
			if callback then
				-- one-time diagnostic
				myCountry = lplr:GetAttribute('MyCountry')
				local reg = replicatedStorage:FindFirstChild('CountryRegistry')
				notif('Auto War', string.format('Remote: %s | Country: %s | Registry countries: %d',
					getActionRemote() and 'OK' or 'NOT FOUND',
					tostring(myCountry),
					reg and #reg:GetChildren() or 0), 6,
					(getActionRemote() and myCountry) and nil or 'warning')
				task.spawn(function()
					repeat
						sweep()
						task.wait(Interval and Interval.Value or 8)
					until not AutoWar.Enabled
				end)
			end
		end,
		Tooltip = 'Justifies and declares war on every country in your target list (or everyone on the server with Target All). Keeps retrying on the interval until all targets are at war.'
	})
	TargetAll = AutoWar:CreateToggle({ Name = 'Target All', Default = false,
		Tooltip = 'Ignore the target list and justify+declare on EVERY other country currently in the server.' })
	Targets = AutoWar:CreateTextList({ Name = 'Targets',
		Tooltip = 'Exact country names to war (one per entry). Ignored when Target All is on.' })
	AutoDeclare = AutoWar:CreateToggle({ Name = 'Auto Declare', Default = true,
		Tooltip = 'Also fire DeclareWar immediately after justifying. Turn off to only justify.' })
	Interval = AutoWar:CreateSlider({ Name = 'Retry', Min = 2, Max = 60, Default = 8, Suffix = 'sec',
		Tooltip = 'How often to re-sweep and retry any targets not yet at war.' })
end)

-- ══════════════════════════════════════════════════════════════════════════════
--  AUTO DEFENSE  (garrison borders + reinforce tiles under attack)
-- ══════════════════════════════════════════════════════════════════════════════
-- Confirmed from the place file:
--   * tiles live in workspace.Regions (cached as _G.regionsChildren). Owned when
--     GetAttribute('Country') == MyCountry. CANNOT spawn on a tile whose
--     'OccupiedFrom' attribute is set (server rejects it -> "occupied territory").
--   * geometry is the tile's GeneratedRegion model (pivot = tile centre).
--   * soldiers live in workspace.SoldiersFolder, each has a 'Country' attribute and
--     a 'LastFightTick' that updates while it is in combat.
--   * spawn: Network:FireServer('CreateArmyOnTile', tileInstance, unitTypeString, count)
run(function()
	local AutoDefense, UnitType, Garrison, ReinforceAmt, DefendBattles, MoneyReserve, ManpowerReserve, Interval, Cooldown, Notify

	-- the exact list the game iterates, with a fallback if it hasn't populated yet
	local function regionTiles()
		if type(_G.regionsChildren) == 'table' and #_G.regionsChildren > 0 then
			return _G.regionsChildren
		end
		local r = workspace:FindFirstChild('Regions')
		return r and r:GetChildren() or {}
	end
	local function soldiersFolder() return workspace:FindFirstChild('SoldiersFolder') end

	local function tilePos(t)
		local geo = t:FindFirstChild('GeneratedRegion') or t
		local ok, p = pcall(function() return geo:GetPivot().Position end)
		if ok and p then return p end
		local bp = (geo:IsA('BasePart') and geo) or geo:FindFirstChildWhichIsA('BasePart', true)
		return bp and bp.Position or nil
	end
	-- I own it and it is not occupied (occupied tiles can't have armies spawned)
	local function spawnable(t, mine)
		return t:GetAttribute('Country') == mine and t:GetAttribute('OccupiedFrom') == nil
	end

	-- typical tile spacing = median nearest-neighbour distance. Computed once and
	-- cached; used as the adjacency threshold for "is this an enemy border".
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

	-- snapshot every tile once per sweep: position, ownership, spawnability
	local function snapshotTiles(mine)
		local all = {}
		for _, t in regionTiles() do
			local p = tilePos(t)
			if p then
				table.insert(all, {
					tile = t, pos = p,
					mine = t:GetAttribute('Country') == mine,
					canSpawn = spawnable(t, mine),
				})
			end
		end
		return all
	end

	-- my spawnable tiles that sit next to a tile I don't own (the frontier)
	local function borderTiles(all)
		local thresh = adjacencyDist(all) * 1.5
		local out = {}
		for _, o in all do
			if o.canSpawn then
				for _, x in all do
					if not x.mine and (o.pos - x.pos).Magnitude <= thresh then
						table.insert(out, o.tile)
						break
					end
				end
			end
		end
		return out
	end

	-- my spawnable tiles that are under attack: an enemy soldier is sitting on/next
	-- to them, OR one of my soldiers there is currently fighting (LastFightTick).
	local function attackedTiles(all, mine)
		local sf = soldiersFolder()
		if not sf then return {} end
		local thresh = adjacencyDist(all)
		local now = tick()
		local threats = {}  -- positions of enemy or actively-fighting soldiers
		for _, s in sf:GetChildren() do
			local sc = s:GetAttribute('Country')
			local enemy = sc and sc ~= mine
			local lf = s:GetAttribute('LastFightTick')
			local fighting = type(lf) == 'number' and (now - lf) < 6
			if enemy or fighting then
				local ok, sp = pcall(function() return s:GetPivot().Position end)
				if ok and sp then table.insert(threats, sp) end
			end
		end
		if #threats == 0 then return {} end
		local out = {}
		for _, o in all do
			if o.canSpawn then
				for _, tp in threats do
					if (o.pos - tp).Magnitude <= thresh * 1.2 then
						table.insert(out, o.tile)
						break
					end
				end
			end
		end
		return out
	end

	-- don't re-spend on the same tile every single sweep
	local lastSpawn = {}

	local function sweep()
		local mine = lplr:GetAttribute('MyCountry')
		if not (mine and getActionRemote()) then return end
		local moneyReserve = (MoneyReserve.Value or 0) * 1e6
		local mpReserve    = (ManpowerReserve.Value or 0) * 1e3
		local unit     = (UnitType and UnitType.Value) or 'Soldier'
		local garrison = math.floor(Garrison.Value)
		local reinAmt  = math.floor(ReinforceAmt.Value)
		local cd       = Cooldown and Cooldown.Value or 20
		local reinforced, garrisoned = 0, 0

		local function canSpend()
			local m, p = getBalance(mine)
			if m and m <= moneyReserve then return false end
			if p and p <= mpReserve then return false end
			return true
		end
		local function spawn(tile, count, force)
			local now = tick()
			if not force and lastSpawn[tile] and (now - lastSpawn[tile]) < cd then return false end
			if not canSpend() then return false end
			lastSpawn[tile] = now
			fireAction('CreateArmyOnTile', tile, unit, count)
			task.wait(0.15)
			return true
		end

		local all = snapshotTiles(mine)

		-- 1) emergency reinforce: tiles under attack (ignores cooldown, bigger batch)
		if DefendBattles.Enabled then
			for _, t in attackedTiles(all, mine) do
				if not AutoDefense.Enabled then break end
				if spawn(t, reinAmt, true) then reinforced += 1 end
			end
		end
		-- 2) garrison the frontier (respects cooldown)
		for _, t in borderTiles(all) do
			if not AutoDefense.Enabled then break end
			if spawn(t, garrison, false) then garrisoned += 1 end
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
				local mine = lplr:GetAttribute('MyCountry')
				local all  = snapshotTiles(mine)
				local owned, spawnTiles = 0, 0
				for _, o in all do
					if o.mine then owned += 1 end
					if o.canSpawn then spawnTiles += 1 end
				end
				notif('Auto Defense', string.format('%s | tiles %d | mine %d | spawnable %d | borders %d | soldiers %s',
					getActionRemote() and 'Remote OK' or 'NO REMOTE',
					#all, owned, spawnTiles, #borderTiles(all),
					soldiersFolder() and 'OK' or 'MISSING'), 8,
					(getActionRemote() and mine and spawnTiles > 0) and nil or 'warning')
				task.spawn(function()
					repeat
						sweep()
						task.wait(Interval and Interval.Value or 8)
					until not AutoDefense.Enabled
				end)
			end
		end,
		Tooltip = 'Stations troops on your border tiles and emergency-reinforces any owned tile under attack. Only spawns on tiles you actually own (skips occupied territory) and never moves onto enemy land.'
	})
	UnitType = AutoDefense:CreateDropdown({ Name = 'Unit',
		List = { 'Soldier', 'Tank', 'Artillery', 'AntiAircraft' }, Default = 'Soldier' })
	Garrison = AutoDefense:CreateSlider({ Name = 'Garrison Size', Min = 1, Max = 500, Default = 10,
		Tooltip = 'Units to keep on each border tile.' })
	ReinforceAmt = AutoDefense:CreateSlider({ Name = 'Reinforce Size', Min = 1, Max = 500, Default = 25,
		Tooltip = 'Units to rush to a tile that is under attack.' })
	DefendBattles = AutoDefense:CreateToggle({ Name = 'Reinforce Battles', Default = true,
		Tooltip = 'Rush reinforcements to any owned tile with an enemy soldier on it or active combat.' })
	MoneyReserve = AutoDefense:CreateSlider({ Name = 'Money Reserve', Min = 0, Max = 500, Default = 5, Suffix = 'M' })
	ManpowerReserve = AutoDefense:CreateSlider({ Name = 'Manpower Reserve', Min = 0, Max = 1000, Default = 20, Suffix = 'K' })
	Interval = AutoDefense:CreateSlider({ Name = 'Interval', Min = 1, Max = 60, Default = 8, Suffix = 'sec',
		Tooltip = 'How often to re-check borders and battles.' })
	Cooldown = AutoDefense:CreateSlider({ Name = 'Re-garrison Cooldown', Min = 0, Max = 120, Default = 20, Suffix = 'sec',
		Tooltip = 'Minimum time before topping up the same border tile again (battles ignore this).' })
	Notify = AutoDefense:CreateToggle({ Name = 'Notify', Default = false })
end)

-- ══════════════════════════════════════════════════════════════════════════════
--  AUTO TRAIN UNIT  (spawn a chosen unit on your capital/chosen tile repeatedly)
-- ══════════════════════════════════════════════════════════════════════════════
run(function()
	local AutoTrain, UnitType, BatchSize, ManpowerReserve, MoneyReserve, Interval, Notify

	-- the canonical tile list the game iterates, with a fallback
	local function regionTiles()
		if type(_G.regionsChildren) == 'table' and #_G.regionsChildren > 0 then
			return _G.regionsChildren
		end
		local r = workspace:FindFirstChild('Regions')
		return r and r:GetChildren() or {}
	end

	-- Pick a tile we can actually spawn on: owned (Country==mine) and NOT occupied
	-- ('OccupiedFrom' set means the server rejects the spawn). Prefer Capital, then a
	-- Core tile, then any valid owned tile. Re-evaluated each sweep.
	local function spawnTile()
		local mine = lplr:GetAttribute('MyCountry')
		if not mine then return nil end
		local capital, core, any
		for _, tile in regionTiles() do
			if tile:GetAttribute('Country') == mine and tile:GetAttribute('OccupiedFrom') == nil then
				any = any or tile
				if tile:GetAttribute('Core') then core = core or tile end
				if tile:GetAttribute('Capital') or tile:GetAttribute('IsCapital') then capital = tile end
			end
		end
		return capital or core or any
	end

	local function sweep()
		local mine = lplr:GetAttribute('MyCountry')
		if not (mine and getActionRemote()) then return end
		local moneyReserve = (MoneyReserve.Value or 0) * 1e6
		local mpReserve    = (ManpowerReserve.Value or 0) * 1e3
		local unit  = (UnitType and UnitType.Value) or 'Soldier'
		local batch = math.floor(BatchSize and BatchSize.Value or 10)
		local money, mp = getBalance(mine)
		if money and money <= moneyReserve then return end
		if mp    and mp    <= mpReserve    then return end
		local tile = spawnTile()
		if not tile then
			notif('Auto Train', 'No owned tile found to spawn on.', 4, 'warning')
			return
		end
		-- Fire regardless of SpawningArmy state so the server queues successive batches
		fireAction('CreateArmyOnTile', tile, unit, batch)
		if Notify.Enabled then
			notif('Auto Train', string.format('Fired %d %s on %s', batch, unit, tile.Name), 3)
		end
	end

	AutoTrain = vain.Categories.Utility:CreateModule({
		Name = 'Auto Train Unit',
		Function = function(callback)
			if callback then
				local tile = spawnTile()
				local mine = lplr:GetAttribute('MyCountry')
				local money, mp = getBalance(mine)
				notif('Auto Train', string.format('Remote: %s | Tile: %s | Money: %s | MP: %s',
					getActionRemote() and 'OK' or 'NOT FOUND',
					tile and tile.Name or 'none',
					money and string.format('%.1fm', money/1e6) or '?',
					mp and tostring(math.floor(mp)) or '?'), 6,
					(getActionRemote() and tile) and nil or 'warning')
				task.spawn(function()
					repeat
						sweep()
						task.wait(Interval and Interval.Value or 5)
					until not AutoTrain.Enabled
				end)
			end
		end,
		Tooltip = 'Automatically trains your chosen unit on your capital (or any owned tile) every interval, as long as you can afford it and stay above your reserves.'
	})
	UnitType = AutoTrain:CreateDropdown({
		Name = 'Unit Type',
		List = { 'Soldier', 'Tank', 'Artillery', 'AntiAircraft', 'Plane', 'Battleship', 'Missile Launcher', 'Aircraft Carrier' },
		Tooltip = 'Which unit to train each interval.'
	})
	BatchSize = AutoTrain:CreateSlider({ Name = 'Batch Size', Min = 1, Max = 500, Default = 10,
		Tooltip = 'How many units to spawn per interval.' })
	MoneyReserve = AutoTrain:CreateSlider({ Name = 'Money Reserve', Min = 0, Max = 500, Default = 5, Suffix = 'M',
		Tooltip = 'Never spend money below this.' })
	ManpowerReserve = AutoTrain:CreateSlider({ Name = 'Manpower Reserve', Min = 0, Max = 1000, Default = 20, Suffix = 'K',
		Tooltip = 'Never spend manpower below this.' })
	Interval = AutoTrain:CreateSlider({ Name = 'Interval', Min = 1, Max = 60, Default = 1, Suffix = 'sec',
		Tooltip = 'How often to check if the tile is free and queue the next batch. Keep at 1s to re-queue instantly after the previous spawn finishes.' })
	Notify = AutoTrain:CreateToggle({ Name = 'Notify', Default = false,
		Tooltip = 'Show a notification each time a batch is trained.' })
end)
