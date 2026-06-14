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

	-- KEEP Targetable LIVE. entitylib computes ent.Targetable ONCE when the entity
	-- is added, but isEnemy depends on in_combat/status which change mid-game (a
	-- player enters/leaves combat). Without this, ESP/Chams (which gate on
	-- ent.Targetable) would freeze an enemy as a "teammate" or vice-versa. Each
	-- frame we recompute Targetable for every entity and fire EntityUpdated when it
	-- flips, so all visual + combat modules immediately follow the in_combat state.
	task.spawn(function()
		while true do
			for _, ent in entitylib.List do
				if ent and ent.Player then
					local now = isEnemy(ent)
					if ent.Targetable ~= now then
						ent.Targetable = now
						pcall(function() entitylib.Events.EntityUpdated:Fire(ent) end)
					end
				end
			end
			task.wait(0.2)
		end
	end)

	-- Make sure entitylib is running/populated. universal.lua also calls start()
	-- but call it here too (idempotent, guarded by .Running) so we don't depend on
	-- load order.
	pcall(function() entitylib.start() end)
end)

-- DIAGNOSTIC 2: entitylib populates from Workspace.Entities (List=3, localAlive=
-- true confirmed). Now probe WHY modules reject targets -- per entity report
-- whether it has a Player, is flagged NPC, its in_combat/status, and isEnemy.
run(function()
	task.delay(7, function()
		local lines = {}
		for _, ent in entitylib.List do
			local plr = ent.Player
			local nm = plr and plr.Name or (ent.NPC and 'NPC' or '?')
			local combat = plr and tostring(inCombat(plr)) or '-'
			local status = plr and tostring(stateValue(plr, 'status')) or '-'
			lines[#lines + 1] = string.format('%s plr=%s npc=%s combat=%s status=%s enemy=%s',
				nm, tostring(plr ~= nil), tostring(ent.NPC == true), combat, status, tostring(isEnemy(ent)))
		end
		local msg = (#lines > 0) and table.concat(lines, ' || ') or 'entitylib.List EMPTY'
		if vain.CreateNotification then
			vain:CreateNotification('Redliner Diag2', msg, 30, 'alert')
		end
		warn('[Redliner Diag2] ' .. msg)
		-- also probe input: does VirtualInputManager exist & SendKeyEvent work?
		local vimOk = pcall(function()
			local v = cloneref(game:GetService('VirtualInputManager'))
			return v.SendKeyEvent ~= nil
		end)
		warn('[Redliner Diag2] VirtualInputManager usable: ' .. tostring(vimOk))
	end)
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

-- ============================================================================
-- Shared input helpers (VirtualInputManager). The game action controller is
-- hidden, so we trigger its OWN keybinds (LMB melee / Q gun / F parry / RMB
-- grapple / SHIFT dash / CTRL slide / SPACE wallrun) instead of reconstructing
-- packets -- build-proof. Keybinds are changeable in-game; these assume defaults.
-- ============================================================================
local vim = cloneref(game:GetService('VirtualInputManager'))
local function tapKey(key)
	pcall(function()
		vim:SendKeyEvent(true, key, false, game)
		task.wait()
		vim:SendKeyEvent(false, key, false, game)
	end)
end
local function holdKey(key, down)
	pcall(function() vim:SendKeyEvent(down and true or false, key, false, game) end)
end
local function clickMouse(right)
	pcall(function()
		local btn = right and 1 or 0
		vim:SendMouseButtonEvent(0, 0, btn, true, game, 0)
		task.wait()
		vim:SendMouseButtonEvent(0, 0, btn, false, game, 0)
	end)
end

-- ============================================================================
-- Auto Parry -- the strong version of bullet defence. [F] parries bullets in
-- Redliner; this watches for ANY incoming threat (projectile OR enemy melee
-- lunge) and taps F on the tightest timing so the parry/deflect lands.
-- ============================================================================
run(function()
	local AutoParry, ParryRange, MeleeParry

	local function incomingWithin(range)
		if not entitylib.isAlive then return false end
		local myPos = entitylib.character.RootPart.Position
		local function fast(o)
			if not o:IsA('BasePart') then return false end
			local vel = o.AssemblyLinearVelocity
			local sp = vel.Magnitude
			if sp < 40 then return false end
			local rel = myPos - o.Position
			return vel:Dot(rel) > 0 and (rel.Magnitude / sp) <= (range / 1000)
		end
		local tagged = collectionService:GetTagged('Projectile')
		if #tagged > 0 then
			for _, o in tagged do if fast(o) then return true end end
		else
			for _, o in workspace:GetDescendants() do
				if o:IsA('BasePart') and not o.Anchored and o.CanQuery == false and fast(o) then
					return true
				end
			end
		end
		if MeleeParry and MeleeParry.Enabled then
			for _, ent in entitylib.List do
				if ent.Player and isEnemy(ent) and ent.RootPart then
					local rel = myPos - ent.RootPart.Position
					if rel.Magnitude < 9 then
						local ev = ent.RootPart.AssemblyLinearVelocity
						if ev.Magnitude > 8 and ev:Dot(rel) > 0 then return true end
					end
				end
			end
		end
		return false
	end

	AutoParry = vain.Categories.Combat:CreateModule({
		Name = 'Auto Parry',
		Function = function(callback)
			if callback then
				local last = 0
				AutoParry:Clean(runService.Heartbeat:Connect(function()
					if tick() - last < 0.16 then return end
					if incomingWithin(ParryRange and ParryRange.Value or 220) then
						last = tick()
						tapKey(Enum.KeyCode.F)
					end
				end))
			end
		end,
		Tooltip = 'Taps F on the tightest timing to parry incoming bullets -- and optionally enemy melee lunges. The precise version of Auto Block. (Assumes Parry is bound to F.)'
	})
	ParryRange = AutoParry:CreateSlider({
		Name = 'Timing Window',
		Min = 60, Max = 400, Default = 220,
		Suffix = function() return 'ms' end,
		Tooltip = 'How early before impact to parry. Lower = riskier last-frame parry; higher = safer.'
	})
	MeleeParry = AutoParry:CreateToggle({
		Name = 'Parry Melee',
		Default = true,
		Tooltip = 'Also parry enemy melee lunges, not just bullets.'
	})
end)

-- ============================================================================
-- Melee Aimbot -- when an enemy is in melee range, snap your facing to them so
-- the swing connects; optionally auto-swing (LMB).
-- ============================================================================
run(function()
	local MeleeAimbot, MeleeRange, AutoSwing

	MeleeAimbot = vain.Categories.Combat:CreateModule({
		Name = 'Melee Aimbot',
		Function = function(callback)
			if callback then
				local lastSwing = 0
				MeleeAimbot:Clean(runService.RenderStepped:Connect(function()
					if not entitylib.isAlive then return end
					local range = MeleeRange and MeleeRange.Value or 14
					local ent = entitylib.EntityPosition({
						Range = range, Part = 'RootPart', Players = true,
						Origin = entitylib.character.RootPart.Position,
						Sort = function(a, b) return a.Magnitude < b.Magnitude end,
					})
					if not ent or not isEnemy(ent) then return end
					local root = entitylib.character.RootPart
					local target = (ent.RootPart or ent.Head).Position
					root.CFrame = CFrame.lookAt(root.Position, Vector3.new(target.X, root.Position.Y, target.Z))
					if AutoSwing and AutoSwing.Enabled and tick() - lastSwing > 0.35 then
						lastSwing = tick()
						clickMouse(false)
					end
				end))
			end
		end,
		Tooltip = 'Snaps your facing onto the nearest enemy in melee range so swings land. Optionally auto-swings (LMB) when an enemy is close.'
	})
	MeleeRange = MeleeAimbot:CreateSlider({
		Name = 'Melee Range',
		Min = 5, Max = 30, Default = 14,
		Suffix = function(val) return val == 1 and 'stud' or 'studs' end,
		Tooltip = 'How close an enemy must be to trigger the facing-snap / auto-swing.'
	})
	AutoSwing = MeleeAimbot:CreateToggle({
		Name = 'Auto Swing',
		Default = false,
		Tooltip = 'Automatically melee (LMB) when an enemy is within range.'
	})
end)

-- ============================================================================
-- Auto Grapple -- [RMB] grapple yanks you toward your aim. Auto-aims at the
-- nearest enemy and fires to close distance for a melee.
-- ============================================================================
run(function()
	local AutoGrapple, GrappleRange, GrappleDelay

	AutoGrapple = vain.Categories.Combat:CreateModule({
		Name = 'Auto Grapple',
		Function = function(callback)
			if callback then
				local last = 0
				AutoGrapple:Clean(runService.RenderStepped:Connect(function()
					if not entitylib.isAlive then return end
					local cd = GrappleDelay and GrappleDelay.Value or 1.5
					if tick() - last < cd then return end
					local range = GrappleRange and GrappleRange.Value or 120
					local ent = entitylib.EntityPosition({
						Range = range, Part = 'RootPart', Players = true,
						Origin = entitylib.character.RootPart.Position,
						Sort = function(a, b) return a.Magnitude < b.Magnitude end,
					})
					if not ent or not isEnemy(ent) then return end
					local root = entitylib.character.RootPart
					local d = (ent.RootPart.Position - root.Position).Magnitude
					if d < 18 then return end
					gameCamera.CFrame = CFrame.lookAt(gameCamera.CFrame.Position, ent.RootPart.Position)
					last = tick()
					clickMouse(true)
				end))
			end
		end,
		Tooltip = 'Auto-aims your grapple (RMB) at the nearest enemy and fires it to yank you into melee range. Only fires when there is distance to close.'
	})
	GrappleRange = AutoGrapple:CreateSlider({
		Name = 'Grapple Range',
		Min = 20, Max = 400, Default = 120,
		Suffix = function(val) return 'studs' end,
		Tooltip = 'Max distance to grapple an enemy from.'
	})
	GrappleDelay = AutoGrapple:CreateSlider({
		Name = 'Re-grapple Delay',
		Min = 0, Max = 5, Default = 1.5, Decimal = 10,
		Suffix = function(val) return 's' end,
		Tooltip = 'Cooldown between auto-grapples so it does not spam RMB.'
	})
end)

-- ============================================================================
-- Triggerbot -- auto-fire your gun ([Q]) when an enemy is under your crosshair.
-- ============================================================================
run(function()
	local Triggerbot, TrigDelay
	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude

	Triggerbot = vain.Categories.Combat:CreateModule({
		Name = 'Triggerbot',
		Function = function(callback)
			if callback then
				local last = 0
				Triggerbot:Clean(runService.RenderStepped:Connect(function()
					if not entitylib.isAlive then return end
					local delay = (TrigDelay and TrigDelay.Value or 60) / 1000
					if tick() - last < delay then return end
					local origin = gameCamera.CFrame.Position
					local dir = gameCamera.CFrame.LookVector * 1000
					rayParams.FilterDescendantsInstances = {entitylib.character.Character, gameCamera}
					local hit = workspace:Raycast(origin, dir, rayParams)
					if not hit then return end
					local model = hit.Instance:FindFirstAncestorWhichIsA('Model')
					local plr = model and playersService:GetPlayerFromCharacter(model)
					if not plr then return end
					for _, ent in entitylib.List do
						if ent.Player == plr then
							if isEnemy(ent) then
								last = tick()
								tapKey(Enum.KeyCode.Q)
							end
							break
						end
					end
				end))
			end
		end,
		Tooltip = 'Auto-fires your gun (Q) the moment an ENEMY is under your crosshair. Skips teammates/friends via the same enemy filter as the aimbot.'
	})
	TrigDelay = Triggerbot:CreateSlider({
		Name = 'Fire Delay',
		Min = 0, Max = 500, Default = 60,
		Suffix = function(val) return 'ms' end,
		Tooltip = 'Delay between auto-fires (reaction-time look + avoids spam).'
	})
end)

-- ============================================================================
-- Movement -- exploit the "no speed limit" + binds. Infinite wallrun, dash spam,
-- camera-relative speed boost. Pure client velocity/input, no remote.
-- ============================================================================
run(function()
	local Movement, WallrunHold, DashSpam, DashInterval, SpeedBoost, SpeedValue

	Movement = vain.Categories.Blatant:CreateModule({
		Name = 'Movement',
		Function = function(callback)
			if callback then
				local lastDash = 0
				Movement:Clean(runService.Heartbeat:Connect(function()
					if not entitylib.isAlive then return end
					local root = entitylib.character.RootPart
					local hum = entitylib.character.Humanoid
					if WallrunHold and WallrunHold.Enabled then
						if inputService:IsKeyDown(Enum.KeyCode.W)
							or inputService:IsKeyDown(Enum.KeyCode.A)
							or inputService:IsKeyDown(Enum.KeyCode.D) then
							holdKey(Enum.KeyCode.Space, true)
						end
					end
					if DashSpam and DashSpam.Enabled then
						local iv = (DashInterval and DashInterval.Value or 600) / 1000
						if tick() - lastDash > iv then
							lastDash = tick()
							tapKey(Enum.KeyCode.LeftShift)
						end
					end
					if SpeedBoost and SpeedBoost.Enabled and hum then
						local move = hum.MoveDirection
						if move.Magnitude > 0.1 then
							local spd = SpeedValue and SpeedValue.Value or 60
							local v = root.AssemblyLinearVelocity
							root.AssemblyLinearVelocity = move * spd + Vector3.new(0, v.Y, 0)
						end
					end
				end))
			else
				holdKey(Enum.KeyCode.Space, false)
			end
		end,
		Tooltip = 'Movement exploits (this game has NO speed limit): infinite wallrun, dash spam, and a camera-relative speed boost. Pure client velocity/input.'
	})
	WallrunHold = Movement:CreateToggle({
		Name = 'Infinite Wallrun',
		Default = false,
		Tooltip = 'Keeps wallrun (SPACE) alive while you hold a movement key against a wall.'
	})
	DashSpam = Movement:CreateToggle({
		Name = 'Dash Spam',
		Default = false,
		Tooltip = 'Auto-presses dash (SHIFT) on an interval for constant dashing.'
	})
	DashInterval = Movement:CreateSlider({
		Name = 'Dash Interval',
		Min = 100, Max = 2000, Default = 600,
		Suffix = function(val) return 'ms' end,
		Tooltip = 'Time between auto-dashes.'
	})
	SpeedBoost = Movement:CreateToggle({
		Name = 'Speed Boost',
		Default = false,
		Tooltip = 'Adds velocity in your movement direction. No speed limit in this game, but big values may still desync -- keep it sane.'
	})
	SpeedValue = Movement:CreateSlider({
		Name = 'Speed',
		Min = 20, Max = 300, Default = 60,
		Suffix = function(val) return 'st/s' end,
		Tooltip = 'How fast Speed Boost pushes you.'
	})
end)

-- ============================================================================
-- Enemy Chams -- highlight ONLY your enemies (alive + in_combat + not friend).
-- The universal Chams can also do this (enable its hide-teammates toggle, since
-- our targetCheck makes Targetable == enemy), but this is a dedicated enemy-only
-- version that works with no extra toggles and follows the live in_combat state.
-- ============================================================================
run(function()
	local EnemyChams, FillColor, OutlineColor, FillTransparency, OutlineTransparency, Walls
	local highlights = {} -- [ent] = Highlight
	local folder = Instance.new('Folder')
	folder.Name = 'RedlinerEnemyChams'
	folder.Parent = vain.gui or game:GetService('CoreGui')

	local function clearAll()
		for _, h in highlights do
			pcall(function() h:Destroy() end)
		end
		table.clear(highlights)
	end

	EnemyChams = vain.Categories.Render:CreateModule({
		Name = 'Enemy Chams',
		Function = function(callback)
			if callback then
				EnemyChams:Clean(runService.RenderStepped:Connect(function()
					for _, ent in entitylib.List do
						local on = ent.Player and ent.Character and isEnemy(ent)
						if on then
							local h = highlights[ent]
							if not h or not h.Parent then
								h = Instance.new('Highlight')
								h.Parent = folder
								highlights[ent] = h
							end
							h.Adornee = ent.Character
							h.DepthMode = Enum.HighlightDepthMode[(Walls and Walls.Enabled) and 'AlwaysOnTop' or 'Occluded']
							h.FillColor = Color3.fromHSV(FillColor.Hue, FillColor.Sat, FillColor.Value)
							h.OutlineColor = Color3.fromHSV(OutlineColor.Hue, OutlineColor.Sat, OutlineColor.Value)
							h.FillTransparency = FillTransparency.Value
							h.OutlineTransparency = OutlineTransparency.Value
						elseif highlights[ent] then
							pcall(function() highlights[ent]:Destroy() end)
							highlights[ent] = nil
						end
					end
					for ent, h in highlights do
						if not ent.Character or not ent.Character.Parent then
							pcall(function() h:Destroy() end)
							highlights[ent] = nil
						end
					end
				end))
			else
				clearAll()
			end
		end,
		Tooltip = 'Chams (highlight) on ENEMIES only -- alive players in combat with you. Teammates, friends and bystanders are never shown. Follows the live in-combat state.'
	})
	FillColor = EnemyChams:CreateColorSlider({
		Name = 'Fill Color',
	})
	OutlineColor = EnemyChams:CreateColorSlider({
		Name = 'Outline Color',
		DefaultSat = 0,
	})
	FillTransparency = EnemyChams:CreateSlider({
		Name = 'Fill Transparency',
		Min = 0, Max = 1, Default = 0.5, Decimal = 100
	})
	OutlineTransparency = EnemyChams:CreateSlider({
		Name = 'Outline Transparency',
		Min = 0, Max = 1, Default = 0, Decimal = 100
	})
	Walls = EnemyChams:CreateToggle({
		Name = 'Through Walls',
		Default = true,
		Tooltip = 'Show the chams through walls (AlwaysOnTop).'
	})
end)
