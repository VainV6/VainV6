local run = function(func)
	func()
end
local cloneref = cloneref or function(obj)
	return obj
end
local vainEvents = setmetatable({}, {
	__index = function(self, index)
		self[index] = Instance.new('BindableEvent')
		return self[index]
	end
})

local playersService = cloneref(game:GetService('Players'))
local inputService = cloneref(game:GetService('UserInputService'))
local replicatedStorage = cloneref(game:GetService('ReplicatedStorage'))
local collectionService = cloneref(game:GetService('CollectionService'))
local tweenService = cloneref(game:GetService('TweenService'))
local runService = cloneref(game:GetService('RunService'))

local gameCamera = workspace.CurrentCamera
local lplr = playersService.LocalPlayer
local vain = shared.vain
local entitylib = vain.Libraries.entity
local whitelist = vain.Libraries.whitelist
local targetinfo = vain.Libraries.targetinfo
local sessioninfo = vain.Libraries.sessioninfo
local getfontsize = vain.Libraries.getfontsize

local store, md = {
    murderer = nil,
    sheriff = nil
}, nil

run(function()
    md = {}

    local function ToolAdded(player, v)
        if v:IsA('Tool') then
            local Index = v:FindFirstChild('KnifeClient') and 'murderer' or v:FindFirstChild('GunClient') and 'sheriff' or nil
            if Index then
                store[Index] = player
                vain:Clean(v.Destroying:Once(function()
                    if store[Index] == player then
                        store[Index] = nil
                    end
                end))
            end
        end
    end
    local function Added(plr): ...any
        if plr:IsA('Player') then
            vain:Clean(plr.CharacterAdded:Connect(Added))
            vain:Clean(plr:WaitForChild('Backpack', 9e9).ChildAdded:Connect(function(v)
                task.delay(0.2, ToolAdded, plr, v)
            end))
            vain:Clean(plr.ChildAdded:Connect(function(v)
                if v:IsA('Backpack') then
                    vain:Clean(v.ChildAdded:Connect(function(v)
                        task.delay(0.2, ToolAdded, plr, v)
                    end))
                end
            end))
            for _, v in plr.Backpack:GetChildren() do
                ToolAdded(plr, v)
            end
            if plr.Character then
                Added(plr.Character)
            end
        else
            local player = playersService:GetPlayerFromCharacter(plr)
            vain:Clean(plr.ChildAdded:Connect(function(v)
                task.delay(0.1, ToolAdded, player, v)
            end))
            for _, v in plr:QueryDescendants('Tool') do
                ToolAdded(player, v)
            end
        end
    end
    for _, v in playersService:GetPlayers() do
        Added(v)
    end
    playersService.PlayerAdded:Connect(Added)
end)

for _, v in {'Reach', 'Trigger Bot', 'Anti Fall', 'Anti Ragdoll', 'Disabler'} do
    vain:Remove(v)
end

--[[
    Combat
]]

run(function()
    local SilentAim
    local Targets
    local Range
    local HitChance
    local HeadChance
    
    local old
    local method = function(origin, direction, params)
        if debug.info(4, 's'):find('GunClient') then
            local ent = entitylib['Entity' .. Mode.Value]({
                Range = Range.Value,
                Wallcheck = Target.Walls.Enabled or nil,
                Part = 'Head',
                Origin = entitylib.character.RootPart.CFrame,
                Players = Target.Players.Enabled,
                NPCs = Target.NPCs.Enabled,
            })
            if ent then
                origin = ent.RootPart.Position + Vector3.new(0, 1, 0)
                direction = Vector3.new(0, -2, 0)
            end
        end
        return old(origin, direction, params)
    end
    
    SilentAim = vain.Categories.Combat:CreateModule({
        Name = 'Silent Aim',
        Function = function(callback)
            if callback then
                old = hookmetamethod(game, '__namecall', newcclosure(function(...)
                    if getnamecallmethod() ~= 'Raycast' then
                        return old(...)
                    end
                    return method(...)
                end))
            else
                hookmetamethod(game, '__namecall', old)
            end
        end
    })
    
    Targets = SilentAim:CreateTargets({Players = true})
    Range = SilentAim:CreateSlider({
    	Name = 'Range',
    	Min = 1,
    	Max = 1000,
    	Default = 150,
    	Function = function(val)
    		if CircleObject then
    			CircleObject.Radius = val
    		end
    	end,
    	Suffix = function(val)
    		return val == 1 and 'stud' or 'studs'
    	end,
    })
    HitChance = SilentAim:CreateSlider({
    	Name = 'Hit Chance',
    	Min = 0,
    	Max = 100,
    	Default = 85,
    	Suffix = '%',
    })
    HeadshotChance = SilentAim:CreateSlider({
    	Name = 'Headshot Chance',
    	Min = 0,
    	Max = 100,
    	Default = 65,
    	Suffix = '%',
    })
end)

-- ══════════════════════════════════════════════════════════════════════════════
--  Vain MM2 add-ons (Role ESP, Auto-Collect Coins, Sheriff Auto-Shoot, Murderer
--  Kill Aura). Roles come from the tool store above: a player holding the
--  KnifeClient tool is the murderer, GunClient the sheriff -- everyone else is an
--  innocent. Combat fires through the REAL input path so we never touch MM2's
--  obfuscated weapon remotes (they re-randomise every update).
-- ══════════════════════════════════════════════════════════════════════════════
local virtualInput = cloneref(game:GetService('VirtualInputManager'))

local function notif(title, text, duration, kind)
	return vain:CreateNotification(title, text, duration or 4, kind)
end

local function aliveLocal()
	return entitylib.isAlive and entitylib.character and entitylib.character.RootPart
end

-- role from the tool store: store.murderer / store.sheriff are the players holding
-- the knife / gun this round; anyone else is an innocent (nil until roles assign)
local function roleOf(plr)
	if not plr then return nil end
	if plr == store.murderer then return 'Murderer' end
	if plr == store.sheriff then return 'Sheriff' end
	return 'Innocent'
end

local function entOf(plr)
	for _, ent in entitylib.List do
		if ent.Player == plr then return ent end
	end
	return nil
end

local function rootOf(plr)
	local char = plr and plr.Character
	return char and (char:FindFirstChild('HumanoidRootPart') or char:FindFirstChildWhichIsA('BasePart'))
end

-- aim the mouse at a world point + click, through the real input path, so the
-- game fires its own (live) shoot/stab. Build-proof -- no weapon remote needed.
local function aimAt(worldPos)
	local screen, onScreen = gameCamera:WorldToViewportPoint(worldPos)
	if not onScreen or screen.Z <= 0 then return false end
	pcall(function() virtualInput:SendMouseMoveEvent(screen.X, screen.Y, game) end)
	return true
end
local function clickMouse()
	pcall(function()
		virtualInput:SendMouseButtonEvent(0, 0, 0, true, game, 0)
		virtualInput:SendMouseButtonEvent(0, 0, 0, false, game, 0)
	end)
end
local function equipSlot1()
	pcall(function()
		virtualInput:SendKeyEvent(true, Enum.KeyCode.One, false, game)
		virtualInput:SendKeyEvent(false, Enum.KeyCode.One, false, game)
	end)
end

-- ── Role ESP ──────────────────────────────────────────────────────────────────
run(function()
	local RoleESP
	local ShowInnocents, ShowName
	local COLORS = {
		Murderer = Color3.fromRGB(255, 60, 60),
		Sheriff = Color3.fromRGB(70, 140, 255),
		Innocent = Color3.fromRGB(90, 220, 120),
	}
	local huds = {} -- [player] = {Highlight, Billboard, Label}

	local function clear(plr)
		local h = huds[plr]
		if h then
			pcall(function() h.Highlight:Destroy() end)
			pcall(function() h.Billboard:Destroy() end)
			huds[plr] = nil
		end
	end
	local function clearAll() for plr in huds do clear(plr) end end

	local function update()
		for plr in huds do
			if not plr.Parent or not plr.Character then clear(plr) end
		end
		for _, plr in playersService:GetPlayers() do
			local char = plr ~= lplr and plr.Character
			local role = char and roleOf(plr)
			local show = char and role and (role ~= 'Innocent' or (ShowInnocents and ShowInnocents.Enabled))
			if show then
				local color = COLORS[role] or Color3.new(1, 1, 1)
				local head = char:FindFirstChild('Head') or char:FindFirstChildWhichIsA('BasePart')
				local data = huds[plr]
				if not data or not data.Highlight.Parent then
					if data then clear(plr) end
					local hl = Instance.new('Highlight')
					hl.Name = 'VainRole'
					hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
					hl.FillTransparency = 0.5
					hl.OutlineTransparency = 0
					hl.Parent = char
					local bb = Instance.new('BillboardGui')
					bb.Name = 'VainRoleTag'
					bb.Size = UDim2.fromOffset(180, 20)
					bb.StudsOffset = Vector3.new(0, 3.2, 0)
					bb.AlwaysOnTop = true
					bb.Parent = char
					local label = Instance.new('TextLabel')
					label.Size = UDim2.fromScale(1, 1)
					label.BackgroundTransparency = 1
					label.Font = Enum.Font.GothamBold
					label.TextSize = 14
					label.TextStrokeTransparency = 0.4
					label.Parent = bb
					data = { Highlight = hl, Billboard = bb, Label = label }
					huds[plr] = data
				end
				data.Highlight.Adornee = char
				data.Highlight.FillColor = color
				data.Highlight.OutlineColor = color
				data.Billboard.Adornee = head
				data.Label.TextColor3 = color
				data.Label.Text = (not ShowName or ShowName.Enabled) and (plr.Name .. ' [' .. role .. ']') or role
			else
				clear(plr)
			end
		end
	end

	RoleESP = vain.Categories.Render:CreateModule({
		Name = 'Role ESP',
		Function = function(callback)
			if callback then
				task.spawn(function()
					repeat update() task.wait(0.25) until not RoleESP.Enabled
					clearAll()
				end)
			else
				clearAll()
			end
		end,
		Tooltip = 'Highlights players by role -- Murderer red, Sheriff blue, Innocent green. Client-side render only.'
	})
	ShowName = RoleESP:CreateToggle({ Name = 'Show Name', Default = true })
	ShowInnocents = RoleESP:CreateToggle({ Name = 'Show Innocents', Default = false,
		Tooltip = 'Also highlight innocents (off = only Murderer + Sheriff).' })
end)

-- ── Auto-Collect Coins ──────────────────────────────────────────────────────────
run(function()
	local AutoCollect
	local Range, Fast
	local touchfn = firetouchinterest
	local collected = setmetatable({}, { __mode = 'k' })

	local coinCache, coinAt = {}, 0
	local function coins()
		if tick() - coinAt < 0.5 then return coinCache end
		coinAt = tick()
		local list = {}
		for _, d in workspace:GetDescendants() do
			if d:IsA('BasePart') and d.Parent then
				local n = d.Name:lower()
				if n:find('coin') and not n:find('bag') then list[#list + 1] = d end
			end
		end
		coinCache = list
		return list
	end

	local function grab(part, hrp)
		if touchfn then
			pcall(function() touchfn(hrp, part, 0); touchfn(hrp, part, 1) end)
		else
			local save = hrp.CFrame
			hrp.CFrame = part.CFrame
			task.delay(0.05, function() if hrp and hrp.Parent then hrp.CFrame = save end end)
		end
	end

	AutoCollect = vain.Categories.Utility:CreateModule({
		Name = 'Auto Collect Coins',
		Function = function(callback)
			if callback then
				task.spawn(function()
					repeat
						if aliveLocal() then
							local hrp = entitylib.character.RootPart
							local maxR = (Range and Range.Value) or 99999
							for _, part in coins() do
								if not AutoCollect.Enabled then break end
								if part.Parent and (part.Position - hrp.Position).Magnitude <= maxR and not collected[part] then
									grab(part, hrp)
									collected[part] = true
									task.delay(1, function() collected[part] = nil end)
								end
							end
						end
						task.wait((Fast and Fast.Enabled) and 0.05 or 0.25)
					until not AutoCollect.Enabled
				end)
			end
		end,
		Tooltip = 'Collects every coin on the map (touch-collect, no teleport when possible). Coin/XP farm.'
	})
	Range = AutoCollect:CreateSlider({ Name = 'Range', Min = 50, Max = 2000, Default = 2000, Suffix = 'studs',
		Tooltip = 'Only collect coins within this range of you.' })
	Fast = AutoCollect:CreateToggle({ Name = 'Fast', Default = true,
		Tooltip = 'Scan/collect more often (snappier, slightly heavier).' })
end)

-- ── Sheriff Auto-Shoot ──────────────────────────────────────────────────────────
run(function()
	local AutoShoot
	local FireRate, MaxRange, Notify
	local lastShot = 0

	AutoShoot = vain.Categories.Combat:CreateModule({
		Name = 'Sheriff Auto-Shoot',
		Function = function(callback)
			if callback then
				task.spawn(function()
					repeat
						if aliveLocal() and store.sheriff == lplr and store.murderer then
							local m = store.murderer
							local ent = entOf(m)
							local hrp = (ent and ent.RootPart) or rootOf(m)
							local alive = (ent and ent.Humanoid and ent.Humanoid.Health > 0) or (m.Character and m.Character:FindFirstChildOfClass('Humanoid') and m.Character:FindFirstChildOfClass('Humanoid').Health > 0)
							if hrp and alive then
								local myHrp = entitylib.character.RootPart
								local maxR = (MaxRange and MaxRange.Value) or 9999
								if (hrp.Position - myHrp.Position).Magnitude <= maxR
									and tick() - lastShot > (1 / ((FireRate and FireRate.Value) or 3)) then
									equipSlot1()
									if aimAt(hrp.Position) then
										clickMouse()
										lastShot = tick()
										if Notify and Notify.Enabled then notif('Sheriff Auto-Shoot', 'shooting the murderer', 1) end
									end
								end
							end
						end
						runService.Heartbeat:Wait()
					until not AutoShoot.Enabled
				end)
			end
		end,
		Tooltip = 'As Sheriff, auto-aims and fires at the known murderer via real mouse input. Pair with Silent Aim for guaranteed hits.'
	})
	FireRate = AutoShoot:CreateSlider({ Name = 'Fire Rate', Min = 1, Max = 10, Default = 3, Suffix = '/s',
		Tooltip = 'Max shots per second.' })
	MaxRange = AutoShoot:CreateSlider({ Name = 'Max Range', Min = 20, Max = 500, Default = 300, Suffix = 'studs' })
	Notify = AutoShoot:CreateToggle({ Name = 'Notify', Default = false })
end)

-- ── Murderer Kill Aura ──────────────────────────────────────────────────────────
run(function()
	local KillAura
	local Range, Delay, Notify
	local lastHit = 0

	local function nearestVictim()
		if not aliveLocal() then return nil end
		local myPos = entitylib.character.RootPart.Position
		local range = (Range and Range.Value) or 14
		local best, bestD
		for _, ent in entitylib.List do
			if ent.Player and ent.Player ~= lplr and ent.Player ~= store.murderer
				and ent.Character and ent.Humanoid and ent.Humanoid.Health > 0 then
				local hrp = ent.RootPart or rootOf(ent.Player)
				if hrp then
					local d = (hrp.Position - myPos).Magnitude
					if d <= range and (not bestD or d < bestD) then best, bestD = ent, d end
				end
			end
		end
		return best
	end

	KillAura = vain.Categories.Combat:CreateModule({
		Name = 'Murderer Kill Aura',
		Function = function(callback)
			if callback then
				task.spawn(function()
					repeat
						if aliveLocal() and store.murderer == lplr then
							local v = nearestVictim()
							local hrp = v and (v.RootPart or rootOf(v.Player))
							if hrp and tick() - lastHit > ((Delay and Delay.Value) or 0.4) then
								equipSlot1()
								if aimAt(hrp.Position) then
									clickMouse()
									lastHit = tick()
									if Notify and Notify.Enabled then notif('Murderer Kill Aura', 'stabbing ' .. v.Player.Name, 1) end
								end
							end
						end
						runService.Heartbeat:Wait()
					until not KillAura.Enabled
				end)
			end
		end,
		Tooltip = 'As Murderer, auto-stabs the nearest player in range via real mouse input. Set Range to your knife reach.'
	})
	Range = KillAura:CreateSlider({ Name = 'Range', Min = 6, Max = 30, Default = 14, Suffix = 'studs',
		Tooltip = 'Knife reach -- how close a victim must be before it strikes.' })
	Delay = KillAura:CreateSlider({ Name = 'Delay', Min = 0.1, Max = 2, Default = 0.4, Suffix = 's',
		Tooltip = 'Seconds between strikes (your knife cooldown).' })
	Notify = KillAura:CreateToggle({ Name = 'Notify', Default = false })
end)
