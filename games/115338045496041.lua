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
--  AUTO WAR  (smart: justify then declare, never on allies / alliance-mates)
-- ══════════════════════════════════════════════════════════════════════════════
-- CONFIRMED from the decompiled place file:
--   * War is a TWO-STEP action, both fired through the game's action remote:
--       FireServer("JustifyWar",  <country>)   -- start justification (costs PP)
--       FireServer("DeclareWar",  <country>)   -- declare once justified
--   * A justification is IN PROGRESS while
--       CountryRegistry[MyCountry].JustifyingWars.<target>  exists, and it is
--     READY TO DECLARE when  workspace:GetServerTimeNow() >= that value's "END"
--     attribute (decoded from CityInfo War button, Line ~2050).
--   * NEVER-WAR relationships:
--       - same ALLIANCE: ReplicatedStorage.Alliances.<a>.Members.<country> -- two
--         countries in the same alliance can't war (game's InAlliance check, Line 426).
--       - ALLIES: CountryRegistry[MyCountry].Allies.<country> (the FormAlly relation).
--   * Already at war: ReplicatedStorage.WarsData.<war>.SideA/SideB hold the country
--     names on each side; if the target is on the opposite side of any war we skip it.
--   * Country list for the filter comes from CountryRegistry:GetChildren().
run(function()
	local AutoWar
	local FilterMode, CountryList, Target, MinTiles, OnlyWeaker, Interval, Notify

	local alliancesFolder
	local function getAlliances()
		if not (alliancesFolder and alliancesFolder.Parent) then
			alliancesFolder = replicatedStorage:FindFirstChild('Alliances')
		end
		return alliancesFolder
	end
	-- which alliance folder a country belongs to (or nil) -- mirrors game's InAlliance
	local function allianceOf(country)
		local al = getAlliances()
		if not al then return nil end
		for _, child in al:GetChildren() do
			local members = child:FindFirstChild('Members')
			if members and members:FindFirstChild(country) then return child end
		end
		return nil
	end

	-- my declared allies (FormAlly relation), as a set
	local function myAllies()
		local set = {}
		local mine = lplr:GetAttribute('MyCountry')
		local cf = mine and countryFolder(mine)
		local allies = cf and cf:FindFirstChild('Allies')
		if allies then
			for _, c in allies:GetChildren() do set[c.Name] = true end
		end
		return set
	end

	-- am I already at war with `country`? (opposite sides of any WarsData entry)
	local function alreadyAtWar(mine, country)
		local wd = replicatedStorage:FindFirstChild('WarsData')
		if not wd then return false end
		for _, war in wd:GetChildren() do
			local a = war:FindFirstChild('SideA')
			local b = war:FindFirstChild('SideB')
			if a and b then
				local mineA = a:FindFirstChild(mine) ~= nil
				local mineB = b:FindFirstChild(mine) ~= nil
				local themA = a:FindFirstChild(country) ~= nil
				local themB = b:FindFirstChild(country) ~= nil
				if (mineA and themB) or (mineB and themA) then return true end
			end
		end
		return false
	end

	-- justification state on a country I'm justifying against:
	--   nil       -> not justifying
	--   'pending' -> justifying, not ready yet
	--   'ready'   -> justified, can declare now
	local function justifyState(mine, country)
		local cf = countryFolder(mine)
		local jw = cf and cf:FindFirstChild('JustifyingWars')
		local entry = jw and jw:FindFirstChild(country)
		if not entry then return nil end
		local endT = entry:GetAttribute('END')
		if endT and workspace:GetServerTimeNow() >= endT then return 'ready' end
		return 'pending'
	end

	-- may I war this country at all? (not me, not ally, not same alliance)
	local function warAllowed(mine, country)
		if not country or country == mine then return false end
		if myAllies()[country] then return false end
		local myAl = allianceOf(mine)
		if myAl and allianceOf(country) == myAl then return false end
		return true
	end

	-- parse the comma/space separated country textbox into a set (case-insensitive)
	local function filterSet()
		local set = {}
		local raw = CountryList and CountryList.Value or ''
		for name in string.gmatch(raw, '[^,]+') do
			local n = name:gsub('^%s+', ''):gsub('%s+$', '')
			if #n > 0 then set[n:lower()] = true end
		end
		return set
	end

	-- does the filter permit warring this country?
	--   Off        -> any allowed country
	--   Whitelist  -> only countries in the list
	--   Blacklist  -> any allowed country EXCEPT those in the list
	local function passesFilter(country)
		local mode = FilterMode and FilterMode.Value or 'Off'
		if mode == 'Off' then return true end
		local inList = filterSet()[country:lower()] == true
		if mode == 'Whitelist' then return inList end
		if mode == 'Blacklist' then return not inList end
		return true
	end

	-- GROUND-TRUTH tile ownership: count how many tiles in workspace.Regions each
	-- country actually owns right now. A conquered/annexed country owns ZERO tiles
	-- and no longer exists as a target -- gating on this stops Auto War declaring on
	-- countries that have already been taken over (the CountryRegistry folder can
	-- linger with stale data, so we don't trust it for existence). Built once/sweep.
	local function liveTileCounts()
		local counts = {}
		local regions = workspace:FindFirstChild('Regions')
		if regions then
			for _, tile in regions:GetChildren() do
				local owner = tile:GetAttribute('Country')
				if owner then counts[owner] = (counts[owner] or 0) + 1 end
			end
		end
		return counts
	end

	-- a country EXISTS (is a valid war target) only if it currently owns a tile
	local function exists(country, counts)
		return (counts[country] or 0) > 0
	end

	-- candidate targets, in priority order (weakest first when OnlyWeaker/Target set)
	local function candidates(mine)
		local reg = replicatedStorage:FindFirstChild('CountryRegistry')
		if not reg then return {} end
		local counts = liveTileCounts()
		local myTiles = counts[mine] or 0
		local minTiles = MinTiles and MinTiles.Value or 0
		local out = {}
		-- explicit single Target overrides everything if set -- but still only if it
		-- actually exists on the map
		local target = Target and Target.Value or ''
		target = target:gsub('^%s+', ''):gsub('%s+$', '')
		if #target > 0 then
			if exists(target, counts) then out[#out + 1] = target end
			return out
		end
		for _, cf in reg:GetChildren() do
			local c = cf.Name
			if exists(c, counts) and warAllowed(mine, c) and passesFilter(c) then
				local t = counts[c]
				if t >= minTiles then
					if not (OnlyWeaker and OnlyWeaker.Enabled) or t <= myTiles then
						out[#out + 1] = c
					end
				end
			end
		end
		-- weakest first so we pick off easy wins
		table.sort(out, function(a, b) return (counts[a] or 0) < (counts[b] or 0) end)
		return out
	end

	local function sweep()
		local mine = lplr:GetAttribute('MyCountry')
		if not (mine and getActionRemote()) then return end

		local counts = liveTileCounts()

		-- 1) advance any justification that is READY -> declare it (skip ghosts that
		--    got conquered while we were justifying)
		local cf = countryFolder(mine)
		local jw = cf and cf:FindFirstChild('JustifyingWars')
		if jw then
			for _, entry in jw:GetChildren() do
				local country = entry.Name
				if exists(country, counts) and warAllowed(mine, country)
					and justifyState(mine, country) == 'ready' and not alreadyAtWar(mine, country) then
					fireAction('DeclareWar', country)
					if Notify.Enabled then notif('Auto War', 'Declared war on ' .. country, 4, 'alert') end
					task.wait(0.4)
				end
			end
		end

		-- 2) start justifying the next best target if we aren't already
		for _, country in candidates(mine) do
			if not AutoWar.Enabled then break end
			if not alreadyAtWar(mine, country) then
				local st = justifyState(mine, country)
				if st == nil then
					fireAction('JustifyWar', country)
					if Notify.Enabled then notif('Auto War', 'Justifying war against ' .. country, 3) end
					task.wait(0.4)
					break   -- one new justification at a time (PP is limited)
				elseif st == 'ready' then
					fireAction('DeclareWar', country)
					if Notify.Enabled then notif('Auto War', 'Declared war on ' .. country, 4, 'alert') end
					task.wait(0.4)
					break
				end
			end
		end
	end

	AutoWar = vain.Categories.Utility:CreateModule({
		Name = 'Auto War',
		Tooltip = "Automatically justifies and then declares wars for you. It NEVER targets your allies or anyone in your alliance, and skips countries you're already at war with. Use Filter Mode + the country list to whitelist (only these) or blacklist (everyone but these), or set a single Target. Justifies one war at a time (political power is limited) and declares each as soon as its justification finishes.",
		Function = function(callback)
			if callback then
				local mine = lplr:GetAttribute('MyCountry')
				local n = #candidates(mine)
				notif('Auto War', string.format('%s | country %s | valid targets: %d%s',
					getActionRemote() and 'Remote OK' or 'NO REMOTE',
					tostring(mine), n,
					(FilterMode and FilterMode.Value ~= 'Off') and (' (' .. FilterMode.Value .. ')') or ''),
					7, (getActionRemote() and mine) and nil or 'warning')
				AutoWar:Clean(task.spawn(function()
					while AutoWar.Enabled do
						sweep()
						task.wait(Interval and Interval.Value or 8)
					end
				end))
			end
		end
	})

	FilterMode = AutoWar:CreateDropdown({ Name = 'Filter Mode',
		List = { 'Off', 'Whitelist', 'Blacklist' }, Default = 'Off',
		Tooltip = "Off = war any valid country. Whitelist = ONLY war countries in the list below. Blacklist = war everyone valid EXCEPT the ones in the list. (Allies / alliance-mates are always protected regardless.)" })
	CountryList = AutoWar:CreateTextBox({ Name = 'Countries',
		Default = '',
		Tooltip = 'Comma-separated country names for the whitelist / blacklist, e.g. "France, Spain, Poland". Case-insensitive. Ignored when Filter Mode is Off.' })
	Target = AutoWar:CreateTextBox({ Name = 'Single Target',
		Default = '',
		Tooltip = 'Optional. Type ONE country name to war only that country (overrides the filter and target-picking). Leave empty to auto-pick targets.' })
	OnlyWeaker = AutoWar:CreateToggle({ Name = 'Only Weaker', Default = true,
		Tooltip = 'Only auto-pick countries with no more tiles than you, so you punch down instead of starting wars you will lose.' })
	MinTiles = AutoWar:CreateSlider({ Name = 'Min Tiles', Min = 0, Max = 200, Default = 0,
		Tooltip = 'Ignore auto-picked countries smaller than this many tiles (skip tiny irrelevant states).' })
	Interval = AutoWar:CreateSlider({ Name = 'Interval', Min = 2, Max = 60, Default = 8, Suffix = 'sec',
		Tooltip = 'How often to advance justifications and start the next war.' })
	Notify = AutoWar:CreateToggle({ Name = 'Notify', Default = true,
		Tooltip = 'Notify when it justifies or declares a war.' })
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
	-- CONFIRMED from the decompiled place file. Rather than guess the live UI's
	-- element states, we compute readiness the way the game does -- from the
	-- ReplicatedStorage data modules `Formables` and `CountryData` plus region
	-- ownership -- and then mark the matching menu entries. Each rendered entry has
	-- Button.NAME.Text == (formable.DN or key) and a "DN" attribute, so we map an
	-- entry back to its formable by that name. States we mark:
	--   * READY   -> you own every required region & are allowed -> green check
	--   * CURRENT -> the formable your country is transformed into now -> blue star
	-- (This game keeps no persistent "formed in the past" flag, so past transforms
	-- cannot be shown -- only the current one.)
	local HighlightFormables
	local MarkReady, MarkCurrent, DimLocked
	local CHECK_ICON = 'rbxassetid://6031094667'
	local STAR_ICON  = 'rbxassetid://6031068421'
	local GREEN = Color3.fromRGB(80, 220, 110)
	local BLUE  = Color3.fromRGB(65, 150, 255)
	local marked = {}

	local formablesMod, countryMod
	local function findModule(name)
		local m = replicatedStorage:FindFirstChild(name, true)
		return (m and m:IsA('ModuleScript')) and m or nil
	end
	local function loadFormables()
		if not formablesMod then formablesMod = findModule('Formables') end
		local ok, data = pcall(function() return require(formablesMod) end)
		return ok and data or nil
	end

	local function currentTransform(country)
		local cf = countryFolder(country)
		return cf and cf:GetAttribute('TRANSFORMEDINTO') or nil
	end
	local function ownsAllRegions(v, myCountry)
		local regions = workspace:FindFirstChild('Regions')
		if not regions then return false end
		if not (v.CountriesREQ or v.CitiesREQ) then return true end
		for _, tile in regions:GetChildren() do
			if tile:GetAttribute('Country') ~= myCountry then
				local core = tile:GetAttribute('Core')
				if (v.CountriesREQ and core ~= nil and table.find(v.CountriesREQ, core))
					or (v.CitiesREQ and table.find(v.CitiesREQ, tile.Name)) then
					return false
				end
			end
		end
		return true
	end
	-- readySet[displayName] = true for every formable you can transform into now;
	-- curName = the display name of your current transform (or nil)
	local function computeReady(myCountry)
		local formables = loadFormables()
		local ready, curName = {}, nil
		if not formables then return ready, curName end
		local cur = currentTransform(myCountry)
		for i, v in formables do
			local dn = v.DN or i
			if cur == i then curName = dn end
			local allowed = not v.WhoCanForm or table.find(v.WhoCanForm, myCountry)
			if allowed and cur ~= i and not v.SPECIAL and ownsAllRegions(v, myCountry) then
				ready[tostring(dn)] = true
			end
		end
		return ready, curName
	end

	-- resolve a menu entry to its formable display name
	local function entryName(entry)
		local dn = entry:GetAttribute('DN')
		if dn then return tostring(dn) end
		local btn = entry:FindFirstChild('Button')
		local nm = btn and btn:FindFirstChild('NAME')
		if nm and nm:IsA('TextLabel') then return nm.Text end
		return nil
	end

	local function container()
		local pg = lplr:FindFirstChild('PlayerGui')
		local mainui = pg and pg:FindFirstChild('MainUI')
		if not mainui then return nil end
		local formables = mainui:FindFirstChild('Formables', true)
		return formables and (formables:FindFirstChild('Container') or formables) or nil
	end

	local function clearMark(target)
		local m = target:FindFirstChild('VainFormMark')
		if m then m:Destroy() end
		local s = target:FindFirstChild('VainFormStroke')
		if s then s:Destroy() end
		local btn = target:FindFirstChild('Button')
		if btn and btn:FindFirstChild('VainDim') then btn.VainDim:Destroy() end
	end
	local function stamp(target, icon, col)
		if target:FindFirstChild('VainFormMark') then target.VainFormMark:Destroy() end
		if target:FindFirstChild('VainFormStroke') then target.VainFormStroke:Destroy() end
		local badge = Instance.new('ImageLabel')
		badge.Name = 'VainFormMark'
		badge.AnchorPoint = Vector2.new(1, 0)
		badge.Position = UDim2.new(1, -4, 0, 4)
		badge.Size = UDim2.fromOffset(24, 24)
		badge.BackgroundTransparency = 1
		badge.Image = icon
		badge.ImageColor3 = col
		badge.ZIndex = 60
		badge.Parent = target
		local stroke = Instance.new('UIStroke')
		stroke.Name = 'VainFormStroke'
		stroke.Color = col
		stroke.Thickness = 2
		stroke.Transparency = 0.15
		stroke.Parent = target
	end

	local function refresh()
		if not (HighlightFormables and HighlightFormables.Enabled) then return end
		local myCountry = lplr:GetAttribute('MyCountry')
		local cont = container()
		if not (myCountry and cont) then return end
		local ready, curName = computeReady(myCountry)
		for _, entry in cont:GetChildren() do
			if entry:IsA('GuiObject') and entry:FindFirstChild('Button') then
				marked[entry] = true
				local name = entryName(entry)
				local isCurrent = entry.Name == '1RESET' or (curName and name == curName)
				local isReady = name ~= nil and ready[name] == true
				if isCurrent and MarkCurrent.Enabled then
					stamp(entry, STAR_ICON, BLUE)
				elseif isReady and MarkReady.Enabled then
					stamp(entry, CHECK_ICON, GREEN)
				else
					clearMark(entry)
				end
				-- optional dim of not-ready, not-current entries
				local btn = entry:FindFirstChild('Button')
				if DimLocked.Enabled and not isReady and not isCurrent then
					if btn and not btn:FindFirstChild('VainDim') then
						local dim = Instance.new('Frame')
						dim.Name = 'VainDim'
						dim.Size = UDim2.fromScale(1, 1)
						dim.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
						dim.BackgroundTransparency = 0.55
						dim.BorderSizePixel = 0
						dim.ZIndex = 55
						dim.Parent = btn
					end
				elseif btn and btn:FindFirstChild('VainDim') then
					btn.VainDim:Destroy()
				end
			end
		end
	end

	HighlightFormables = vain.Categories.Utility:CreateModule({
		Name = 'Highlight Formables',
		Tooltip = "In the transformation menu: a green check on every formable you can transform into RIGHT NOW (computed from the game's Formables data + your regions) and a blue star on your current transform. The game keeps no 'formed in the past' flag, so past transforms can't be marked. Open the menu so the entries exist.",
		Function = function(callback)
			if callback then
				HighlightFormables:Clean(task.spawn(function()
					while HighlightFormables.Enabled do
						refresh()
						task.wait(0.5)
					end
				end))
			else
				for entry in marked do
					if entry and entry.Parent then clearMark(entry) end
				end
				table.clear(marked)
			end
		end
	})

	MarkReady = HighlightFormables:CreateToggle({ Name = 'Mark Ready', Default = true,
		Tooltip = 'Green check + outline on every formable you can transform into right now.' })
	MarkCurrent = HighlightFormables:CreateToggle({ Name = 'Mark Current', Default = true,
		Tooltip = 'Blue star on the formable your country is currently transformed into.' })
	DimLocked = HighlightFormables:CreateToggle({ Name = 'Dim Locked', Default = false,
		Tooltip = 'Darken formables you cannot form yet, so the ready ones stand out.' })
end)

-- ══════════════════════════════════════════════════════════════════════════════
--  AUTO TRANSFORM  (transform into any formable the moment it becomes available)
-- ══════════════════════════════════════════════════════════════════════════════
-- CONFIRMED from the decompiled place file (BuildFormables, Lines 4032-4075).
-- We DON'T scrape the UI (it only exists once the menu is opened and its element
-- names are unreliable). Instead we replicate the game's OWN availability rule from
-- the two data ModuleScripts it uses, both in ReplicatedStorage:
--     Formables[i]  = { WhoCanForm, CountriesREQ, CitiesREQ, SPECIAL, DN, ... }
--     CountryData[c] = country info (DN, ...)
-- A formable `i` is transformable RIGHT NOW when ALL of:
--   * you are allowed: not v.WhoCanForm, or table.find(v.WhoCanForm, MyCountry)
--   * it is not your CURRENT transform: CountryRegistry[MyCountry].TRANSFORMEDINTO ~= i
--   * it is not SPECIAL-locked (v.SPECIAL) unless you own the "<i>_FORMABLE" item
--   * you own EVERY required region: no region whose Core is in v.CountriesREQ (or
--     whose Name is in v.CitiesREQ) is owned by someone else.
-- Then transform with the game's real call:  FireServer("TransformInto", i)
run(function()
	local AutoTransform
	local Interval, Notify

	-- locate the two data modules in ReplicatedStorage (by name, version-proof)
	local formablesMod, countryMod
	local function findModule(name)
		local direct = replicatedStorage:FindFirstChild(name, true)
		if direct and direct:IsA('ModuleScript') then return direct end
		return nil
	end
	local function loadData()
		if not formablesMod then formablesMod = findModule('Formables') end
		if not countryMod then countryMod = findModule('CountryData') end
		local okF, formables = pcall(function() return require(formablesMod) end)
		local okC, countries = pcall(function() return require(countryMod) end)
		return okF and formables or nil, okC and countries or nil
	end

	-- your current transform (a CountryRegistry attribute on your country)
	local function currentTransform(country)
		local cf = countryFolder(country)
		return cf and cf:GetAttribute('TRANSFORMEDINTO') or nil
	end

	-- do you own every region this formable requires? Mirrors the game's v468 loop.
	local function ownsAllRegions(v, myCountry)
		local regions = workspace:FindFirstChild('Regions')
		if not regions then return false end
		local needCountries = v.CountriesREQ
		local needCities = v.CitiesREQ
		if not (needCountries or needCities) then return true end
		for _, tile in regions:GetChildren() do
			local owner = tile:GetAttribute('Country')
			if owner ~= myCountry then
				local core = tile:GetAttribute('Core')
				local reqByCore = needCountries and core ~= nil and table.find(needCountries, core)
				local reqByCity = needCities and table.find(needCities, tile.Name)
				if reqByCore or reqByCity then
					return false   -- a required region is owned by someone else
				end
			end
		end
		return true
	end

	local function ownsFormableItem(i)
		-- SPECIAL formables unlock via a "<i>_FORMABLE" BoughtItem. We can't read the
		-- client BoughtItems list, so we simply DON'T auto-fire SPECIAL ones (the
		-- server would reject them anyway). Returns false => treat SPECIAL as locked.
		return false
	end

	-- is formable `i` (definition v) transformable right now for myCountry?
	local function canForm(i, v, myCountry, cur)
		if cur == i then return false end
		if v.WhoCanForm and not table.find(v.WhoCanForm, myCountry) then return false end
		if v.SPECIAL and not ownsFormableItem(i) then return false end
		if not ownsAllRegions(v, myCountry) then return false end
		return true
	end

	-- list every formable key you can transform into right now
	local function availableFormables()
		local myCountry = lplr:GetAttribute('MyCountry')
		if not myCountry then return {}, myCountry end
		local formables = select(1, loadData())
		if not formables then return {}, myCountry end
		local cur = currentTransform(myCountry)
		local out = {}
		for i, v in formables do
			if canForm(i, v, myCountry, cur) then table.insert(out, i) end
		end
		return out, myCountry
	end

	local attempted = {}

	-- the game pops an "Are you sure?" dialog whose confirm button fires
	-- FireServer("TransformInto", i). We fire that call directly, so no dialog needed.
	local function doTransform(i)
		fireAction('TransformInto', i)
	end

	local function sweep()
		local list, myCountry = availableFormables()
		if not myCountry then return 0, 0 end
		local now = tick()
		local fired = 0
		for _, i in list do
			if not attempted[i] or (now - attempted[i]) > 10 then
				attempted[i] = now
				doTransform(i)
				fired += 1
				if Notify.Enabled then
					local formables = select(1, loadData())
					local dn = formables and formables[i] and (formables[i].DN or i) or i
					notif('Auto Transform', 'Transforming into ' .. tostring(dn), 3, 'success')
				end
				-- after a successful transform the country's TRANSFORMEDINTO changes,
				-- so re-evaluate on the next sweep; one per sweep is plenty.
				task.wait(0.5)
				break
			end
		end
		return fired, #list
	end

	AutoTransform = vain.Categories.Utility:CreateModule({
		Name = 'Auto Transform',
		Tooltip = "Automatically transforms your country into any formable the instant its requirements are met -- it reads the game's own Formables / CountryData modules and region ownership (no need to open the menu) and fires the real TransformInto call. Skips your current transform and formables locked to other countries or behind SPECIAL unlocks.",
		Function = function(callback)
			if callback then
				table.clear(attempted)
				local formables, countries = loadData()
				local list, myCountry = availableFormables()
				notif('Auto Transform', string.format(
					'%s | data %s | country %s | available now: %d',
					getActionRemote() and 'Remote OK' or 'NO REMOTE',
					(formables and countries) and 'loaded' or 'MODULES NOT FOUND',
					tostring(myCountry), #list),
					7, (getActionRemote() and formables and myCountry) and nil or 'warning')
				AutoTransform:Clean(task.spawn(function()
					while AutoTransform.Enabled do
						sweep()
						task.wait(Interval and Interval.Value or 4)
					end
				end))
			end
		end
	})

	Interval = AutoTransform:CreateSlider({ Name = 'Check Interval', Min = 1, Max = 30, Default = 4, Suffix = 'sec',
		Tooltip = 'How often to re-evaluate which formables you can transform into.' })
	Notify = AutoTransform:CreateToggle({ Name = 'Notify', Default = true,
		Tooltip = 'Notify each time it transforms your country into a formable.' })
end)
