-- Vain module set for the medieval RTS (place 13802699692).
--
-- The server VALIDATES every action (cost, unit-space, placement, ownership),
-- so none of these try to cheat the rules -- there are no free units / infinite
-- cash exploits because the server would reject them. Instead these AUTOMATE
-- legal play faster and more tirelessly than a human can: command your whole
-- army at once, keep the economy and army production running, and (Auto Play)
-- run the entire match loop for you.
--
-- Everything below talks to the game's own plain (unobfuscated) remotes in
-- ReplicatedStorage and reads the same client-readable state the game's UI uses:
--   Spawn:FireServer(unitName, position)           -- recruit a unit (cost+space checked server-side)
--   Upgrade:FireServer(buildingModel)              -- upgrade a building
--   Sell:FireServer(model)                         -- sell a unit/building
--   SendUnitGoals:InvokeServer(goals, isAttack, isMove)  -- goals = {{unitModel, Vector3}, ...}
--   GetInfoCash:Invoke()                           -- current cash (BindableFunction)
--   Workspace.Game.PlayerFolder[name].Units        -- my army
--   Workspace.Game.PlayerFolder[name].Stats.{CurrentUnits,MaxUnits,CurrentBuildings,MaxBuildings}
--   ReplicatedStorage.Units.Default[name]:GetAttribute('Space'/'Cost')

local run = function(func) func() end
local cloneref = cloneref or function(obj) return obj end

local playersService = cloneref(game:GetService('Players'))
local runService = cloneref(game:GetService('RunService'))
local replicatedStorage = cloneref(game:GetService('ReplicatedStorage'))

local lplr = playersService.LocalPlayer
local vain = shared.vain

local function notif(...)
	return vain:CreateNotification(...)
end

-- ---------------------------------------------------------------------------
-- Shared helpers: resolve the game's state defensively (anything can be nil
-- mid-match: respawn, fog, streaming) so a module never errors the whole file.
-- ---------------------------------------------------------------------------

local function gameFolder()
	local w = workspace:FindFirstChild('Game')
	return w
end

local function myFolder()
	local g = gameFolder()
	local pf = g and g:FindFirstChild('PlayerFolder')
	return pf and pf:FindFirstChild(lplr.Name) or nil
end

local function myTeam()
	local mf = myFolder()
	local tv = mf and mf:FindFirstChild('TeamValue')
	return tv and tv.Value or nil
end

-- all of my living unit models
local function myUnits()
	local out = {}
	local mf = myFolder()
	local units = mf and mf:FindFirstChild('Units')
	if units then
		for _, u in units:GetChildren() do
			if u:IsA('Model') and u.PrimaryPart and u:GetAttribute('Destroyed') ~= true then
				out[#out + 1] = u
			end
		end
	end
	return out
end

-- every enemy unit/building model on the map (different TeamValue from mine)
local function enemyObjects()
	local out = {}
	local g = gameFolder()
	local pf = g and g:FindFirstChild('PlayerFolder')
	local mine = myTeam()
	if not pf then return out end
	for _, folder in pf:GetChildren() do
		local tv = folder:FindFirstChild('TeamValue')
		if tv and tv.Value ~= mine then
			for _, sub in {'Units', 'Buildings'} do
				local cont = folder:FindFirstChild(sub)
				if cont then
					for _, o in cont:GetChildren() do
						if o:IsA('Model') and o.PrimaryPart and o:GetAttribute('Destroyed') ~= true then
							out[#out + 1] = o
						end
					end
				end
			end
		end
	end
	return out
end

local function nearestEnemyTo(pos)
	local best, bestDist
	for _, o in enemyObjects() do
		local d = (o.PrimaryPart.Position - pos).Magnitude
		if not bestDist or d < bestDist then
			best, bestDist = o, d
		end
	end
	return best, bestDist
end

-- send a goal to a set of units. units = {model,...}; target = Vector3.
-- isAttack -> attack-move, else plain move.
local function commandUnits(units, target, isAttack)
	local remote = replicatedStorage:FindFirstChild('SendUnitGoals')
	if not remote or typeof(target) ~= 'Vector3' then return false end
	local goals = {}
	for _, u in units do
		if u.PrimaryPart then
			goals[#goals + 1] = {u, target}
		end
	end
	if #goals == 0 then return false end
	local ok = pcall(function()
		remote:InvokeServer(goals, isAttack and true or false, not isAttack and true or false)
	end)
	return ok
end

local function getCash()
	local remote = replicatedStorage:FindFirstChild('GetInfoCash')
	if not remote then return 0 end
	local ok, val = pcall(function() return remote:Invoke() end)
	return ok and tonumber(val) or 0
end

-- {Cost, Space} for a unit name from ReplicatedStorage.Units.Default
local function unitStats(name)
	local units = replicatedStorage:FindFirstChild('Units')
	local def = units and units:FindFirstChild('Default')
	local u = def and def:FindFirstChild(name)
	if not u then return nil end
	return {
		Cost = u:GetAttribute('Cost') or 0,
		Space = u:GetAttribute('Space') or 1,
	}
end

local function unitSpace()
	local mf = myFolder()
	local stats = mf and mf:FindFirstChild('Stats')
	if not stats then return 0, 0 end
	local cur = stats:FindFirstChild('CurrentUnits')
	local max = stats:FindFirstChild('MaxUnits')
	return (cur and cur.Value) or 0, (max and max.Value) or 0
end

-- ObjectStats (ReplicatedStorage.Utilities.ObjectStats) is the source of truth:
-- it maps unit names -> {Cost, Space} AND building names -> {Recruits = {...}}.
local objectStats = (function()
	local util = replicatedStorage:FindFirstChild('Utilities')
	local mod = util and util:FindFirstChild('ObjectStats')
	if mod then
		local ok, t = pcall(require, mod)
		if ok and type(t) == 'table' then return t end
	end
	return {}
end)()

-- list of spawnable unit names (entries in ObjectStats that have a Cost but no
-- Recruits list -- i.e. units, not buildings). Falls back to Units.Default.
local function spawnableNames()
	local out = {}
	for name, info in pairs(objectStats) do
		if type(info) == 'table' and info.Cost ~= nil and info.Recruits == nil then
			out[#out + 1] = name
		end
	end
	if #out == 0 then
		local units = replicatedStorage:FindFirstChild('Units')
		local def = units and units:FindFirstChild('Default')
		if def then
			for _, u in def:GetChildren() do out[#out + 1] = u.Name end
		end
	end
	table.sort(out)
	return out
end

-- which of MY buildings can recruit this unit? returns the building model (so we
-- can pass its PrimaryPart). The Spawn remote's 2nd arg is the RECRUITING
-- BUILDING'S PrimaryPart, NOT a world position -- passing a Vector3 was why
-- nothing spawned.
local function recruiterFor(unitName)
	local mf = myFolder()
	local buildings = mf and mf:FindFirstChild('Buildings')
	if not buildings then return nil end
	for _, b in buildings:GetChildren() do
		if b:IsA('Model') and b.PrimaryPart and b:GetAttribute('Destroyed') ~= true then
			local info = objectStats[b.Name]
			local recruits = info and info.Recruits
			if type(recruits) == 'table' and table.find(recruits, unitName) then
				return b
			end
		end
	end
	return nil
end

-- {Cost, Space} for a unit, preferring ObjectStats (the real values the server uses)
local function statsFor(name)
	local info = objectStats[name]
	if type(info) == 'table' and info.Cost ~= nil then
		return {Cost = info.Cost or 0, Space = info.Space or 1}
	end
	return unitStats(name)
end

-- Recruit a unit from a building that can train it, ONLY if affordable + space
-- (matches the client gate so the server accepts it). Returns true on a fire.
local function trySpawn(name)
	local stats = statsFor(name)
	if not stats then return false end
	if getCash() < stats.Cost then return false end
	local cur, max = unitSpace()
	if (cur + (stats.Space or 0)) > max then return false end
	local building = recruiterFor(name)
	if not building or not building.PrimaryPart then return false end
	local remote = replicatedStorage:FindFirstChild('Spawn')
	if not remote then return false end
	return pcall(function() remote:FireServer(name, building.PrimaryPart) end)
end

-- ---------------------------------------------------------------------------
-- Tier 1: Unit God Commands
-- ---------------------------------------------------------------------------

run(function()
	-- Mass Attack: every frame (slow tick), send your whole army to attack-move
	-- onto the nearest enemy object. Re-issued so idle units keep re-engaging.
	local MassAttack
	MassAttack = vain.Categories.Blatant:CreateModule({
		Name = 'Mass Attack',
		Function = function(callback)
			if callback then
				task.spawn(function()
					repeat
						local units = myUnits()
						if #units > 0 then
							-- rally point = army centroid, find nearest enemy to it
							local sum = Vector3.zero
							for _, u in units do sum += u.PrimaryPart.Position end
							local centroid = sum / #units
							local enemy = nearestEnemyTo(centroid)
							if enemy then
								commandUnits(units, enemy.PrimaryPart.Position, true)
							end
						end
						task.wait(1)
					until not MassAttack.Enabled
				end)
			end
		end,
		Tooltip = 'Sends your entire army to attack-move onto the nearest enemy, re-issuing so idle units keep engaging. Uses the game\'s own command remote -- server-valid.'
	})
end)

run(function()
	-- Rally To Me: keep the whole army moving to your character/camera position.
	local RallyToMe
	RallyToMe = vain.Categories.Blatant:CreateModule({
		Name = 'Rally To Me',
		Function = function(callback)
			if callback then
				task.spawn(function()
					repeat
						local char = lplr.Character
						local hrp = char and char:FindFirstChild('HumanoidRootPart')
						local pos = hrp and hrp.Position
							or (workspace.CurrentCamera and workspace.CurrentCamera.CFrame.Position)
						local units = myUnits()
						if pos and #units > 0 then
							commandUnits(units, pos, false)
						end
						task.wait(1)
					until not RallyToMe.Enabled
				end)
			end
		end,
		Tooltip = 'Continuously moves your whole army to your position -- instant regroup/retreat.'
	})
end)

-- ---------------------------------------------------------------------------
-- Tier 2: Auto Economy
-- ---------------------------------------------------------------------------

run(function()
	-- Auto Spawn: continuously recruit the selected unit at your spawn whenever
	-- you can afford it and have unit-space. Honours the real cost/space the
	-- server checks, so every spawn is accepted -- it just never stops.
	local AutoSpawn
	local UnitChoice

	AutoSpawn = vain.Categories.Utility:CreateModule({
		Name = 'Auto Spawn',
		Function = function(callback)
			if callback then
				task.spawn(function()
					repeat
						local name = UnitChoice and UnitChoice.Value
						if name and name ~= '' then
							trySpawn(name)
						end
						task.wait(0.5)
					until not AutoSpawn.Enabled
				end)
			end
		end,
		Tooltip = 'Continuously recruits the chosen unit whenever you can afford it and have space. Never breaks the cost/space rules (so the server accepts it) -- it just produces non-stop.'
	})
	UnitChoice = AutoSpawn:CreateDropdown({
		Name = 'Unit',
		List = spawnableNames(),
		Tooltip = 'Which unit to mass-produce.'
	})
end)

run(function()
	-- Auto Upgrade: fire Upgrade on each of your buildings the moment cash allows.
	-- The server decides if the upgrade is valid/affordable; we just keep asking.
	local AutoUpgrade
	AutoUpgrade = vain.Categories.Utility:CreateModule({
		Name = 'Auto Upgrade',
		Function = function(callback)
			if callback then
				task.spawn(function()
					local remote = replicatedStorage:FindFirstChild('Upgrade')
					repeat
						local mf = myFolder()
						local buildings = mf and mf:FindFirstChild('Buildings')
						if remote and buildings then
							for _, b in buildings:GetChildren() do
								if not AutoUpgrade.Enabled then break end
								if b:IsA('Model') then
									pcall(function() remote:FireServer(b) end)
									task.wait(0.2)
								end
							end
						end
						task.wait(2)
					until not AutoUpgrade.Enabled
				end)
			end
		end,
		Tooltip = 'Keeps firing Upgrade on all your buildings; the server applies it whenever it is affordable/valid. Snowballs your base automatically.'
	})
end)

-- ---------------------------------------------------------------------------
-- Tier 3: Auto Play -- composes economy + production + attack into a match loop
-- ---------------------------------------------------------------------------

run(function()
	local AutoPlay
	local PrimaryUnit
	local Aggro

	-- castle position used as the army's home/rally point
	local function castlePos()
		local mf = myFolder()
		local buildings = mf and mf:FindFirstChild('Buildings')
		if buildings then
			local c = buildings:FindFirstChild('Castle') or buildings:FindFirstChildWhichIsA('Model')
			if c and c.PrimaryPart then return c.PrimaryPart.Position end
		end
		local char = lplr.Character
		local hrp = char and char:FindFirstChild('HumanoidRootPart')
		return hrp and hrp.Position or (workspace.CurrentCamera and workspace.CurrentCamera.CFrame.Position) or Vector3.zero
	end

	-- count how many of a unit I currently have, by name
	local function countUnit(name)
		local n = 0
		for _, u in myUnits() do if u.Name == name then n += 1 end end
		return n
	end

	AutoPlay = vain.Categories.Blatant:CreateModule({
		Name = 'Auto Play',
		Function = function(callback)
			if callback then
				if not (myFolder() and replicatedStorage:FindFirstChild('Spawn') and replicatedStorage:FindFirstChild('SendUnitGoals')) then
					notif('Auto Play', 'Could not find the game state/remotes (not in a match yet?). Disabling.', 6, 'alert')
					AutoPlay:Toggle()
					return
				end
				task.spawn(function()
					notif('Auto Play', 'Running: economy (builders), army production, and attacking the nearest enemy.', 5)
					repeat
						local base = castlePos()
						-- 1) ECONOMY: keep a couple of Builders alive. Builders raise your
						-- cap by constructing houses, so they are the actual economy unit
						-- (House / Builder Hut are BUILDINGS -- placed, not Spawn-recruited).
						local cur, max = unitSpace()
						if max - cur >= 1 then
							local spawned = false
							if countUnit('Builder') < 2 then
								spawned = trySpawn('Builder')
							end
							-- 2) ARMY: fill remaining space with the primary unit
							local unit = (PrimaryUnit and PrimaryUnit.Value) or 'Knight'
							if not spawned and unit ~= '' then
								trySpawn(unit)
							end
						end

						-- 3) ATTACK: send the standing army at the nearest enemy. Keep a
						-- small home guard if Aggro is off, else commit everything.
						local units = myUnits()
						if #units > 0 then
							local sum = Vector3.zero
							for _, u in units do sum += u.PrimaryPart.Position end
							local centroid = sum / #units
							local enemy = nearestEnemyTo(centroid)
							if enemy then
								local army = units
								if not (Aggro and Aggro.Enabled) and #units > 4 then
									-- leave ~25% at base to defend
									army = {}
									for i = 1, math.floor(#units * 0.75) do army[i] = units[i] end
								end
								commandUnits(army, enemy.PrimaryPart.Position, true)
							else
								-- no enemy in sight: regroup at base
								commandUnits(units, base, false)
							end
						end

						task.wait(1.5)
					until not AutoPlay.Enabled
				end)
			end
		end,
		Tooltip = 'Plays the whole match: grows your economy (builders/houses for cap), mass-produces your army, and attack-moves it onto the nearest enemy -- re-rallying idle units. All via the game\'s own remotes, so every action is server-valid.'
	})
	PrimaryUnit = AutoPlay:CreateDropdown({
		Name = 'Army Unit',
		List = spawnableNames(),
		Tooltip = 'The main unit Auto Play mass-produces for its army.'
	})
	Aggro = AutoPlay:CreateToggle({
		Name = 'All-In',
		Tooltip = 'Commit your ENTIRE army to the attack (no home guard). Faster rush, weaker defence.'
	})
end)
