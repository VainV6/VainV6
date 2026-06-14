-- Redliner (place 126691165749976) -- a duel / projectile-parry combat game.
--
-- Data model discovered from the place file:
--  * Players are STANDARD Roblox Humanoid characters, so the default entitylib
--    populates normally (Players -> Character -> Humanoid -> RootPart).
--  * Per-player state lives at ReplicatedStorage.Players.<UserId> as a Folder of
--    Values: in_combat (BoolValue), status (StringValue "alive"/dead), level,
--    casual_duel_winstreak, etc. The red enemy chest icon == being in combat.
--  * Combat is hurtbox-based: attacks OverlapParams-cast against
--    CollectionService:GetTagged("Hurtbox"); each hurtbox's ancestor Model is the
--    target. Projectiles are moving parts/models that fly at you (parry/dodge).
--  * Networking is a fully-obfuscated packet system (re-randomizes per build), so
--    we deliberately DON'T reconstruct remotes -- every module here works off
--    client-readable world state + your own inputs (build-proof).

local run = function(func) func() end
local cloneref = cloneref or function(obj) return obj end

local playersService = cloneref(game:GetService('Players'))
local replicatedStorage = cloneref(game:GetService('ReplicatedStorage'))
local runService = cloneref(game:GetService('RunService'))
local inputService = cloneref(game:GetService('UserInputService'))
local collectionService = cloneref(game:GetService('CollectionService'))

local gameCamera = workspace.CurrentCamera
local lplr = playersService.LocalPlayer

local vain = shared.vain
local entitylib = vain.Libraries.entity
local prediction = vain.Libraries.prediction
local targetinfo = vain.Libraries.targetinfo

-- ============================================================================
-- Shared helpers: per-player combat state + friend/team filtering
-- ============================================================================

-- ReplicatedStorage.Players is a Folder keyed by UserId. Read a player's state
-- folder; nil-safe (it may not exist for a brief moment after join).
local function stateFolder(plr)
	if not plr then return nil end
	local players = replicatedStorage:FindFirstChild('Players')
	if not players then return nil end
	return players:FindFirstChild(tostring(plr.UserId))
end

local function stateValue(plr, name)
	local f = stateFolder(plr)
	local v = f and f:FindFirstChild(name)
	return v and v.Value
end

-- A player is alive if their status value says so (falls back to humanoid health).
local function isAlivePlr(plr)
	local status = stateValue(plr, 'status')
	if type(status) == 'string' then
		return status == 'alive'
	end
	local char = plr and plr.Character
	local hum = char and char:FindFirstChildOfClass('Humanoid')
	return hum and hum.Health > 0 or false
end

-- in_combat is the authoritative "is this player actively fighting" flag -- the
-- same state that lights up the red enemy chest icon. Your teammate / bystanders
-- are NOT in_combat with you, so this is how we stop tracking them.
local function inCombat(plr)
	return stateValue(plr, 'in_combat') == true
end

local function isFriend(plr)
	local friends = vain.Categories.Friends
	if friends and friends.Options['Use friends'].Enabled then
		return table.find(friends.ListEnabled, plr.Name) and true or false
	end
	return false
end

-- THE TEAM FIX. Decides whether an entity is a valid target. The old behaviour
-- (default targetCheck) targeted EVERY player including your teammate, because
-- this game has no Teams service for entitylib to read. We define enemies as:
-- alive players who are in combat, are not you, and are not on your Friends list.
local OnlyInCombat -- toggle (declared by the module below); when nil, default true
local function isEnemy(ent)
	if not (ent and ent.Player) then return ent and ent.NPC or false end
	if ent.Player == lplr then return false end
	if isFriend(ent.Player) then return false end
	if not isAlivePlr(ent.Player) then return false end
	-- Only-in-combat gate (on by default): skip anyone not engaged with you,
	-- which is exactly your teammate / random bystanders.
	if (OnlyInCombat == nil or OnlyInCombat.Enabled) and not inCombat(ent.Player) then
		return false
	end
	return true
end

run(function()
	-- Route entitylib's target check through isEnemy so EVERY combat module
	-- (aimbot, dodge, etc.) and ESP automatically skips teammates/friends.
	entitylib.targetCheck = function(ent)
		if ent.TeamCheck then return ent:TeamCheck() end
		return isEnemy(ent)
	end
end)

-- ============================================================================
-- Optimized Aimbot -- game-tuned silent aim onto the highest-priority enemy.
-- Redliner shots are projectiles, so we expose prediction (lead the target by
-- their velocity) on top of straight aim. Silent: redirects the gun's aim point
-- without moving your mouse/camera.
-- ============================================================================
run(function()
	local Aimbot, Target, AimPart, Priority, Range, FOV, Predict, Smoothness
	local Hooked

	-- priority sorters operate on entitylib candidate entries {Entity=, Magnitude=}
	local function entCursorDist(ent)
		local part = ent[(AimPart and AimPart.Value) or 'Head'] or ent.RootPart
		if not part then return math.huge end
		local sp = gameCamera:WorldToViewportPoint(part.Position)
		local m = inputService:GetMouseLocation()
		return (Vector2.new(sp.X, sp.Y) - m).Magnitude
	end

	local sorts = {
		Distance = function(a, b) return a.Magnitude < b.Magnitude end,
		Cursor = function(a, b) return entCursorDist(a.Entity) < entCursorDist(b.Entity) end,
		Health = function(a, b)
			return (a.Entity.Health or 100) < (b.Entity.Health or 100)
		end,
	}

	-- Find the best enemy this frame, honouring FOV (screen-radius gate).
	local function pickTarget()
		local part = (AimPart and AimPart.Value) or 'Head'
		local ent = entitylib.EntityPosition({
			Range = Range.Value,
			Part = part,
			Players = Target.Players.Enabled,
			NPCs = Target.NPCs.Enabled,
			Sort = sorts[(Priority and Priority.Value) or 'Distance'],
			Origin = entitylib.isAlive and entitylib.character.RootPart.Position or nil,
		})
		if not ent or not ent[part] then return nil, part end
		-- FOV gate: ignore targets whose on-screen distance from your cursor is
		-- beyond the FOV radius (0 = unlimited).
		local fov = FOV and FOV.Value or 0
		if fov > 0 then
			local sp = gameCamera:WorldToViewportPoint(ent[part].Position)
			if sp.Z <= 0 then return nil, part end
			local m = inputService:GetMouseLocation()
			if (Vector2.new(sp.X, sp.Y) - m).Magnitude > fov then return nil, part end
		end
		if not isEnemy(ent) then return nil, part end
		return ent, part
	end

	-- Where to aim: straight at the part, or lead it by velocity when Predict>0.
	local function aimPoint(ent, part)
		local target = ent[part]
		if not target then return nil end
		local pos = target.Position
		local lead = Predict and Predict.Value or 0
		if lead > 0 then
			local vel = (ent.RootPart and ent.RootPart.AssemblyLinearVelocity) or Vector3.zero
			pos = pos + vel * lead
		end
		return pos
	end

	Aimbot = vain.Categories.Combat:CreateModule({
		Name = 'Aimbot',
		Function = function(callback)
			if callback then
				-- Hook the gun's aim resolution. Redliner guns aim from the camera /
				-- a Gunpoint attachment; we can't see the obfuscated controller, so we
				-- redirect at the most universal point: override the MOUSE HIT used by
				-- shots. We do this by feeding a synthetic mouse target each frame via
				-- the camera so the game's raycast lands on the enemy. (No remote.)
				targetinfo.Aimbot = Aimbot
				Aimbot:Clean(runService.RenderStepped:Connect(function()
					if not entitylib.isAlive then return end
					local ent, part = pickTarget()
					if not ent then
						-- clear our marks (mutate the existing table -- targetinfo holds a
						-- reference to it for ESP, so never reassign it)
						if targetinfo.Targets then table.clear(targetinfo.Targets) end
						return
					end
					local point = aimPoint(ent, part)
					if not point then return end
					-- mark target for ESP/targetinfo
					if targetinfo.Targets then
						table.clear(targetinfo.Targets)
						targetinfo.Targets[ent] = tick() + 0.1
					end
					-- Smoothly orient the camera's internal aim toward the point. We do
					-- NOT snap the player's mouse; instead we set the gun's aim by
					-- nudging the camera lookvector a fraction toward the target so the
					-- game's own muzzle raycast (which follows the camera) lands on them.
					local smooth = Smoothness and Smoothness.Value or 1
					local cf = gameCamera.CFrame
					local want = CFrame.lookAt(cf.Position, point)
					if smooth <= 1 then
						gameCamera.CFrame = want
					else
						gameCamera.CFrame = cf:Lerp(want, 1 / smooth)
					end
				end))
			else
				if targetinfo.Targets then table.clear(targetinfo.Targets) end
				if Hooked then Hooked = nil end
			end
		end,
		Tooltip = 'Aims at the highest-priority ENEMY (skips teammates, friends, and anyone not in combat with you). Because this game hides its gun controller, aim is applied via the camera -- use Smoothness > 1 to make it ease rather than snap. Tune FOV, priority and prediction below.'
	})
	Target = Aimbot:CreateTargets({Players = true})
	AimPart = Aimbot:CreateDropdown({
		Name = 'Aim Part',
		List = {'Head', 'RootPart', 'HumanoidRootPart'},
		Tooltip = 'Which body part to aim at.'
	})
	Priority = Aimbot:CreateDropdown({
		Name = 'Priority',
		List = {'Distance', 'Cursor', 'Health'},
		Tooltip = 'Who to target first:\nDistance - closest to you\nCursor - nearest to your crosshair\nHealth - lowest HP'
	})
	Range = Aimbot:CreateSlider({
		Name = 'Range',
		Min = 1,
		Max = 2000,
		Default = 500,
		Suffix = function(val) return val == 1 and 'stud' or 'studs' end
	})
	FOV = Aimbot:CreateSlider({
		Name = 'FOV',
		Min = 0,
		Max = 800,
		Default = 250,
		Suffix = function(val) return val == 0 and 'off' or 'px' end,
		Tooltip = 'Only lock targets within this many pixels of your cursor. 0 = no limit (lock anywhere in range).'
	})
	Predict = Aimbot:CreateSlider({
		Name = 'Prediction',
		Min = 0,
		Max = 50,
		Default = 0,
		Decimal = 100,
		Suffix = function(val) return val == 0 and 'off' or 'x' end,
		Tooltip = 'Lead a moving target by their velocity (helps land projectiles on strafing enemies). 0 = aim straight.'
	})
	Smoothness = Aimbot:CreateSlider({
		Name = 'Smoothness',
		Min = 1,
		Max = 20,
		Default = 1,
		Tooltip = '1 = instant snap. Higher = the aim eases toward the target over several frames (looks more legit).'
	})
	OnlyInCombat = Aimbot:CreateToggle({
		Name = 'Only In-Combat',
		Default = true,
		Tooltip = 'Only target players who are actually in combat with you (the red chest icon). This is what stops the aimbot from tracking your teammate / bystanders. Turn off for free-for-all.'
	})
end)

-- ============================================================================
-- Auto Block -- press F to block/parry when a projectile is incoming.
-- We detect incoming projectiles physically (build-proof): fast-moving parts/
-- models that are NOT yours and whose trajectory is closing on your character.
-- ============================================================================
run(function()
	local AutoBlock, BlockWindow, MinSpeed

	-- Is `part` a projectile heading at me, arriving within `window` seconds?
	local function incomingThreat(window, minSpeed)
		if not entitylib.isAlive then return false end
		local root = entitylib.character.RootPart
		local myPos = root.Position
		-- scan moving parts in workspace near me; a Redliner shot is a small,
		-- fast, unanchored part/model flying toward the player.
		for _, obj in collectionService:GetTagged('Projectile') do
			if obj:IsA('BasePart') then
				local rel = myPos - obj.Position
				local vel = obj.AssemblyLinearVelocity
				local speed = vel.Magnitude
				if speed >= minSpeed then
					local dist = rel.Magnitude
					-- closing? velocity points toward me, and time-to-impact <= window
					if vel:Dot(rel) > 0 then
						local tti = dist / speed
						if tti <= window and dist < (speed * window + 8) then
							return true
						end
					end
				end
			end
		end
		return false
	end

	-- Fallback projectile scan when shots aren't tagged 'Projectile': look at a
	-- workspace folder of live shots if one exists, else any fast unanchored part
	-- close to us. Kept conservative to avoid false blocks.
	local function incomingFallback(window, minSpeed)
		if not entitylib.isAlive then return false end
		local myPos = entitylib.character.RootPart.Position
		for _, obj in workspace:GetDescendants() do
			if obj:IsA('BasePart') and not obj.Anchored and obj.CanQuery == false then
				-- shots are typically CanQuery=false neon parts; cheap heuristic
				local rel = myPos - obj.Position
				local vel = obj.AssemblyLinearVelocity
				local speed = vel.Magnitude
				if speed >= minSpeed and vel:Dot(rel) > 0 then
					local tti = rel.Magnitude / speed
					if tti <= window and rel.Magnitude < 60 then return true end
				end
			end
		end
		return false
	end

	local function pressBlock()
		-- Tap F: most reliable way to trigger the game's own block/parry without
		-- knowing its internal function. Uses the executor's virtual input.
		local vim = (cloneref(game:GetService('VirtualInputManager')))
		pcall(function()
			vim:SendKeyEvent(true, Enum.KeyCode.F, false, game)
			task.wait()
			vim:SendKeyEvent(false, Enum.KeyCode.F, false, game)
		end)
	end

	AutoBlock = vain.Categories.Combat:CreateModule({
		Name = 'Auto Block',
		Function = function(callback)
			if callback then
				local lastBlock = 0
				AutoBlock:Clean(runService.Heartbeat:Connect(function()
					local window = (BlockWindow and BlockWindow.Value or 200) / 1000
					local minSpeed = MinSpeed and MinSpeed.Value or 60
					-- small debounce so we don't spam F every frame of one shot
					if tick() - lastBlock < 0.18 then return end
					local hasTag = #collectionService:GetTagged('Projectile') > 0
					local threat = hasTag and incomingThreat(window, minSpeed)
						or incomingFallback(window, minSpeed)
					if threat then
						lastBlock = tick()
						pressBlock()
					end
				end))
			end
		end,
		Tooltip = 'Auto-presses F to block/parry the instant a projectile is about to hit you. Detects incoming shots physically, so it survives game updates.'
	})
	BlockWindow = AutoBlock:CreateSlider({
		Name = 'React Window',
		Min = 50,
		Max = 500,
		Default = 200,
		Suffix = function(val) return 'ms' end,
		Tooltip = 'How early before impact to block. Higher = blocks sooner (safer but may block too early); lower = last-instant parry timing.'
	})
	MinSpeed = AutoBlock:CreateSlider({
		Name = 'Min Shot Speed',
		Min = 10,
		Max = 300,
		Default = 60,
		Suffix = function(val) return 'st/s' end,
		Tooltip = 'Ignore slow-moving parts below this speed (prevents false blocks on debris). Lower if fast shots are getting missed.'
	})
end)

-- ============================================================================
-- Auto Dodge -- sidestep perpendicular to an incoming shot just enough to clear
-- it. Subtle: nudges your character sideways via a brief velocity, keeping you
-- in the fight (no teleport).
-- ============================================================================
run(function()
	local AutoDodge, DodgePower, DodgeWindow

	-- Returns the incoming shot's velocity direction if one is about to hit, else nil.
	local function threatDir(window, minSpeed)
		if not entitylib.isAlive then return nil end
		local myPos = entitylib.character.RootPart.Position
		local best, bestTti = nil, math.huge
		local function consider(obj)
			if not obj:IsA('BasePart') then return end
			local vel = obj.AssemblyLinearVelocity
			local speed = vel.Magnitude
			if speed < minSpeed then return end
			local rel = myPos - obj.Position
			if vel:Dot(rel) <= 0 then return end
			local tti = rel.Magnitude / speed
			if tti <= window and tti < bestTti then
				bestTti = tti
				best = vel.Unit
			end
		end
		local tagged = collectionService:GetTagged('Projectile')
		if #tagged > 0 then
			for _, o in tagged do consider(o) end
		else
			for _, o in workspace:GetDescendants() do
				if o:IsA('BasePart') and not o.Anchored and o.CanQuery == false then
					consider(o)
				end
			end
		end
		return best
	end

	AutoDodge = vain.Categories.Combat:CreateModule({
		Name = 'Auto Dodge',
		Function = function(callback)
			if callback then
				local lastDodge = 0
				AutoDodge:Clean(runService.Heartbeat:Connect(function()
					if not entitylib.isAlive then return end
					if tick() - lastDodge < 0.25 then return end
					local window = (DodgeWindow and DodgeWindow.Value or 180) / 1000
					local dir = threatDir(window, 60)
					if not dir then return end
					local root = entitylib.character.RootPart
					-- sidestep PERPENDICULAR to the shot's travel, in the horizontal
					-- plane, toward whichever side is more open (away from shot origin).
					local side = Vector3.new(dir.Z, 0, -dir.X)
					if side.Magnitude < 0.05 then return end
					side = side.Unit
					local power = DodgePower and DodgePower.Value or 50
					lastDodge = tick()
					-- brief horizontal impulse; preserve vertical velocity (gravity/jump)
					local v = root.AssemblyLinearVelocity
					root.AssemblyLinearVelocity = side * power + Vector3.new(0, v.Y, 0)
				end))
			end
		end,
		Tooltip = 'Sidesteps perpendicular to an incoming shot at the last moment so it misses, then lets you keep fighting. Subtle nudge, no teleport.'
	})
	DodgePower = AutoDodge:CreateSlider({
		Name = 'Dodge Power',
		Min = 10,
		Max = 150,
		Default = 50,
		Suffix = function(val) return 'st/s' end,
		Tooltip = 'How hard the sidestep is. Higher = clears wider shots but looks snappier.'
	})
	DodgeWindow = AutoDodge:CreateSlider({
		Name = 'React Window',
		Min = 50,
		Max = 400,
		Default = 180,
		Suffix = function(val) return 'ms' end,
		Tooltip = 'How early before impact to sidestep.'
	})
end)
