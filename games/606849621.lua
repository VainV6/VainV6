local loadstring = function(...)
	local res, err = loadstring(...)
	if err and vain then vain:CreateNotification('Vain', 'Failed to load : '..err, 30, 'alert') end
	return res
end
local isfile = isfile or function(file)
	local suc, res = pcall(function() return readfile(file) end)
	return suc and res ~= nil and res ~= ''
end
local function downloadFile(path, func)
	if not isfile(path) then
		local suc, res = pcall(function() return game:HttpGet('https://raw.githubusercontent.com/7GrandDadPGN/VapeV4ForRoblox/'..readfile('vain/profiles/commit.txt')..'/'..select(1, path:gsub('vain/', '')), true) end)
		if not suc or res == '404: Not Found' then error(res) end
		if path:find('.lua') then res = '--This watermark is used to delete the file if its cached, remove it to make the file persist after vain updates.\n'..res end
		writefile(path, res)
	end
	return (func or readfile)(path)
end
local run = function(func) func() end
local cloneref = cloneref or function(obj) return obj end

local playersService = cloneref(game:GetService('Players'))
local replicatedStorage = cloneref(game:GetService('ReplicatedStorage'))
local runService = cloneref(game:GetService('RunService'))
local inputService = cloneref(game:GetService('UserInputService'))
local textService = cloneref(game:GetService('TextService'))
local tweenService = cloneref(game:GetService('TweenService'))
local teamsService = cloneref(game:GetService('Teams'))
local collectionService = cloneref(game:GetService('CollectionService'))
local contextService = cloneref(game:GetService('ContextActionService'))

local gameCamera = workspace.CurrentCamera
local lplr = playersService.LocalPlayer

local vain = shared.vain
local entitylib = vain.Libraries.entity
local whitelist = vain.Libraries.whitelist
local prediction = vain.Libraries.prediction
local targetinfo = vain.Libraries.targetinfo
local sessioninfo = vain.Libraries.sessioninfo
-- vm.lua is a custom Luau bytecode VM used to map remotes to friendly names.
-- The load can fail (missing file, a download that 404s, an executor without the
-- functions vm.lua needs), which previously left `vm` nil and crashed dumpRemotes
-- at first use. Load it defensively so a failure is non-fatal.
local vm
do
	local ok, chunk = pcall(downloadFile, 'vain/libraries/vm.lua')
	if ok and chunk then
		local loader = loadstring(chunk, 'vm')
		if loader then
			local ran, res = pcall(loader)
			if ran then vm = res end
		end
	end
	if type(vm) ~= 'table' or type(vm.luau_deserialize) ~= 'function' then
		vm = nil
	end
end

local jb = {}
local InfNitro = {Enabled = false}
local LazerGodmode = {Enabled = false}

local function getVehicle(ent)
	if ent.Player then
		for _, car in collectionService:GetTagged('Vehicle') do
			for _, seat in car:GetChildren() do
				if (seat.Name == 'Seat' or seat.Name == 'Passenger') then
					seat = seat:FindFirstChild('PlayerName')
					if seat and seat.Value == ent.Player.Name then
						return car
					end
				end
			end
		end
	end
end

local function isArrested(name)
	-- spec.Name is a localized display string, so match on PlayerName + the
	-- presence of the ShouldArrest field (the arrest spec) instead of v.Name.
	for i, v in jb.CircleAction.Specs do
		if v.PlayerName == name and v.ShouldArrest ~= nil then
			return not v.ShouldArrest
		end
	end
	return false
end

local function isFriend(plr, recolor)
	if vain.Categories.Friends.Options['Use friends'].Enabled then
		local friend = table.find(vain.Categories.Friends.ListEnabled, plr.Name) and true
		if recolor then
			friend = friend and vain.Categories.Friends.Options['Recolor visuals'].Enabled
		end
		return friend
	end
	return nil
end

local function isIllegal(ent)
	if ent.Player and ent.Player.Team == teamsService.Prisoner then
		local items = ent.Player:FindFirstChild('CurrentInventory')
		items = items and items.Value
		if items then
			for i, v in items:GetChildren() do
				if v.Name ~= 'MansionInvite' then
					return true
				end
			end
		end

		return ent.Illegal
	end
	return true
end

local function isTarget(plr)
	return table.find(vain.Categories.Targets.ListEnabled, plr.Name) and true
end

local function notif(...)
	return vain:CreateNotification(...)
end

-- universal.lua loads BEFORE this file and creates a generic 'Silent Aim'
-- module that duplicates the richer Jailbreak-specific 'SilentAim' (no space)
-- defined below. Since this file loads second, vain.Modules already holds the
-- universal copy -- remove it so only the Jailbreak version remains.
run(function()
	for _, dupeName in {'Silent Aim'} do
		if vain.Modules[dupeName] then
			vain:Remove(dupeName)
		end
	end
end)

run(function()
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
			},
			{
				Connect = function()
					return hum:GetPropertyChangedSignal('Sit'):Connect(function()
						if getVehicle(ent) then
							ent.Illegal = true
						end
					end)
				end
			}
		}
	end

	entitylib.targetCheck = function(ent)
		if ent.TeamCheck then return ent:TeamCheck() end
		if ent.NPC then return true end
		if isFriend(ent.Player) then return false end
		if not select(2, whitelist:get(ent.Player)) then return false end
		if lplr.Team == teamsService.Police then
			return ent.Player.Team ~= teamsService.Police
		else
			return ent.Player.Team == teamsService.Police
		end
		return true
	end
end)
entitylib.start()

run(function()
	local getscriptbytecode = getscriptbytecode or (getgenv and getgenv().getscriptbytecode) or dumpstring
	local function dumpRemotes(scripts, renamed)
		local returned = {}

		-- If the bytecode VM or the bytecode dumper is unavailable on this
		-- executor, we can't derive friendly remote names. Return empty so the
		-- module still loads (fireHook just falls back to raw remote ids).
		if type(vm) ~= 'table' or type(vm.luau_deserialize) ~= 'function' or type(getscriptbytecode) ~= 'function' then
			return returned
		end

		for _, scr in scripts do
			-- Wrap per-script so one unparseable script (or a deserialize error)
			-- doesn't abort the whole dump and crash module init.
			local ok, deserializedcode = pcall(function()
				return vm.luau_deserialize(getscriptbytecode(scr))
			end)
			if not ok or type(deserializedcode) ~= 'table' or not deserializedcode.protoList then
				continue
			end

			for _, proto in deserializedcode.protoList do
				local stack, top, code = {}, -1, proto.code
				for i, inst in code do
					if inst.opcode == 4 then -- LOADN
						stack[inst.A] = inst.D
					elseif inst.opcode == 5 then -- LOADK
						stack[inst.A] = inst.K
					elseif inst.opcode == 6 then -- MOVE
						stack[inst.A] = stack[inst.B]
					elseif inst.opcode == 12 then -- GETIMPORT
						local count, import = inst.KC, getrenv()[inst.K0]

						if count == 1 then
							stack[inst.A] = import
						elseif count == 2 then
							stack[inst.A] = import[inst.K1]
						elseif count == 3 then
							stack[inst.A] = import[inst.K1][inst.K2]
						end
					elseif inst.opcode == 20 then -- NAMECALL
						local A, B, kv = inst.A, inst.B, inst.K
						stack[A + 1] = stack[B]

						local callInst = code[i + 2]
						local callA, callB, callC = callInst.A, callInst.B, callInst.C
						local params = if callB == 0 then top - callA else callB - 1
						if kv == 'sub' or kv == 'reverse' then
							local arg1, arg2, arg3 = table.unpack(stack, callA + 1, callA + params)
							if kv == 'reverse' and not arg1 then arg1 = 'a' end

							local ret_list = table.pack(string[kv](arg1, arg2, arg3))
							local ret_num = ret_list.n - 1
							if callC == 0 then
								top = callA + ret_num - 1
							else
								ret_num = callC - 1
							end

							table.move(ret_list, 1, ret_num, callA, stack)
						elseif kv == 'FireServer' then
							local name, val = proto.debugname == '(??)' and scr.Name or proto.debugname, stack[callA + 2]
							if name == val then table.insert(returned, val) continue end
							if returned[name] then
								for i = 1, 10 do
									if not returned[name..i] then name ..= i break end
								end
							end

							returned[name] = val
						end
					elseif inst.opcode == 49 then -- CONCAT
						local s = ""
						for i = inst.B, inst.C do
							if type(stack[i]) ~= 'string' then continue end
							s ..= stack[i]
						end
						stack[inst.A] = s
					end
				end
			end
		end

		for i, v in table.clone(returned) do
			if renamed[i] then
				returned[i] = nil
				returned[renamed[i]] = v
			end
		end

		return returned
	end

	local function getCash()
		for i, v in debug.getupvalue(jb.TeamChooseController.Init, 2) do
			if type(v) == 'function' then
				for _, const in debug.getconstants(v) do
					if tostring(const):find('PlusCash') then
						return v, i
					end
				end
			end
		end
	end

	local function toMoney(num)
		local one, two, three = string.match(tostring(num), '^([^%d]*%d)(%d*)(.-)$')
		return one .. (two:reverse():gsub('(%d%d%d)', '%1,'):reverse() .. three)..'$'
	end

	jb = {
		BulletEmitter = require(replicatedStorage.Game.ItemSystem.BulletEmitter),
		CircleAction = require(replicatedStorage.Module.UI).CircleAction,
		CargoController = require(replicatedStorage.Game.Robbery.RobberyPassengerTrain),
		FallingController = require(replicatedStorage.Game.Falling),
		GunController = require(replicatedStorage.Game.Item.Gun),
		HotbarItemSystem = require(replicatedStorage.Hotbar.HotbarItemSystem),
		InventoryItemSystem = require(replicatedStorage.Inventory.InventoryItemSystem),
		ItemSystemController = require(replicatedStorage.Game.ItemSystem.ItemSystem),
		JetPackController = require(replicatedStorage.Game.JetPack.JetPack),
		PlayerUtils = require(replicatedStorage.Game.PlayerUtils),
		RagdollController = require(replicatedStorage.Module.AlexRagdoll),
		TaserController = require(replicatedStorage.Game.Item.Taser),
		TeamChooseController = require(replicatedStorage.TeamSelect.TeamChooseUI),
		VehicleController = require(replicatedStorage.Vehicle.VehicleUtils)
	}

	if not jb.VehicleController.toggleLocalLocked or not jb.VehicleController.NitroShopVisible then
		repeat task.wait() until (jb.VehicleController.toggleLocalLocked and jb.VehicleController.NitroShopVisible) or vain.Loaded == nil
		if vain.Loaded == nil then return end
	end
	-- remotetable holds the shared FireServer used by most action modules. Its
	-- upvalue index can drift on Jailbreak updates; if it can't be resolved,
	-- bail out of setup (with a notification) instead of erroring the whole block
	-- and silently killing every FireServer-based module.
	local remotetable = select(2, pcall(debug.getupvalue, jb.VehicleController.toggleLocalLocked, 2))
	if type(remotetable) ~= 'table' or not remotetable.FireServer then
		notif('Vain', 'Jailbreak: could not resolve the remote table (game updated?). Action modules disabled.', 10, 'alert')
		jb.FireServer = function() end
		return
	end
	local fireserver, hook = remotetable.FireServer

	remotes = dumpRemotes({
		replicatedStorage.Game.TrainSystem.LocomotiveFront,
		replicatedStorage.Game.ItemSystem.ItemSystem,
		replicatedStorage.Game.CashBuyUI,
		replicatedStorage.Game.Item.Taser,
		replicatedStorage.Game.Item.Gun,
		replicatedStorage.Game.Falling,
		lplr.PlayerScripts.LocalScript
	}, {
		Action = 'Pickup',
		Action3 = 'StartRob',
		Action2 = 'EndRob',
		AttemptArrest = 'Arrest',
		attemptPunch = 'Punch',
		AttemptVehicleEject = 'Eject',
		AttemptVehicleEnter = 'GetIn',
		BroadcastInputBegan = 'InputBegan',
		BroadcastInputEnded = 'InputEnded',
		CalculateDelta = 'UseNitro',
		Draw = 'TaseReplicate',
		Gun = 'PopTires',
		LocalScript2 = 'LookAngle',
		LocomotiveFront = 'SelfDamage',
		onPressed = 'FlipVehicle',
		OnJump = 'GetOut',
		OnJump1 = 'GetOut',
		UpdateMousePosition = 'AimPosition'
	})

	-- Hardcoded friendly -> real remote-name fallbacks. The dynamic dumpRemotes
	-- map keys by proto debugname / script name, which drifts every time the game
	-- reshuffles its code (action remotes now live in anonymous closures keyed by
	-- collision order). These were decoded statically from the current place file
	-- and are used whenever the dynamic dump is missing the friendly key, so the
	-- AutoFeatures keep working across updates that only renamed functions.
	-- Decoded from Place_606849621.rbxlx (2026-06-13).
	local REMOTE_FALLBACKS = {
		Arrest = 'ye6k5tad',
		Punch = 'v1w5mwz1',
		Eject = 'c28zzq8w',
		GetIn = 'eomd9qco',
		GetOut = 'yslgeqao',
		Tase = 'fav6jbbv',
		TaseReplicate = 'dxgaejek',
		-- vehicle/tire damage: Gun fires FireServer(<this>, vehicleModel, weaponClass)
		-- when a bullet hits a part under workspace.Vehicles (Gun.lua ~L483). AutoPop
		-- calls jb:FireServer('PopTires', car, 'Sniper') with the same arg shape.
		PopTires = 'eygwrvei',
	}
	for friendly, real in REMOTE_FALLBACKS do
		if not remotes[friendly] then
			remotes[friendly] = real
		end
	end

	local function fireHook(self, id, ...)
		local rem
		for i, v in remotes do
			if v == id then
				rem = i
			end
		end

		if InfNitro.Enabled and rem == 'UseNitro' then return end
		if LazerGodmode.Enabled and rem == 'SelfDamage' then return end

		return hook(self, id, ...)
	end

	hook = hookfunction(fireserver, function(self, id, ...)
		return fireHook(self, id, ...)
	end)

	-- AutoFeatures call jb:FireServer every loop tick. If a remote can't be
	-- resolved (game updated -> obfuscated name changed), warn ONCE per remote
	-- instead of spamming a notification on every single tick.
	local warnedRemotes = {}
	function jb:FireServer(id, ...)
		if not remotes[id] then
			if not warnedRemotes[id] then
				warnedRemotes[id] = true
				notif('Vain', 'Failed to find remote ('..id..')', 10, 'alert')
			end
			return
		end
		return hook(remotetable, remotes[id], ...)
	end

	local arrests = sessioninfo:AddItem('Arrested')
	local moneymade = sessioninfo:AddItem('Money Made', 0, toMoney, true)
	local bounty = sessioninfo:AddItem('Bounty List', '', function()
		-- Bounties live in ReplicatedStorage.BountyData.Value as a JSON array of
		-- {UserId, Bounty}; the old workspace MostWanted.Board UI no longer exists.
		local text = ''
		local list
		local ok, svc = pcall(function() return require(replicatedStorage.Bounty.BountyBoardService) end)
		if ok and type(svc) == 'table' and type(svc.Bounties) == 'table' then
			list = svc.Bounties
		else
			local data = replicatedStorage:FindFirstChild('BountyData')
			if data then
				local good, decoded = pcall(function()
					return cloneref(game:GetService('HttpService')):JSONDecode(data.Value)
				end)
				if good and type(decoded) == 'table' then list = decoded end
			end
		end

		for _, entry in (type(list) == 'table' and list or {}) do
			if type(entry) == 'table' and entry.UserId then
				local plr = playersService:GetPlayerByUserId(entry.UserId)
				local name = plr and (plr.DisplayName or plr.Name) or ('User '..tostring(entry.UserId))
				text = text..'\n'..(name..': '..tostring(entry.Bounty))
			end
		end

		return text
	end, false)

	local cashfunc, cashhook = getCash()
	if cashfunc then
		cashhook = hookfunction(cashfunc, function(amount, text, ...)
			moneymade:Increment(amount)
			if text == 'Arrest' then
				arrests:Increment()
			end
			return cashhook(amount, text, ...)
		end)
	end

	vain:Clean(function()
		table.clear(remotes)
		table.clear(jb)
		hookfunction(fireserver, hook)
		hookfunction(cashfunc, cashhook)
		--restorefunction(fireserver)
		--restorefunction(cashfunc)
	end)
end)

-- Remove universal modules that don't apply to / are superseded in Jailbreak.
-- Guarded: some mainapi builds lack :Remove, and a module may already be gone --
-- a bare crash here aborted the rest of this file (SilentAim etc. never loaded).
run(function()
	for _, v in {'Reach', 'TriggerBot', 'Disabler', 'AntiFall', 'HitBoxes', 'Killaura', 'MurderMystery'} do
		if vain.Modules[v] and type(vain.Remove) == 'function' then
			pcall(vain.Remove, vain, v)
		end
	end
end)
run(function()
	local SilentAim
	local Target
	local Mode
	local Range
	local CircleColor
	local CircleTransparency
	local CircleFilled
	local CircleObject
	local Instant
	local Hooked
	local ProjectileRaycast = RaycastParams.new()
	ProjectileRaycast.RespectCanCollide = true

	SilentAim = vain.Categories.Combat:CreateModule({
		Name = 'SilentAim',
		Function = function(callback)
			if CircleObject then
				CircleObject.Visible = callback and Mode.Value == 'Mouse'
			end
			if callback then
				-- Pure SILENT aim: redirect the bullet trajectory to the target inside
				-- TransformLocalMousePosition. This never moves your mouse or camera --
				-- only the shot's aim point is changed. (The old visible camera-snap that
				-- called mousemoverel has been removed; use the Aimbot module for that.)
				Hooked = jb.GunController.TransformLocalMousePosition
				jb.GunController.TransformLocalMousePosition = function(self, pos)
					local ent = entitylib['Entity'..Mode.Value]({
						Range = Range.Value,
						Wallcheck = Target.Walls.Enabled and (obj or true) or nil,
						Part = 'RootPart',
						Origin = entitylib.isAlive and entitylib.character.RootPart.Position or nil,
						Players = Target.Players.Enabled,
						NPCs = Target.NPCs.Enabled
					})

					if ent then
						local item = jb.ItemSystemController:GetLocalEquipped()
						if item and ((self.Tip.CFrame.Position - ent.RootPart.Position).Magnitude / (item.Config.BulletSpeed or 1000)) < item.BulletEmitter.LifeSpan then
							ProjectileRaycast.FilterDescendantsInstances = {gameCamera, ent.Character}
							ProjectileRaycast.CollisionGroup = ent.RootPart.CollisionGroup
							local calc = prediction.SolveTrajectory(self.Tip.CFrame.Position, item.Config.BulletSpeed or 1000, math.abs(item.BulletEmitter.GravityVector.Y), ent.RootPart.Position, Instant.Enabled and Vector3.zero or ent.RootPart.Velocity, workspace.Gravity, ent.HipHeight, nil, ProjectileRaycast)
							if calc then
								targetinfo.Targets[ent] = tick() + 1
								return calc
							end
						end
					end

					return pos
				end

				-- keep the range circle following the mouse + optional hitscan; NO mouse move
				SilentAim:Clean(runService.RenderStepped:Connect(function()
					if CircleObject then
						CircleObject.Position = inputService:GetMouseLocation()
					end
					if Instant.Enabled then
						local item = jb.ItemSystemController:GetLocalEquipped()
						if item and item.BulletEmitter then
							rawset(item.BulletEmitter, 'LastUpdate', tick() - (item.BulletEmitter.LifeSpan - 0.001))
						end
					end
				end))
			else
				jb.GunController.TransformLocalMousePosition = Hooked
			end
		end,
		Tooltip = 'Silent aim - silently redirects your bullets to the nearest target. Never moves your mouse or camera. Use the Aimbot module for a camera/hit lock.'

	})
	Target = SilentAim:CreateTargets({Players = true})
	Mode = SilentAim:CreateDropdown({
		Name = 'Mode',
		List = {'Mouse', 'Position'},
		Function = function(val)
			if CircleObject then
				CircleObject.Visible = SilentAim.Enabled and val == 'Mouse'
			end
		end,
		Tooltip = 'Mouse - Checks for entities near the mouses position\nPosition - Checks for entities near the local character'
	})
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
		end
	})
	SilentAim:CreateToggle({
		Name = 'Range Circle',
		Function = function(callback)
			if callback then
				CircleObject = Drawing.new('Circle')
				CircleObject.Filled = CircleFilled.Enabled
				CircleObject.Color = Color3.fromHSV(CircleColor.Hue, CircleColor.Sat, CircleColor.Value)
				CircleObject.Position = vain.gui.AbsoluteSize / 2
				CircleObject.Radius = Range.Value
				CircleObject.NumSides = 100
				CircleObject.Transparency = 1 - CircleTransparency.Value
				CircleObject.Visible = SilentAim.Enabled and Mode.Value == 'Mouse'
			else
				pcall(function()
					CircleObject.Visible = false
					CircleObject:Remove()
				end)
			end
			CircleColor.Object.Visible = callback
			CircleTransparency.Object.Visible = callback
			CircleFilled.Object.Visible = callback
		end
	})
	CircleColor = SilentAim:CreateColorSlider({
		Name = 'Circle Color', 
		Function = function(hue, sat, val)
			if CircleObject then
				CircleObject.Color = Color3.fromHSV(hue, sat, val)
			end
		end, 
		Darker = true, 
		Visible = false
	})
	CircleTransparency = SilentAim:CreateSlider({
		Name = 'Transparency',
		Min = 0,
		Max = 1,
		Decimal = 10,
		Default = 0.5,
		Function = function(val)
			if CircleObject then
				CircleObject.Transparency = 1 - val
			end
		end,
		Darker = true,
		Visible = false
	})
	CircleFilled = SilentAim:CreateToggle({
		Name = 'Circle Filled', 
		Function = function(callback)
			if CircleObject then
				CircleObject.Filled = callback
			end
		end, 
		Darker = true, 
		Visible = false
	})
	Instant = SilentAim:CreateToggle({Name = 'Hitscan Bullets', Tooltip = 'Bullets skip their travel time and arrive instantly at the target (no lead needed). Best paired with a target Mode above.'})
end)

-- Dedicated Aimbot: every bullet you fire is silently redirected onto the nearest
-- target in range AND made hitscan (zero travel time), so it lands the instant you
-- shoot with no aiming, leading, or camera movement. This is the one-click "lock
-- everything" preset; SilentAim above is the configurable version.
run(function()
	local Aimbot
	local Target
	local Range
	local AimPart
	local Priority
	local Hooked
	local AimRaycast = RaycastParams.new()
	AimRaycast.RespectCanCollide = true
	local inflatedRoots = {} -- [RootPart] = true, hit radii we enlarged (restore on disable)
	local HITBOX_RADIUS = 20 -- studs; default is 3. Big enough to catch in-car targets.

	-- Target-priority sort functions. Each entitylib sorting item is
	-- {Entity = <ent>, Magnitude = <distance>}; the entity exposes .Humanoid,
	-- .RootPart, .Head, .Character, .Player.
	local function entHealth(ent)
		local h = ent and ent.Humanoid
		return (h and h.Health) or math.huge
	end
	-- angle (radians) between the camera look vector and the direction to the entity;
	-- smaller = closer to your crosshair.
	local function entAngle(ent)
		local part = ent[AimPart and AimPart.Value or 'Head'] or ent.RootPart
		if not part then return math.huge end
		local dir = (part.Position - gameCamera.CFrame.Position)
		if dir.Magnitude == 0 then return math.huge end
		local dot = math.clamp(gameCamera.CFrame.LookVector:Dot(dir.Unit), -1, 1)
		return math.acos(dot)
	end
	-- screen-space distance (pixels) from the actual mouse cursor to the entity;
	-- smaller = nearer the cursor. Off-screen / behind-camera targets are pushed last.
	local function entCursor(ent)
		local part = ent[AimPart and AimPart.Value or 'Head'] or ent.RootPart
		if not part then return math.huge end
		local screen, onScreen = gameCamera:WorldToViewportPoint(part.Position)
		if not onScreen then return math.huge end
		local mouse = inputService:GetMouseLocation()
		return (Vector2.new(screen.X, screen.Y) - mouse).Magnitude
	end
	local sorts = {
		Distance = function(a, b) return a.Magnitude < b.Magnitude end,
		Cursor = function(a, b) return entCursor(a.Entity) < entCursor(b.Entity) end,
		Angle = function(a, b) return entAngle(a.Entity) < entAngle(b.Entity) end,
		Health = function(a, b) return entHealth(a.Entity) < entHealth(b.Entity) end,
		-- threat = whoever is both close AND low-health (easy + dangerous kills first)
		Threat = function(a, b)
			return (a.Magnitude * entHealth(a.Entity)) < (b.Magnitude * entHealth(b.Entity))
		end,
	}

	Aimbot = vain.Categories.Combat:CreateModule({
		Name = 'Aimbot',
		Function = function(callback)
			if callback then
				-- SILENT TRAJECTORY REDIRECT (does NOT move your mouse or camera).
				-- The gun calls TransformLocalMousePosition(self, pos) to decide where the
				-- bullet is aimed; we return a point on the target instead, so the shot
				-- flies to them no matter where you are actually looking. Combined with the
				-- hitscan + inflated hitbox below, every shot lands on the target through
				-- car bodies and at any range.
				Hooked = jb.GunController.TransformLocalMousePosition
				jb.GunController.TransformLocalMousePosition = function(self, pos)
					local part = AimPart and AimPart.Value or 'Head'
					local ent = entitylib.EntityPosition({
						Range = Range.Value,
						Wallcheck = Target.Walls.Enabled and true or nil,
						Part = part,
						Sort = sorts[Priority and Priority.Value or 'Distance'],
						Origin = entitylib.isAlive and entitylib.character.RootPart.Position or nil,
						Players = Target.Players.Enabled,
						NPCs = Target.NPCs.Enabled
					})
					if ent and ent[part] then
						-- Aim STRAIGHT at the target part -- exactly what your manual mouse
						-- aim hands the gun. Hitscan is forced on below, so the bullet has
						-- zero travel time: nothing to lead, no gravity drop to compensate.
						-- The old SolveTrajectory returned a gravity-arc lead point that
						-- overshot at close range, which is why manual aim hit in-car targets
						-- but the aimbot missed.
						targetinfo.Targets[ent] = tick() + 1
						return ent[part].Position
					end
					return pos
				end

				-- Make every bullet hitscan (instant), pass through world geometry, and
				-- inflate every target's RootPart hit radius (the emitter sizes its
				-- proximity sphere from RootPart:GetAttribute('HitRadius'), default 3, and
				-- checks it BEFORE the surface raycast) so a shot near the target lands
				-- regardless of the car body.
				Aimbot:Clean(runService.RenderStepped:Connect(function()
					local item = jb.ItemSystemController:GetLocalEquipped()
					if item and item.BulletEmitter then
						rawset(item.BulletEmitter, 'LastUpdate', tick() - (item.BulletEmitter.LifeSpan - 0.001))
						item.BulletEmitter.IgnoreList = {workspace}
					end
					for _, e in entitylib.List do
						if e.Targetable
							and ((e.Player and Target.Players.Enabled) or (e.NPC and Target.NPCs.Enabled)) then
							-- Inflate the hit radius on BOTH the entitylib RootPart and the
							-- character's literal HumanoidRootPart -- the BulletEmitter reads
							-- the tagged character's .RootPart (the HumanoidRootPart), so we
							-- must enlarge that exact instance for in-car hits to register.
							local parts = {e.RootPart}
							local char = e.Character
							local hrp = char and char:FindFirstChild('HumanoidRootPart')
							if hrp then parts[#parts + 1] = hrp end
							for _, part in parts do
								if part then
									inflatedRoots[part] = true
									part:SetAttribute('HitRadius', HITBOX_RADIUS)
								end
							end
						end
					end
				end))
			else
				jb.GunController.TransformLocalMousePosition = Hooked
				local item = jb.ItemSystemController:GetLocalEquipped()
				if item and item.BulletEmitter then
					item.BulletEmitter.IgnoreList = {}
				end
				for root in inflatedRoots do
					pcall(function() root:SetAttribute('HitRadius', nil) end)
				end
				table.clear(inflatedRoots)
			end
		end,
		Tooltip = 'Silently redirects every shot onto the highest-priority target -- no mouse or camera movement. Hitscan + inflated hitboxes make it land through car bodies and at any range.'

	})
	Target = Aimbot:CreateTargets({Players = true})
	AimPart = Aimbot:CreateDropdown({
		Name = 'Aim Part',
		List = {'Head', 'RootPart'},
		Tooltip = 'Which body part to aim at. Head is more exposed for players inside vehicles.'
	})
	Priority = Aimbot:CreateDropdown({
		Name = 'Priority',
		List = {'Distance', 'Cursor', 'Angle', 'Health', 'Threat'},
		Tooltip = 'Who to target first:\nDistance - closest to you\nCursor - nearest to your mouse cursor on screen\nAngle - closest to your crosshair\nHealth - lowest HP\nThreat - close AND low HP'
	})
	Range = Aimbot:CreateSlider({
		Name = 'Range',
		Min = 1,
		Max = 5000,
		Default = 1000,
		Suffix = function(val)
			return val == 1 and 'stud' or 'studs'
		end
	})
end)

-- Standalone Hitscan: makes EVERY bullet you fire arrive instantly with zero
-- travel time, independent of aiming. The BulletEmitter advances each bullet by
-- (now - LastUpdate) * BulletSpeed every frame (see Game.ItemSystem.BulletEmitter
-- :Update). RenderStepped runs before the gun's Heartbeat Update, so pushing
-- LastUpdate back almost a full LifeSpan each frame makes the very next step move
-- the bullet its ENTIRE max travel distance at once -- it lands the moment it is
-- fired instead of flying at BulletSpeed. Pure local timing change, no remote.
run(function()
	local Hitscan

	Hitscan = vain.Categories.Combat:CreateModule({
		Name = 'Hitscan',
		Function = function(callback)
			if callback then
				Hitscan:Clean(runService.RenderStepped:Connect(function()
					local item = jb.ItemSystemController:GetLocalEquipped()
					if item and item.BulletEmitter then
						rawset(item.BulletEmitter, 'LastUpdate', tick() - (item.BulletEmitter.LifeSpan - 0.001))
					end
				end))
			end
		end,
		Tooltip = 'Your bullets hit instantly with zero travel time -- no leading or waiting for the projectile. Works with any gun, with or without aimbot.'
	})
end)

run(function()
	local Wallbang = {Enabled = false}
	
	Wallbang = vain.Categories.Combat:CreateModule({
		Name = 'Wallbang',
		Function = function(callback)
			if callback then
				local hook
				hook = hookfunction(jb.GunController.BulletEmitterOnLocalHitPlayer, function(...)
					-- Guard the metadata arg: its position/type can shift between game
					-- versions, and forcing fields on a non-table threw "index nil".
					local shotData = select(15, ...)
					if type(shotData) == 'table' then
						shotData.isWallbang = nil
						shotData.isHeadshot = true
					end
					-- pcall the original: if the gun's damage remote isn't present on
					-- this hit (Gun.lua FindFirstChild(DAMAGE_REMOTE_NAME) -> nil), the
					-- original errors -- swallow it so it doesn't spam the console.
					local results = {pcall(hook, ...)}
					if results[1] then
						return table.unpack(results, 2)
					end
				end)
	
				repeat
					local item = jb.ItemSystemController:GetLocalEquipped()
					if item and item.BulletEmitter then
						item.BulletEmitter.IgnoreList = {workspace}
					end
					task.wait(0.1)
				until not Wallbang.Enabled
			else
				restorefunction(jb.GunController.BulletEmitterOnLocalHitPlayer)
			end
		end,
		Tooltip = 'Modifies bullets to always do headshot damage & shooting through most walls.'
	})
end)

run(function()
	-- NoSpread zeroes the LOCAL gun's BulletSpread AND CamShakeMagnitude (the
	-- per-gun camera-shake amount that makes your screen jolt on every shot).
	-- Both live on item.Config and are client-owned -- the game reads them to aim
	-- the shot / shake your camera; it does not change movement/position, so the
	-- position-based anticheat has nothing to flag. Originals restored on disable.
	--
	-- It also kills RECOIL: each shot the gun calls item.SpringCamera:Accelerate(
	-- dir * 0.15 * CamShakeMagnitude * t) (verified in Game.Item.Gun), so zeroing
	-- CamShakeMagnitude already cancels the kick. As a belt-and-suspenders for guns
	-- with a non-shake recoil path, we also pin the recoil spring's velocity (.v)
	-- and position (.p) to zero each tick -- the Spring (Module.Spring) stores its
	-- state in .p/.v/.Target, so a zeroed spring produces no camera movement.
	local NoSpread
	local FIELDS = {'BulletSpread', 'CamShakeMagnitude'}
	local originals = {} -- [Config] = {Field = originalValue}

	NoSpread = vain.Categories.Combat:CreateModule({
		Name = 'NoSpread',
		Function = function(callback)
			if callback then
				repeat
					local item = jb.ItemSystemController:GetLocalEquipped()
					local cfg = item and item.Config
					if cfg then
						for _, field in FIELDS do
							if type(cfg[field]) == 'number' then
								originals[cfg] = originals[cfg] or {}
								if originals[cfg][field] == nil then
									originals[cfg][field] = cfg[field]
								end
								if cfg[field] ~= 0 then
									cfg[field] = 0
								end
							end
						end
					end
					-- damp the recoil spring so any residual kick decays to nothing
					local spring = item and item.SpringCamera
					if type(spring) == 'table' then
						pcall(function()
							spring.v = spring.v * 0
							spring.p = spring.p * 0
							if spring.Target then spring.Target = spring.Target * 0 end
						end)
					end
					task.wait(0.05)
				until not NoSpread.Enabled
			else
				for cfg, fields in originals do
					for field, val in fields do
						pcall(function() cfg[field] = val end)
					end
				end
				table.clear(originals)
			end
		end,
		Tooltip = 'Removes bullet spread, camera shake AND recoil on your equipped gun for pinpoint, jolt-free shots. Client-side gun config + recoil spring only (no movement), so the anticheat does not flag it.'
	})
end)

run(function()
	-- Bounty ESP: highlight players that appear on the Most Wanted board and show
	-- their bounty above their head. This is purely client-side rendering (a
	-- Highlight + BillboardGui in your own PlayerGui/character) -- it reads the
	-- existing in-world board and never touches movement or fires a remote, so
	-- the anticheat has nothing to detect.
	local BountyESP
	local MinBounty
	local highlights = {} -- [Player] = {Highlight, BillboardGui}

	-- Read the live Most Wanted list. The game no longer scrapes a workspace UI
	-- board; bounties are a JSON array in ReplicatedStorage.BountyData.Value,
	-- decoded by Bounty.BountyBoardService into .Bounties = {{UserId, Bounty}, ...}.
	--
	-- We decode the raw BountyData.Value JSON FIRST: requiring BountyBoardService
	-- from the exploit thread can hand back a fresh module instance whose init()
	-- never ran, leaving .Bounties empty (this is why BountyESP showed nothing).
	-- The raw value is always populated by the server. The service is only a
	-- secondary source if the JSON decode somehow fails.
	local bountyService = select(2, pcall(function()
		return require(replicatedStorage.Bounty.BountyBoardService)
	end))
	local httpService = cloneref(game:GetService('HttpService'))
	local function readBoard()
		local map = {}
		local list

		local data = replicatedStorage:FindFirstChild('BountyData')
		if data then
			local ok, decoded = pcall(function() return httpService:JSONDecode(data.Value) end)
			if ok and type(decoded) == 'table' and next(decoded) ~= nil then
				list = decoded
			end
		end
		-- secondary: the service's decoded cache (only if it actually has entries)
		if not list and type(bountyService) == 'table' and type(bountyService.Bounties) == 'table' and next(bountyService.Bounties) ~= nil then
			list = bountyService.Bounties
		end

		if type(list) ~= 'table' then return map end
		for _, entry in list do
			if type(entry) == 'table' and entry.UserId then
				local num = tonumber((tostring(entry.Bounty):gsub('[^%d]', ''))) or 0
				map[entry.UserId] = num
			end
		end
		return map
	end

	local function clear(plr)
		local h = highlights[plr]
		if h then
			pcall(function() h.Highlight:Destroy() end)
			pcall(function() h.Billboard:Destroy() end)
			highlights[plr] = nil
		end
	end

	local function clearAll()
		for plr in highlights do clear(plr) end
	end

	local function format(num)
		return '$' .. tostring(num):reverse():gsub('(%d%d%d)', '%1,'):reverse():gsub('^,', '')
	end

	local function update()
		local board = readBoard()
		local min = MinBounty and MinBounty.Value or 0

		-- remove highlights for players no longer qualifying
		for plr in highlights do
			local b = board[plr.UserId]
			if not b or b < min or not plr.Character then
				clear(plr)
			end
		end

		for _, ent in entitylib.List do
			local plr = ent.Player
			local b = plr and board[plr.UserId]
			if plr and b and b >= min and ent.Character then
				local data = highlights[plr]
				if not data then
					local hl = Instance.new('Highlight')
					hl.Name = 'VainBounty'
					hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
					hl.FillColor = Color3.fromRGB(255, 170, 0)
					hl.OutlineColor = Color3.fromRGB(255, 200, 60)
					hl.FillTransparency = 0.6
					hl.Adornee = ent.Character
					hl.Parent = ent.Character

					local bb = Instance.new('BillboardGui')
					bb.Name = 'VainBountyTag'
					bb.Size = UDim2.fromOffset(120, 18)
					bb.StudsOffset = Vector3.new(0, 3.2, 0)
					bb.AlwaysOnTop = true
					bb.Adornee = ent.Character:FindFirstChild('Head') or ent.Character.PrimaryPart
					bb.Parent = ent.Character
					local label = Instance.new('TextLabel')
					label.Size = UDim2.fromScale(1, 1)
					label.BackgroundTransparency = 1
					label.Font = Enum.Font.GothamBold
					label.TextSize = 14
					label.TextColor3 = Color3.fromRGB(255, 200, 60)
					label.TextStrokeTransparency = 0.4
					label.Parent = bb

					data = {Highlight = hl, Billboard = bb, Label = label}
					highlights[plr] = data
				end
				if data.Label then data.Label.Text = format(b) end
				if data.Billboard and (not data.Billboard.Adornee or data.Billboard.Adornee.Parent == nil) then
					data.Billboard.Adornee = ent.Character:FindFirstChild('Head') or ent.Character.PrimaryPart
				end
				if data.Highlight and data.Highlight.Adornee ~= ent.Character then
					data.Highlight.Adornee = ent.Character
					data.Highlight.Parent = ent.Character
				end
			end
		end
	end

	BountyESP = vain.Categories.Render:CreateModule({
		Name = 'BountyESP',
		Function = function(callback)
			if callback then
				task.spawn(function()
					repeat
						update()
						task.wait(0.5)
					until not BountyESP.Enabled
					clearAll()
				end)
			else
				clearAll()
			end
		end,
		Tooltip = 'Highlights Most Wanted players and shows their bounty. Client-side render only -- undetectable by the anticheat.'
	})
	MinBounty = BountyESP:CreateSlider({
		Name = 'Min Bounty',
		Min = 0,
		Max = 50000,
		Default = 0,
		Suffix = '$'
	})
end)

run(function()
	local AutoArrest = {Enabled = false}
	local InstaArrest
	local ArrestRange
	local arrestDebounce = {} -- [Player] = tick(), avoid re-firing on the same target every frame

	-- The game decides team by player.TeamValue.Value (a string "Police" /
	-- "Prisoner"), NOT the Roblox Teams service -- gating on lplr.Team was
	-- comparing against a possibly-nil Team object, so AutoArrest never ran.
	local function teamOf(plr)
		local tv = plr and plr:FindFirstChild('TeamValue')
		if tv then return tv.Value end
		return plr and plr.Team and plr.Team.Name
	end

	-- Fire the arrest remote for a player. Lightly rate-limited (every 0.1s) so we
	-- keep RE-FIRING until the server actually registers the arrest, instead of
	-- giving up after one packet -- this is what makes it land 100% of the time
	-- even if the first attempt is dropped or arrives a frame too early.
	local function tryArrest(plr)
		if not plr then return end
		local last = arrestDebounce[plr]
		if not last or tick() - last > 0.1 then
			arrestDebounce[plr] = tick()
			-- the game fires the arrest remote with the PLAYER INSTANCE
			-- (Players:FindFirstChild(name) -> Player), not the name string
			jb:FireServer('Arrest', plr)
		end
	end

	-- AutoArrest needs Handcuffs EQUIPPED (the diagnostic showed cuffs=false was
	-- the blocker -- you can't arrest with another item out). Equip them for the
	-- user via the game's own inventory system instead of requiring it manually.
	local lastEquipTry = 0
	local function ensureHandcuffs()
		local equipped = jb.ItemSystemController:GetLocalEquipped()
		if equipped and equipped.__ClassName == 'Handcuffs' then return true end
		-- throttle so we don't spam equip every frame
		if tick() - lastEquipTry < 0.5 then return false end
		lastEquipTry = tick()
		local inv = jb.InventoryItemSystem
		if not inv or not inv.getInventoryItemsFor then return false end
		local ok, items = pcall(inv.getInventoryItemsFor, lplr)
		if not ok or type(items) ~= 'table' then return false end
		for _, it in items do
			local name = it.obj and it.obj.Name
			if name == 'Handcuffs' then
				pcall(function()
					if inv.toggleEquip then
						inv.toggleEquip(it)
					elseif it.AttemptSetEquipped then
						it:AttemptSetEquipped(true)
					end
				end)
				return false -- equip is async; report not-yet-equipped this pass
			end
		end
		return false
	end

	AutoArrest = vain.Categories.Blatant:CreateModule({
		Name = 'AutoArrest',
		Function = function(callback)
			if callback then
				-- One-time diagnostic so we can SEE why an arrest does/doesn't fire instead
				-- of guessing: reports my team, whether handcuffs are equipped, and how many
				-- nearby prisoners were seen on the first pass.
				local diagDone = false
				-- The game's ShouldArrest test (decoded) is purely: target is a Prisoner with
				-- a Humanoid, NOT already handcuffed, and NOT in a vehicle. There is NO client
				-- distance gate (distance is server-side). We mirror exactly that -- earlier a
				-- too-strict distance/team gate was silently rejecting valid arrests. Handcuffs
				-- equipped + Police team are the only local prerequisites (u803/u756).
				repeat
					local mine = teamOf(lplr)
					if entitylib.isAlive and mine == 'Police' then
						-- auto-equip handcuffs (the diagnostic showed cuffs=false was the
						-- blocker). hasCuffs is true only once they are actually out.
						local hasCuffs = ensureHandcuffs()
						if not diagDone then
							diagDone = true
							notif('AutoArrest', ('Active. Team='..tostring(mine)..', equipping/using handcuffs.'), 5)
						end
						if hasCuffs then
							for _, ent in entitylib.AllPosition({ Players = true, Part = 'RootPart', Range = 1000 }) do
								if not AutoArrest.Enabled then break end
								local plr = ent.Player
								local tchar = plr and plr.Character
								if plr and tchar and ent.Humanoid and teamOf(plr) == 'Prisoner' then
									local inVehicle = ent.Humanoid.Sit
										or tchar:GetAttribute('InVehicle')
										or getVehicle(ent)
									local cuffed = tchar:GetAttribute('HasHandcuffs')
									if inVehicle then
										local vehicle = getVehicle(ent)
										if vehicle then jb:FireServer('Eject', vehicle) end
									elseif not cuffed then
										tryArrest(plr)
									end
								end
							end
						end
					elseif not diagDone then
						diagDone = true
						notif('AutoArrest', ('Idle: you are not on the Police team. Team='..tostring(mine)), 8, 'alert')
					end
					task.wait(0.1)
				until not AutoArrest.Enabled
				table.clear(arrestDebounce)
			end
		end,
		Tooltip = 'Instantly arrests nearby criminals the moment they are in range, reading the game arrest prompts. Ejects them from vehicles first.'
	})
	InstaArrest = AutoArrest:CreateToggle({
		Name = 'Insta Arrest',
		Default = true,
		Tooltip = 'Arrest immediately without needing handcuffs equipped or waiting between arrests.'
	})
	ArrestRange = AutoArrest:CreateSlider({
		Name = 'Arrest Range',
		Min = 1,
		Max = 50,
		Default = 18,
		Suffix = function(val)
			return val == 1 and 'stud' or 'studs'
		end,
		Tooltip = 'How close a criminal must be to arrest. The server enforces ~18 studs; higher values just try sooner.'
	})
end)
	
run(function()
	local AutoPop
	local Range
	local HandCheck
	local TeamCheck
	
	local function getEntitiesInVehicle(car)
		local entities = {}
	
		for _, seat in car:GetChildren() do
			if (seat.Name == 'Seat' or seat.Name == 'Passenger') then
				seat = seat:FindFirstChild('PlayerName')
				if seat then
					for _, ent in entitylib.List do
						if ent.Player and ent.Player.Name == seat.Value then
							table.insert(entities, ent)
						end
					end
				end
			end
		end
	
		return entities
	end
	
	local function getVehiclesNear()
		local allowed = {}
	
		if entitylib.isAlive then
			local localPosition = entitylib.character.HumanoidRootPart.Position
			for _, car in collectionService:GetTagged('Vehicle') do
				if car.PrimaryPart and (car.PrimaryPart.Position - localPosition).Magnitude <= Range.Value then
					local entities = getEntitiesInVehicle(car)
					local check = #entities > 0
					if TeamCheck.Enabled then
						for _, ent in entities do
							if not ent.Targetable then 
								check = false 
								break 
							end
						end
					end
					
					if check then 
						table.insert(allowed, car) 
					end
				end
			end
		end
	
		return allowed
	end
	
	AutoPop = vain.Categories.Blatant:CreateModule({
		Name = 'AutoPop',
		Function = function(callback)
			if callback then
				task.spawn(function()
					repeat
						local item = jb.ItemSystemController:GetLocalEquipped()
						if (not HandCheck.Enabled) or item and item.BulletEmitter then
							for _, car in getVehiclesNear() do
								if not AutoPop.Enabled then break end
								jb:FireServer('PopTires', car, 'Sniper')
								task.wait(0.1)
							end
						end
						task.wait(0.016)
					until not AutoPop.Enabled
				end)
			end
		end,
		Tooltip = 'Automatically pops vehicles tires around you'
	})
	Range = AutoPop:CreateSlider({
		Name = 'Range',
		Min = 1,
		Max = 600,
		Default = 600
	})
	HandCheck = AutoPop:CreateToggle({Name = 'Hand Check'})
	TeamCheck = AutoPop:CreateToggle({Name = 'Team Check'})
end)

run(function()
	-- AutoRob: when you're standing in a robbable zone, fire the SAME StartRob
	-- remote the game fires when you press the robbery prompt -- nothing more.
	-- It does not move you or teleport, and the server validates that you're
	-- actually in the zone, so the position-based anticheat has nothing to flag.
	-- Robberies then auto-progress while you stand there (pair with InstantAction).
	local AutoRob
	local lastFire = {} -- [robberyObject] = tick(), debounce so we don't spam

	-- Is this tagged robbery object currently robbable (not already in progress)?
	local function robbable(obj)
		-- RobberyState / InProgress live as an attribute or value on the object.
		local inProgress = obj:GetAttribute('InProgress')
		if inProgress == nil then
			local v = obj:FindFirstChild('InProgress')
			inProgress = v and v.Value
		end
		return not inProgress
	end

	AutoRob = vain.Categories.Blatant:CreateModule({
		Name = 'AutoRob',
		Function = function(callback)
			if callback then
				repeat
					if entitylib.isAlive then
						-- use the server-trusted position the anticheat itself
						-- tracks, so our range check matches what it sees
						local hum = entitylib.character.Humanoid
						local serverPos = hum and hum:FindFirstChild('HumanoidUnloadServerPosition')
						local myPos = (serverPos and serverPos.Value) or entitylib.character.RootPart.Position

						for _, obj in collectionService:GetTagged('Robbery') do
							if not AutoRob.Enabled then break end
							local part = obj:IsA('BasePart') and obj or obj.PrimaryPart or obj:FindFirstChildWhichIsA('BasePart', true)
							if part and (part.Position - myPos).Magnitude <= 25 and robbable(obj) then
								if (tick() - (lastFire[obj] or 0)) > 1.5 then
									lastFire[obj] = tick()
									jb:FireServer('StartRob', obj)
								end
							end
						end
					end
					task.wait(0.25)
				until not AutoRob.Enabled
			end
		end,
		Tooltip = 'Automatically starts the robbery you are standing in (fires the same StartRob the game does). Pair with InstantAction. Anticheat-safe -- no movement.'
	})
end)

run(function()
	local Punch = {Enabled = false}
	
	Punch = vain.Categories.Blatant:CreateModule({
		Name = 'AutoPunch',
		Function = function(callback)
			if callback then
				repeat
					if entitylib.isAlive then 
						jb:FireServer('Punch') 
					end
					task.wait(0.3)
				until not Punch.Enabled
			end
		end,
		Tooltip = 'Always punches people infront of you'
	})
end)
	
run(function()
	local AutoTaze = {Enabled = false}
	local AutoTazeHandCheck = {Enabled = false}
	
	AutoTaze = vain.Categories.Blatant:CreateModule({
		Name = 'AutoTaze',
		Function = function(callback)
			if callback then
				repeat
					local item = jb.ItemSystemController:GetLocalEquipped()
					item = item and item.__ClassName == 'Taser' and item or nil
					if item then
						-- Respect the taser's real cooldown: the game stores the next
						-- usable time as a NextUse attribute on the item and refuses to
						-- tase before it. Firing during cooldown does nothing (a miss),
						-- which is why the flat 10s wait dropped shots. Use the gun's own
						-- range too, not a guessed 50.
						local nextUse = item.inventoryItemValue and item.inventoryItemValue:GetAttribute('NextUse')
						local ready = not (type(nextUse) == 'number' and os.clock() < nextUse)
						local range = (item.Config and item.Config.Range) or 50
						if ready then
							local ent = entitylib.EntityPosition({
								Players = true,
								Part = 'RootPart',
								Range = range
							})
							if ent and ent.RootPart and ent.Humanoid and isIllegal(ent) and not isArrested(ent.Player.Name) then
								-- Match the args the game's own Tase sends: the target's
								-- PrimaryPart (RootPart) and a hit position ON that part --
								-- NOT the head. The server validates the hit part/position,
								-- so sending the head got hits rejected.
								local pos = ent.RootPart.Position
								jb:FireServer('TaseReplicate', pos)
								jb:FireServer('Tase', ent.Humanoid, ent.RootPart, pos)
							end
						end
					end
					task.wait(0.05)
				until not AutoTaze.Enabled
			end
		end,
		Tooltip = 'Immobilizes nearby criminals with the taser. Respects the taser cooldown and range and sends the hit data the game does, so the server accepts it.'
	})
	AutoTazeHandCheck = AutoTaze:CreateToggle({Name = 'Hand Check'})
end)
	
run(function()
	LazerGodmode = vain.Categories.Blatant:CreateModule({Name = 'LazerGodmode'})
end)
	
run(function()
	local NoFall

	-- The old method hard-coded upvalue 19 / constant 9 of FallingController.Init,
	-- which Jailbreak shifts on updates (hence "Patch point not found"). Instead,
	-- SEARCH the Init closure's upvalues for the function that ragdolls you and
	-- swap its 'Sit' constant: a function holding both 'Sit' and a ragdoll/falling
	-- state constant is the fall handler. Returns (func, constIndex) or nil.
	local function findFallPatch()
		local ok, init = pcall(function() return jb.FallingController.Init end)
		if not ok or type(init) ~= 'function' then return nil end
		for i = 1, 40 do
			local okv, up = pcall(debug.getupvalue, init, i)
			if okv and type(up) == 'function' then
				local okc, consts = pcall(debug.getconstants, up)
				if okc and type(consts) == 'table' then
					local sitIndex, looksLikeFall
					for ci, c in consts do
						if c == 'Sit' then sitIndex = ci end
						if c == 'FallingDown' or c == 'Ragdoll' or c == 'PlatformStand' or c == 'GettingUp' then
							looksLikeFall = true
						end
					end
					if sitIndex and looksLikeFall then
						return up, sitIndex
					end
				end
			end
		end
		return nil
	end

	-- Fallback: keep the ragdoll-causing Humanoid states disabled client-side.
	local stateThread
	local RAGDOLL_STATES = {
		Enum.HumanoidStateType.FallingDown,
		Enum.HumanoidStateType.Ragdoll,
		Enum.HumanoidStateType.PlatformStanding,
	}
	local function setRagdollStates(enabled)
		local char = entitylib.isAlive and entitylib.character
		local hum = char and char.Humanoid
		if not hum then return end
		for _, st in RAGDOLL_STATES do
			pcall(hum.SetStateEnabled, hum, st, enabled)
		end
	end

	local usingConstant = false -- remember which method we enabled with

	NoFall = vain.Categories.Blatant:CreateModule({
		Name = 'NoFall',
		Function = function(callback)
			if callback then
				-- Preferred: flip the fall handler's 'Sit' constant so it no-ops.
				local func, idx = findFallPatch()
				if func and idx and pcall(debug.setconstant, func, idx, 'Archivable') then
					usingConstant = true
					return
				end
				-- Fallback: keep the ragdoll-causing states disabled ourselves.
				usingConstant = false
				setRagdollStates(false)
				stateThread = task.spawn(function()
					repeat
						setRagdollStates(false)
						task.wait(0.5)
					until not NoFall.Enabled
					setRagdollStates(true)
				end)
			else
				if usingConstant then
					local func, idx = findFallPatch()
					if func and idx then
						pcall(debug.setconstant, func, idx, 'Sit')
					end
					usingConstant = false
				else
					if stateThread then
						pcall(task.cancel, stateThread)
						stateThread = nil
					end
					setRagdollStates(true)
				end
			end
		end,
		Tooltip = 'Disables ragdoll handling & fall damage'
	})
end)
	
run(function()
	local InfiniteNitro
	-- Resolve the nitro state table defensively: this debug.getupvalue index can
	-- drift when Jailbreak updates VehicleController, which previously made the
	-- whole module error on load. If it can't be found, disable cleanly with a
	-- notification instead of crashing.
	local nitrotable = select(2, pcall(debug.getupvalue, jb.VehicleController.NitroShopVisible, 1))
	local oldnitro

	InfiniteNitro = vain.Categories.Utility:CreateModule({
		Name = 'InfiniteNitro',
		Function = function(callback)
			if type(nitrotable) ~= 'table' then
				if callback then
					notif('InfiniteNitro', 'Could not find the nitro table (game updated?). Disabling.', 6, 'alert')
					InfiniteNitro:Toggle()
				end
				return
			end
			-- Mirror state onto InfNitro so fireHook also blocks the UseNitro
			-- remote (stops the server draining boost), not just the local refill.
			InfNitro.Enabled = callback and true or false
			if callback then
				oldnitro = nitrotable.Nitro
				pcall(jb.VehicleController.updateSpdBarRatio, 1)
				repeat
					nitrotable.Nitro = 250
					task.wait(0.1)
				until not InfiniteNitro.Enabled
			else
				nitrotable.Nitro = oldnitro
				pcall(jb.VehicleController.updateSpdBarRatio, (oldnitro or 250) / 250)
			end
		end,
		Tooltip = 'Infinite boost for the local car'
	})
end)

run(function()
	-- Infinite Jetpack fuel: the JetPack controller (Game.JetPack.JetPack) stores
	-- the local fuel as plain table fields LocalFuel / LocalMaxFuel on the returned
	-- module, and consumes it client-side each thrust frame (LocalFuel = LocalFuel
	-- - dt * ...). We just keep LocalFuel pinned to LocalMaxFuel on a cycle -- same
	-- approach as InfiniteNitro. Pure local state, never fires a remote, so there's
	-- nothing for the anticheat to flag.
	local InfiniteJetpack
	local jp = jb.JetPackController

	InfiniteJetpack = vain.Categories.Utility:CreateModule({
		Name = 'InfiniteJetpack',
		Function = function(callback)
			if type(jp) ~= 'table' or type(jp.LocalFuel) ~= 'number' then
				if callback then
					notif('InfiniteJetpack', 'Could not find the jetpack fuel (game updated?). Disabling.', 6, 'alert')
					InfiniteJetpack:Toggle()
				end
				return
			end
			if callback then
				repeat
					jp.LocalFuel = jp.LocalMaxFuel or jp.LocalFuel
					task.wait(0.1)
				until not InfiniteJetpack.Enabled
			end
		end,
		Tooltip = 'Keeps your jetpack fuel topped up so it never runs out. Local fuel state only (no remote), so the anticheat does not flag it.'
	})
end)

run(function()
	local InstantAction
	InstantAction = vain.Categories.Utility:CreateModule({
		Name = 'InstantAction',
		Function = function(callback)
			-- Constant index 3 of CircleAction.Press drifts on updates; guard it.
			local ok = pcall(debug.setconstant, jb.CircleAction.Press, 3, callback and 'Timeda' or 'Timed')
			if not ok and callback then
				notif('InstantAction', 'Patch point not found (game updated?). Disabling.', 6, 'alert')
				InstantAction:Toggle()
			end
		end,
		Tooltip = 'Allows you to instantly complete ProximityPrompt actions'
	})
end)
	
run(function()
	local KeySpoofer
	KeySpoofer = vain.Categories.Utility:CreateModule({
		Name = 'KeySpoofer',
		Function = function(callback)
			if callback then
				local ok = pcall(hookfunction, jb.PlayerUtils.hasKey, function()
					return true
				end)
				if not ok then
					notif('KeySpoofer', 'Could not hook hasKey (game updated?). Disabling.', 6, 'alert')
					KeySpoofer:Toggle()
				end
			else
				pcall(restorefunction, jb.PlayerUtils.hasKey)
			end
		end,
		Tooltip = 'Enables most doors to be walked through'
	})
end)
	