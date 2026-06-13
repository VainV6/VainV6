-- Vain :: Rogue Realms (139976482392419)
-- Wave-based RPG roguelike. Enemies are character models (Humanoid + EnemyHitBox)
-- that spawn into workspace.Enemies. Weapons are Tools, each holding its own
-- ServerControl RemoteFunction (classic linked-gear pattern). Most combat routes
-- through that per-tool ServerControl, so modules that only fire the legitimate
-- attack faster are reliable; raw value edits (health/mana) are server-checked.

local run = function(func)
	local suc, err = pcall(func)
	if not suc then
		local vain = shared.vain
		if vain and vain.CreateNotification then
			vain:CreateNotification('Vain Rogue Realms', 'Failure executing function: ' .. tostring(err), 3)
		end
	end
end
local cloneref = cloneref or function(obj)
	return obj
end
local vapeEvents = setmetatable({}, {
	__index = function(self, index)
		self[index] = Instance.new('BindableEvent')
		return self[index]
	end
})

local playersService = cloneref(game:GetService('Players'))
local runService = cloneref(game:GetService('RunService'))
local inputService = cloneref(game:GetService('UserInputService'))
local replicatedStorage = cloneref(game:GetService('ReplicatedStorage'))
local collectionService = cloneref(game:GetService('CollectionService'))
local tweenService = cloneref(game:GetService('TweenService'))

local gameCamera = workspace.CurrentCamera
local lplr = playersService.LocalPlayer
local vain = shared.vain
local entitylib = vain.Libraries.entity
local whitelist = vain.Libraries.whitelist
local prediction = vain.Libraries.prediction
local targetinfo = vain.Libraries.targetinfo
local sessioninfo = vain.Libraries.sessioninfo

local function notif(...)
	return vain:CreateNotification(...)
end

local function isFriend(plr, recolor)
	if plr and vain.Categories.Friends.Options['Use friends'].Enabled then
		local friend = table.find(vain.Categories.Friends.ListEnabled, plr.Name) and true
		if recolor then
			friend = friend and vain.Categories.Friends.Options['Recolor visuals'].Enabled
		end
		return friend
	end
	return nil
end

local function isTarget(plr)
	return plr and table.find(vain.Categories.Targets.ListEnabled, plr.Name) and true
end

-- ── Enemy helpers ─────────────────────────────────────────────────────────────
-- Live enemies are character models parented under workspace.Enemies. They carry
-- a Humanoid and an EnemyHitBox part; EnemyInfo (a BillboardGui) holds the name.
local function enemiesFolder()
	return workspace:FindFirstChild('Enemies')
end

local function isEnemyModel(model)
	if typeof(model) ~= 'Instance' or not model:IsA('Model') then return false end
	return model:FindFirstChild('EnemyHitBox') ~= nil or model:FindFirstChildOfClass('Humanoid') ~= nil
end

local function enemyName(model)
	local info = model:FindFirstChild('EnemyInfo', true)
	local nameLabel = info and info:FindFirstChild('EnemyName', true)
	if nameLabel and nameLabel:IsA('TextLabel') then
		return nameLabel.Text
	end
	return model.Name
end

-- ── entitylib setup for NPC enemies ───────────────────────────────────────────
-- entitylib.start() only tracks players, so we register each enemy model as an
-- NPC entity ourselves and keep the workspace.Enemies folder watched.
run(function()
	entitylib.targetCheck = function(ent)
		if ent.TeamCheck then return ent:TeamCheck() end
		if ent.NPC then return true end -- enemies are always valid targets
		if isFriend(ent.Player) then return false end
		return ent.Player ~= lplr
	end

	entitylib.getUpdateConnections = function(ent)
		local hum = ent.Humanoid
		return {
			hum:GetPropertyChangedSignal('Health'),
			hum:GetPropertyChangedSignal('MaxHealth'),
			{
				Connect = function()
					ent.Friend = ent.Player and isFriend(ent.Player) or nil
					ent.Target = ent.Player and isTarget(ent.Player) or nil
					return {Disconnect = function() end}
				end
			}
		}
	end
end)
entitylib.start()

run(function()
	local function tryAddEnemy(model)
		if not isEnemyModel(model) then return end
		if entitylib.getEntity(model) then return end
		entitylib.addEntity(model, nil)
	end

	local function bindFolder(folder)
		if not folder then return end
		vain:Clean(folder.ChildAdded:Connect(tryAddEnemy))
		vain:Clean(folder.ChildRemoved:Connect(function(model)
			entitylib.removeEntity(model)
		end))
		for _, model in folder:GetChildren() do
			tryAddEnemy(model)
		end
	end

	-- bind the current folder and re-bind if it's replaced (world/map swap)
	bindFolder(enemiesFolder())
	vain:Clean(workspace.ChildAdded:Connect(function(child)
		if child.Name == 'Enemies' then
			bindFolder(child)
		end
	end))
end)

-- ── Weapon helpers ────────────────────────────────────────────────────────────
-- Each weapon Tool carries its own ServerControl RemoteFunction. We don't know
-- the exact action signature without the live source, so combat modules try a
-- few classic gear conventions and otherwise fall back to firing Tool.Activated.
local function getEquippedTool()
	local char = lplr.Character
	if not char then return nil end
	return char:FindFirstChildOfClass('Tool')
end

local function getServerControl(tool)
	tool = tool or getEquippedTool()
	return tool and tool:FindFirstChild('ServerControl'), tool
end

-- Best-effort attack against an enemy entity using the equipped weapon. Returns
-- true if it managed to fire something. Pure-melee gears usually accept the
-- target's hitbox/character; we try those shapes, then fall back to Activated.
local function attackEnemy(ent)
	local hitbox = ent.Character and (ent.Character:FindFirstChild('EnemyHitBox') or ent.RootPart)
	local sc, tool = getServerControl()
	if sc then
		-- Classic linked-gear conventions, tried in order. pcall each so a wrong
		-- signature doesn't error the loop.
		local target = hitbox or ent.RootPart
		local hum = ent.Humanoid
		local tries = {
			function() return sc:InvokeServer(target) end,
			function() return sc:InvokeServer(hum, target) end,
			function() return sc:InvokeServer('Damage', target) end,
			function() return sc:InvokeServer('Hit', target) end,
		}
		for _, fn in tries do
			local ok = pcall(fn)
			if ok then return true end
		end
	end
	if tool then
		local ok = pcall(function() tool:Activate() end)
		if ok then return true end
	end
	return false
end

local function aliveLocal()
	return entitylib.isAlive and entitylib.character and entitylib.character.RootPart
end

-- ══════════════════════════════════════════════════════════════════════════════
--  ENEMY ESP
-- ══════════════════════════════════════════════════════════════════════════════
run(function()
	local EnemyESP
	local ShowHealth, ShowName, BossOnly, MaxRange
	local highlights = {} -- [ent] = {Highlight, Billboard, Label}

	local function clear(ent)
		local h = highlights[ent]
		if h then
			pcall(function() h.Highlight:Destroy() end)
			pcall(function() h.Billboard:Destroy() end)
			highlights[ent] = nil
		end
	end

	local function clearAll()
		for ent in highlights do clear(ent) end
	end

	local function isBoss(ent)
		local n = (ent.Character and ent.Character.Name or '')
		return ent.Character and (ent.Character:FindFirstChild('Boss', true) ~= nil
			or ent.Character:GetAttribute('Boss') == true)
	end

	local function update()
		local myPos = aliveLocal() and entitylib.character.RootPart.Position
		local maxR = MaxRange and MaxRange.Value or 99999
		for ent in highlights do
			if not ent.Character or not ent.Character.Parent then clear(ent) end
		end
		for _, ent in entitylib.List do
			if ent.NPC and ent.Character and ent.Character.Parent then
				local inRange = (not myPos) or (ent.RootPart.Position - myPos).Magnitude <= maxR
				local pass = inRange and (not (BossOnly and BossOnly.Enabled) or isBoss(ent))
				if pass then
					local data = highlights[ent]
					if not data then
						local hl = Instance.new('Highlight')
						hl.Name = 'VainEnemy'
						hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
						hl.FillColor = isBoss(ent) and Color3.fromRGB(255, 60, 60) or Color3.fromRGB(255, 140, 40)
						hl.OutlineColor = Color3.fromRGB(255, 220, 120)
						hl.FillTransparency = 0.55
						hl.Adornee = ent.Character
						hl.Parent = ent.Character

						local bb = Instance.new('BillboardGui')
						bb.Name = 'VainEnemyTag'
						bb.Size = UDim2.fromOffset(150, 30)
						bb.StudsOffset = Vector3.new(0, 3, 0)
						bb.AlwaysOnTop = true
						bb.Adornee = ent.Head or ent.RootPart
						bb.Parent = ent.Character
						local label = Instance.new('TextLabel')
						label.Size = UDim2.fromScale(1, 1)
						label.BackgroundTransparency = 1
						label.Font = Enum.Font.GothamBold
						label.TextSize = 13
						label.TextColor3 = Color3.fromRGB(255, 235, 200)
						label.TextStrokeTransparency = 0.4
						label.Parent = bb

						data = {Highlight = hl, Billboard = bb, Label = label}
						highlights[ent] = data
					end
					if data.Label then
						local parts = {}
						if not ShowName or ShowName.Enabled then table.insert(parts, enemyName(ent.Character)) end
						if (not ShowHealth or ShowHealth.Enabled) and ent.Humanoid then
							table.insert(parts, string.format('%d/%d', math.floor(ent.Health or ent.Humanoid.Health), math.floor(ent.MaxHealth or ent.Humanoid.MaxHealth)))
						end
						data.Label.Text = table.concat(parts, '  ')
					end
				else
					clear(ent)
				end
			end
		end
	end

	EnemyESP = vain.Categories.Render:CreateModule({
		Name = 'Enemy ESP',
		Function = function(callback)
			if callback then
				task.spawn(function()
					repeat
						update()
						task.wait(0.2)
					until not EnemyESP.Enabled
					clearAll()
				end)
			else
				clearAll()
			end
		end,
		Tooltip = 'Highlights enemies with their name and health. Client-side render only.'
	})
	ShowName = EnemyESP:CreateToggle({Name = 'Show Name', Default = true})
	ShowHealth = EnemyESP:CreateToggle({Name = 'Show Health', Default = true})
	BossOnly = EnemyESP:CreateToggle({Name = 'Bosses Only'})
	MaxRange = EnemyESP:CreateSlider({Name = 'Max Range', Min = 50, Max = 2000, Default = 2000, Suffix = 'studs'})
end)

-- ══════════════════════════════════════════════════════════════════════════════
--  KILL AURA  (auto-attack enemies in range with your equipped weapon)
-- ══════════════════════════════════════════════════════════════════════════════
run(function()
	local KillAura
	local Range, Delay, MultiTarget, BossPriority

	local function pickTargets()
		if not aliveLocal() then return {} end
		local myPos = entitylib.character.RootPart.Position
		local range = Range and Range.Value or 30
		local found = {}
		for _, ent in entitylib.List do
			if ent.NPC and ent.Character and ent.Character.Parent and ent.Humanoid and ent.Humanoid.Health > 0 then
				local dist = (ent.RootPart.Position - myPos).Magnitude
				if dist <= range then
					table.insert(found, {ent = ent, dist = dist})
				end
			end
		end
		table.sort(found, function(a, b)
			if BossPriority and BossPriority.Enabled then
				local ab = a.ent.Character:FindFirstChild('Boss', true) ~= nil
				local bb = b.ent.Character:FindFirstChild('Boss', true) ~= nil
				if ab ~= bb then return ab end
			end
			return a.dist < b.dist
		end)
		return found
	end

	KillAura = vain.Categories.Combat:CreateModule({
		Name = 'KillAura',
		Function = function(callback)
			if callback then
				task.spawn(function()
					repeat
						local targets = pickTargets()
						local count = (MultiTarget and MultiTarget.Enabled) and #targets or math.min(1, #targets)
						for i = 1, count do
							local data = targets[i]
							if data then
								attackEnemy(data.ent)
								if targetinfo and targetinfo.Targets then
									targetinfo.Targets[data.ent] = tick() + 0.5
								end
							end
						end
						task.wait(Delay and Delay.Value or 0.15)
					until not KillAura.Enabled
				end)
			end
		end,
		Tooltip = 'Automatically attacks enemies in range with your equipped weapon.'
	})
	Range = KillAura:CreateSlider({Name = 'Range', Min = 5, Max = 100, Default = 30, Suffix = 'studs'})
	Delay = KillAura:CreateSlider({Name = 'Delay', Min = 0.05, Max = 1, Default = 0.15, Decimal = 100, Suffix = 's'})
	MultiTarget = KillAura:CreateToggle({Name = 'Multi Target'})
	BossPriority = KillAura:CreateToggle({Name = 'Boss Priority', Default = true})
end)

-- ══════════════════════════════════════════════════════════════════════════════
--  AUTO FARM  (face nearest enemy, attack, and auto-collect drops)
-- ══════════════════════════════════════════════════════════════════════════════
run(function()
	local AutoFarm
	local Offset, Height, ReturnHome

	local function nearestEnemy()
		if not aliveLocal() then return nil end
		local myPos = entitylib.character.RootPart.Position
		local best, bestd = nil, math.huge
		for _, ent in entitylib.List do
			if ent.NPC and ent.Humanoid and ent.Humanoid.Health > 0 and ent.Character and ent.Character.Parent then
				local d = (ent.RootPart.Position - myPos).Magnitude
				if d < bestd then best, bestd = ent, d end
			end
		end
		return best
	end

	-- Teleport our character right next to an enemy: a few studs in front of its
	-- hitbox (so we're in melee range and facing it), lifted slightly so we don't
	-- clip into the model.
	local function teleportTo(ent)
		if not aliveLocal() then return end
		local part = ent.Character and (ent.Character:FindFirstChild('EnemyHitBox') or ent.RootPart)
		if not part then return end
		local root = entitylib.character.RootPart
		local offset = Offset and Offset.Value or 4
		local height = Height and Height.Value or 0
		-- stand `offset` studs toward the enemy from a tiny pull-back, facing it
		local goal = part.Position + Vector3.new(0, height, 0)
		local from = root.Position
		local dir = (goal - from)
		if dir.Magnitude > 0.1 then
			goal = goal - dir.Unit * offset
		end
		pcall(function()
			root.CFrame = CFrame.lookAt(goal, part.Position)
		end)
	end

	AutoFarm = vain.Categories.Combat:CreateModule({
		Name = 'AutoFarm',
		Function = function(callback)
			if callback then
				local home = aliveLocal() and entitylib.character.RootPart.CFrame or nil
				task.spawn(function()
					repeat
						local ent = nearestEnemy()
						if ent and aliveLocal() then
							-- teleport to the enemy and beat on it until it dies or
							-- despawns, then loop to the next nearest -- so we sweep
							-- through every enemy on the map.
							repeat
								teleportTo(ent)
								attackEnemy(ent)
								if targetinfo and targetinfo.Targets then
									targetinfo.Targets[ent] = tick() + 0.5
								end
								task.wait(0.12)
							until not AutoFarm.Enabled
								or not ent.Character
								or not ent.Character.Parent
								or not ent.Humanoid
								or ent.Humanoid.Health <= 0
								or not aliveLocal()
						else
							task.wait(0.2)
						end
					until not AutoFarm.Enabled
					-- optionally return to where we started once disabled
					if ReturnHome and ReturnHome.Enabled and home and aliveLocal() then
						pcall(function() entitylib.character.RootPart.CFrame = home end)
					end
				end)
			end
		end,
		Tooltip = 'Teleports from enemy to enemy, attacking each until it dies -- sweeps the whole map. WARNING: teleporting is detectable; this is for games/servers where that is acceptable.'
	})
	Offset = AutoFarm:CreateSlider({Name = 'TP Distance', Min = 0, Max = 20, Default = 4, Suffix = 'studs', Tooltip = 'How far in front of the enemy to land.'})
	Height = AutoFarm:CreateSlider({Name = 'TP Height', Min = -10, Max = 20, Default = 0, Suffix = 'studs', Tooltip = 'Vertical offset so you do not clip into the enemy.'})
	ReturnHome = AutoFarm:CreateToggle({Name = 'Return On Disable', Tooltip = 'Teleport back to your start position when AutoFarm is turned off.'})
end)

-- ══════════════════════════════════════════════════════════════════════════════
--  BOW AIMBOT  (lead the nearest enemy when firing a bow/ranged weapon)
-- ══════════════════════════════════════════════════════════════════════════════
run(function()
	local BowAimbot
	local Range, Hitbox, ProjectileSpeed

	local rayCheck = RaycastParams.new()
	rayCheck.FilterType = Enum.RaycastFilterType.Exclude

	-- Bows in this game fire toward the mouse; we hook mouse position resolution
	-- by overriding where the local mouse points while the bow is drawn. Since the
	-- exact projectile API is per-gear, we expose this as an aim-assist: it snaps
	-- the camera/aim toward the predicted enemy point so the normal shot lands.
	local function bestTarget()
		if not aliveLocal() then return nil end
		local myPos = entitylib.character.RootPart.Position
		local range = Range and Range.Value or 250
		local best, bestd = nil, math.huge
		for _, ent in entitylib.List do
			if ent.NPC and ent.Humanoid and ent.Humanoid.Health > 0 and ent.Character and ent.Character.Parent then
				local d = (ent.RootPart.Position - myPos).Magnitude
				if d <= range and d < bestd then best, bestd = ent, d end
			end
		end
		return best
	end

	BowAimbot = vain.Categories.Combat:CreateModule({
		Name = 'Bow Aimbot',
		Function = function(callback)
			if callback then
				task.spawn(function()
					repeat
						local ent = bestTarget()
						if ent and inputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1) then
							local part = ent.Character:FindFirstChild('EnemyHitBox') or ent.RootPart
							local origin = entitylib.character.RootPart.Position
							rayCheck.FilterDescendantsInstances = {lplr.Character, ent.Character, gameCamera}
							local speed = ProjectileSpeed and ProjectileSpeed.Value or 150
							local vel = part.AssemblyLinearVelocity
							if not vel or vel.Magnitude < 0.01 then vel = part.Velocity end
							local aim = part.Position
							local calc = prediction.SolveTrajectory(origin, speed, workspace.Gravity, part.Position, vel, workspace.Gravity, ent.HipHeight, nil, rayCheck)
							if calc then aim = calc end
							-- snap the camera toward the predicted point (aim assist)
							pcall(function()
								gameCamera.CFrame = CFrame.lookAt(gameCamera.CFrame.Position, aim)
							end)
							if targetinfo and targetinfo.Targets then targetinfo.Targets[ent] = tick() + 0.5 end
						end
						task.wait()
					until not BowAimbot.Enabled
				end)
			end
		end,
		Tooltip = 'Leads the nearest enemy with your projectile speed and aims your camera at the predicted point while firing. Uses the shared ballistic solver.'
	})
	Range = BowAimbot:CreateSlider({Name = 'Range', Min = 20, Max = 600, Default = 250, Suffix = 'studs'})
	ProjectileSpeed = BowAimbot:CreateSlider({Name = 'Projectile Speed', Min = 50, Max = 500, Default = 150})
end)

-- ══════════════════════════════════════════════════════════════════════════════
--  NO ATTACK COOLDOWN  (zero the local weapon's attack cooldown values)
-- ══════════════════════════════════════════════════════════════════════════════
run(function()
	local NoCooldown
	local originals = {} -- [ValueObject] = original number

	local function fields(tool)
		local out = {}
		for _, name in {'AttackCooldown', 'Cooldown', 'DamageCooldown'} do
			local v = tool:FindFirstChild(name, true)
			if v and (v:IsA('NumberValue') or v:IsA('IntValue')) then
				table.insert(out, v)
			end
		end
		return out
	end

	NoCooldown = vain.Categories.Combat:CreateModule({
		Name = 'No Attack Cooldown',
		Function = function(callback)
			if callback then
				task.spawn(function()
					repeat
						local tool = getEquippedTool()
						if tool then
							for _, v in fields(tool) do
								if originals[v] == nil then originals[v] = v.Value end
								if v.Value ~= 0 then v.Value = 0 end
							end
						end
						task.wait(0.1)
					until not NoCooldown.Enabled
				end)
			else
				for v, val in originals do
					pcall(function() v.Value = val end)
				end
				table.clear(originals)
			end
		end,
		Tooltip = 'Zeroes your equipped weapon cooldown values locally for faster attacks. Server may still rate-limit; client-side only.'
	})
end)

-- ══════════════════════════════════════════════════════════════════════════════
--  AUTO DASH  (spam dash off cooldown -- movement help for kiting)
-- ══════════════════════════════════════════════════════════════════════════════
run(function()
	local AutoDash
	-- Dash is usually a keypress (the place has a DashButton). We replay the dash
	-- input on an interval. If the game binds dash to Q by default this triggers it.
	AutoDash = vain.Categories.Blatant:CreateModule({
		Name = 'Auto Dash',
		Function = function(callback)
			if callback then
				task.spawn(function()
					repeat
						if aliveLocal() then
							pcall(function()
								-- fire the common dash keybinds via the input pipeline
								for _, key in {Enum.KeyCode.Q, Enum.KeyCode.LeftControl} do
									game:GetService('VirtualInputManager'):SendKeyEvent(true, key, false, game)
									game:GetService('VirtualInputManager'):SendKeyEvent(false, key, false, game)
								end
							end)
						end
						task.wait(0.6)
					until not AutoDash.Enabled
				end)
			end
		end,
		Tooltip = 'Repeatedly triggers your dash to kite enemies. Uses the dash keybind (Q / Ctrl).'
	})
end)

-- ══════════════════════════════════════════════════════════════════════════════
--  ANTI AFK  (stay connected during long farms)
-- ══════════════════════════════════════════════════════════════════════════════
run(function()
	local AntiAFK
	local conn
	AntiAFK = vain.Categories.Utility:CreateModule({
		Name = 'Anti AFK',
		Function = function(callback)
			if callback then
				conn = lplr.Idled:Connect(function()
					pcall(function()
						local vu = game:GetService('VirtualUser')
						vu:CaptureController()
						vu:ClickButton2(Vector2.new())
					end)
				end)
				vain:Clean(conn)
			elseif conn then
				conn:Disconnect()
				conn = nil
			end
		end,
		Tooltip = 'Prevents the 20-minute AFK kick so long auto-farms keep running.'
	})
end)

-- ══════════════════════════════════════════════════════════════════════════════
--  LOOT / SESSION TRACKER
-- ══════════════════════════════════════════════════════════════════════════════
run(function()
	local kills = sessioninfo:AddItem('Enemies Killed', 0)
	local seen = {}

	-- Count enemies that disappear after dropping to 0 health while we're nearby.
	vain:Clean(entitylib.Events.EntityRemoved:Connect(function(ent)
		if ent.NPC and ent.Humanoid and ent.Humanoid.Health <= 0 then
			if aliveLocal() then
				kills:Increment(1)
			end
		end
	end))
end)

-- ── Remove universal modules that don't apply to this RPG ──────────────────────
run(function()
	for _, name in {'Reach', 'TriggerBot', 'HitBoxes', 'Killaura', 'MurderMystery', 'AntiFall'} do
		if vain.Modules[name] then
			vain:Remove(name)
		end
	end
end)

vain:Clean(function()
	for _, v in vapeEvents do
		pcall(function() v:Destroy() end)
	end
	table.clear(vapeEvents)
end)
