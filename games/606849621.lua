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
	local specs = jb.CircleAction and jb.CircleAction.Specs
	if type(specs) ~= 'table' then return false end
	for i, v in specs do
		if v.PlayerName == name and v.ShouldArrest ~= nil then
			return not v.ShouldArrest
		end
	end
	return false
end

-- An entity is alive if it has a humanoid with health left. entitylib mirrors
-- the humanoid health onto ent.Health.
local function isAliveEnt(ent)
	if not ent then return false end
	local h = ent.Health
	if type(h) == 'number' then return h > 0 end
	local hum = ent.Humanoid
	return hum and hum.Health > 0 or false
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

-- A criminal worth acting on for AutoTaze / Aimbot: alive, illegal, and not
-- already handcuffed/arrested. Skips dead and already-arrested players.
local function isValidCriminal(ent)
	if not (ent and ent.Player) then return false end
	if not isAliveEnt(ent) then return false end
	if not isIllegal(ent) then return false end
	if isArrested(ent.Player.Name) then return false end
	local char = ent.Player.Character
	if char and char:GetAttribute('HasHandcuffs') then return false end
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
	-- IMPORTANT: these obfuscated aliases are RE-RANDOMIZED EVERY GAME BUILD.
	-- They must be re-decoded from the current place file on each Jailbreak
	-- update or the action modules silently no-op (server ignores a dead alias).
	-- Decoded from build "13 Jun @ 12:07 PM EDT @4e0945f":
	--   Arrest=u137, Punch=attemptPunch closure, Eject=u147 (vehicle spec
	--   ShouldEject -> u147(spec.Part.Parent); egi9qmpo was the BREAKOUT remote,
	--   not eject), GetIn=u829, GetOut=exit event, Tase/TaseReplicate from
	--   Game.Item.Taser, PopTires from Game.Item.Gun vehicle-hit.
	local REMOTE_FALLBACKS = {
		Arrest = 'xajzr1t8',
		Punch = 'jv58z10g',
		Eject = 'jhkx8ol1',
		GetIn = 'ttwwg5ep',
		GetOut = 'ywd3edo6',
		Tase = 'm938v2jf',
		TaseReplicate = 'b5tcnkgw',
		PopTires = 's1qvuyxz',
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
	local AutoShoot
	local Hooked
	-- Auto Shoot state: the gun we're currently holding the trigger on, the saved
	-- FireAuto per Config (so semi-autos keep firing while held; restored on stop),
	-- and a fake mouse-down input passed to the gun's own ShootBegin/ShootEnd.
	local triggerItem
	local fireAutoSaved = setmetatable({}, {__mode = 'k'})
	local autoShootInput = {UserInputType = Enum.UserInputType.MouseButton1, KeyCode = Enum.KeyCode.Unknown}
	local AimRaycast = RaycastParams.new()
	AimRaycast.RespectCanCollide = true
	local inflatedRoots = {} -- [RootPart] = true, hit radii we enlarged (restore on disable)
	local HITBOX_RADIUS = 20 -- studs; default is 3. Big enough to catch in-car targets.
	local aimingAtCar = false -- set by the trajectory hook when the current target is in a car

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

	-- ── Auto Shoot ────────────────────────────────────────────────────────────
	-- Release the trigger on whatever gun we were holding it on.
	local function releaseTrigger()
		if triggerItem then
			pcall(function() triggerItem:ShootEnd(autoShootInput) end)
			pcall(function() rawset(triggerItem, 'IsShooting', false) end)
			triggerItem = nil
		end
	end
	-- Hold the trigger on this gun (mirrors a mouse-down): force full-auto so
	-- semi-autos keep firing, then drive the gun's own ShootBegin. Only presses
	-- once per gun -- the gun's Heartbeat handles cadence + server rate-limit.
	local function pressTrigger(item)
		if triggerItem == item then return end
		releaseTrigger()
		triggerItem = item
		local cfg = item.Config
		if cfg then
			if fireAutoSaved[cfg] == nil then fireAutoSaved[cfg] = cfg.FireAuto end
			cfg.FireAuto = true
		end
		-- ShootBegin is the method mouse-down calls; fall back to the flag if absent
		if not pcall(function() item:ShootBegin(autoShootInput) end) then
			pcall(function() rawset(item, 'IsShooting', true) end)
		end
	end
	-- Nearest valid target inside the aimbot's Range, using the same target/part/
	-- priority settings. Skips dead targets and friends (never a teammate).
	local function autoShootTarget()
		local ent = entitylib.EntityPosition({
			Range = Range.Value,
			Part = AimPart and AimPart.Value or 'Head',
			Sort = sorts[Priority and Priority.Value or 'Distance'],
			Origin = entitylib.isAlive and entitylib.character.RootPart.Position or nil,
			Players = Target.Players.Enabled,
			NPCs = Target.NPCs.Enabled
		})
		if not ent then return nil end
		if ent.Player and (not isAliveEnt(ent) or isFriend(ent.Player)) then return nil end
		return ent
	end

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
					-- Skip ONLY dead targets and friends. We deliberately do NOT gate on
					-- isValidCriminal/team here: the aimbot is a general PvP weapon, so it
					-- must be able to shoot ANYONE you target -- including a Prisoner who
					-- isn't committing a crime, a fellow Police officer, or a flying
					-- hacker. (The old criminal-only gate made the aimbot refuse to fire
					-- at non-criminal players: "he can hit me but I can't hit him".)
					if ent and ent.Player then
						if not isAliveEnt(ent) then return pos end
						if isFriend(ent.Player) then return pos end
					end
					if ent and ent[part] then
						-- If the target is in a vehicle, aim at the CAR instead of trying to
						-- shoot the driver through the body -- so the shots hit/pop the car.
						local hum = ent.Humanoid
						if hum and (hum.Sit or (ent.Player and ent.Player.Character and ent.Player.Character:GetAttribute('InVehicle'))) then
							local vehicle = getVehicle(ent)
							local vpart = vehicle and (vehicle.PrimaryPart or vehicle:FindFirstChildWhichIsA('BasePart', true))
							if vpart then
								aimingAtCar = true
								targetinfo.Targets[ent] = tick() + 1
								return vpart.Position
							end
						end
						-- Aim STRAIGHT at the target part (hitscan = no lead/gravity needed).
						aimingAtCar = false
						targetinfo.Targets[ent] = tick() + 1
						return ent[part].Position
					end
					aimingAtCar = false
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
						-- Normally ignore world geometry so on-foot shots pass through walls.
						-- BUT when we're aiming at a car (in-car target), the bullet must be
						-- able to COLLIDE with the car to damage it -- so don't ignore the
						-- world in that case.
						item.BulletEmitter.IgnoreList = aimingAtCar and {} or {workspace}
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

				-- AUTO SHOOT: while a valid target sits in Range, hold the trigger for
				-- you (no clicking). Self-terminates when the Aimbot is disabled.
				task.spawn(function()
					repeat
						if AutoShoot and AutoShoot.Enabled then
							local item = jb.ItemSystemController:GetLocalEquipped()
							-- only real guns have a BulletEmitter (taser/handcuffs excluded)
							if item and item.BulletEmitter and autoShootTarget() then
								pressTrigger(item)
							else
								releaseTrigger()
							end
						else
							releaseTrigger()
						end
						task.wait()
					until not Aimbot.Enabled
					releaseTrigger()
				end)
			else
				aimingAtCar = false
				releaseTrigger()
				for cfg, saved in fireAutoSaved do
					pcall(function() cfg.FireAuto = saved end)
				end
				table.clear(fireAutoSaved)
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
	AutoShoot = Aimbot:CreateToggle({
		Name = 'Auto Shoot',
		Tooltip = 'Automatically holds the trigger whenever a valid target is within Range -- you never have to click. Uses the same Target / Aim Part / Priority settings, forces full-auto so semi-autos keep firing, and pairs with the aimbot so every shot lands. Friends and dead targets are skipped.'
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


-- Rapid Fire: makes any semi-auto / burst gun fire continuously with no reload
-- pause -- just hold click. We deliberately do NOT touch FireFreq: the SERVER
-- independently rate-limits via the NextShotPossibleTime attribute on its own
-- clock, so inflating the local fire rate gets every extra shot rejected
-- ("destroyed by server side"). Instead we only flip the two levers the server
-- can't see:
--   * Config.FireAuto = true -> ShootBegin keeps IsShooting=true while held, so
--     the Heartbeat loop fires every time the gun's own cooldown allows. This
--     gives continuous fire at the gun's LEGIT max rate, which the server accepts.
--   * Keep the mag topped + clear IsReloading -> the gun never enters the reload
--     animation (it reloads when AmmoCurrentLocal hits 0), removing the pause
--     between volleys. Reloading is purely a local gate, so this is server-safe.
run(function()
	local RapidFire
	local cfgOriginals = setmetatable({}, {__mode = 'k'}) -- [Config] = original FireAuto

	RapidFire = vain.Categories.Combat:CreateModule({
		Name = 'Rapid Fire',
		Function = function(callback)
			if callback then
				repeat
					local item = jb.ItemSystemController:GetLocalEquipped()
					local cfg = item and item.Config
					if cfg then
						if cfgOriginals[cfg] == nil then
							cfgOriginals[cfg] = {FireAuto = cfg.FireAuto}
						end
						-- full-auto: holding click keeps firing (at the gun's native rate)
						cfg.FireAuto = true
						-- never reload: keep the mag full and cancel any reload in progress
						local iiv = item.inventoryItemValue
						local mag = type(cfg.MagSize) == 'number' and cfg.MagSize or nil
						if iiv and mag then
							pcall(function()
								iiv:SetAttribute('AmmoCurrent', mag)
								iiv:SetAttribute('AmmoCurrentLocal', mag)
								if iiv:GetAttribute('IsReloading') then
									iiv:SetAttribute('IsReloading', false)
								end
							end)
						end
						if item.IsReloading then
							pcall(function() item.IsReloading = false end)
						end
					end
					task.wait()
				until not RapidFire.Enabled
			else
				for cfg, saved in cfgOriginals do
					pcall(function() cfg.FireAuto = saved.FireAuto end)
				end
				table.clear(cfgOriginals)
			end
		end,
		Tooltip = 'Hold click to fire any semi-auto / burst gun (Plasma Shotgun, Revolver, Sniper...) continuously with no reload pause. Fires at the native max rate -- the server rate-limits anything faster, so this stays accepted.'
	})
end)

-- Plasma One-Shot: stacks a plasma weapon's per-pellet damage into a single
-- trigger pull. The plasma guns (PlasmaGun/PlasmaPistol/PlasmaShotgun) use a
-- custom ShootOther that loops Config.BulletsPerShot times and, for EACH pellet
-- that raycasts onto a humanoid, independently fires the Damage remote at that
-- humanoid (PlasmaGun.lua ShootOther L142-174). The server applies damage per
-- remote call, so N pellets landing on one target = N x per-pellet damage. By
-- inflating Config.BulletsPerShot (and zeroing BulletSpread so every pellet
-- goes to the same aimed point) one click lands dozens of damage packets at
-- once -> a one-shot. Pairs naturally with Aimbot (every pellet aimed at the
-- target). Restores BulletsPerShot/BulletSpread on disable.
run(function()
	local PlasmaOneShot
	local Pellets
	local plasmaOriginals = setmetatable({}, {__mode = 'k'}) -- [Config] = {BulletsPerShot=, BulletSpread=}

	local PLASMA = {PlasmaGun = true, PlasmaPistol = true, PlasmaShotgun = true}

	PlasmaOneShot = vain.Categories.Combat:CreateModule({
		Name = 'Plasma One-Shot',
		Function = function(callback)
			if callback then
				repeat
					local item = jb.ItemSystemController:GetLocalEquipped()
					local cfg = item and item.Config
					-- only act on plasma weapons (they use the per-pellet ShootOther path)
					if item and cfg and PLASMA[item.__ClassName] then
						if plasmaOriginals[cfg] == nil then
							plasmaOriginals[cfg] = {
								BulletsPerShot = cfg.BulletsPerShot,
								BulletSpread = cfg.BulletSpread,
							}
						end
						-- every pellet -> its own damage packet on the same target
						cfg.BulletsPerShot = (Pellets and Pellets.Value) or 40
						-- no spread so all pellets converge on the aimed point
						cfg.BulletSpread = 0
					end
					task.wait()
				until not PlasmaOneShot.Enabled
			else
				for cfg, saved in plasmaOriginals do
					pcall(function()
						cfg.BulletsPerShot = saved.BulletsPerShot
						cfg.BulletSpread = saved.BulletSpread
					end)
				end
				table.clear(plasmaOriginals)
			end
		end,
		Tooltip = 'Plasma weapons only. Multiplies the pellets-per-shot so one trigger pull lands many damage packets on the same target -- enough to one-shot. Aim at the target (use Aimbot) and fire once.'
	})
	Pellets = PlasmaOneShot:CreateSlider({
		Name = 'Pellets',
		Min = 4,
		Max = 80,
		Default = 40,
		Tooltip = 'How many damage packets per shot. Higher = more total damage (more reliable one-shot) but more remote spam; too high may be flagged. 40 is plenty.'
	})
end)

run(function()
	local Wallbang = {Enabled = false}
	local WB_HITBOX = 18 -- studs; default RootPart hit radius is 3
	local wbInflated = {} -- [RootPart] = true, radii we enlarged (restore on disable)
	local wbConn -- RenderStepped connection for hitbox inflation

	Wallbang = vain.Categories.Combat:CreateModule({
		Name = 'Wallbang',
		Function = function(callback)
			if callback then
				-- INFLATE TARGET HITBOXES every frame. This is what actually makes
				-- through-wall shots LAND reliably: the BulletEmitter checks a proximity
				-- sphere around each player's RootPart (sized by its 'HitRadius' attr,
				-- default 3) BEFORE the surface raycast, and a hit there ignores walls
				-- entirely. With the default radius of 3 you have to be aiming nearly
				-- dead-on, so most through-wall shots slip past the sphere and then get
				-- swallowed by the {workspace} IgnoreList -> "barely hitting through
				-- walls". A big radius makes any roughly-aimed shot register. (The
				-- Aimbot does the same; Wallbang now does it standalone too.)
				wbConn = runService.RenderStepped:Connect(function()
					for _, e in entitylib.List do
						if e.Targetable and (e.Player or e.NPC) then
							local parts = {e.RootPart}
							local char = e.Character
							local hrp = char and char:FindFirstChild('HumanoidRootPart')
							if hrp then parts[#parts + 1] = hrp end
							for _, part in parts do
								if part then
									wbInflated[part] = true
									part:SetAttribute('HitRadius', WB_HITBOX)
								end
							end
						end
					end
				end)

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
					if item then
						-- Two raycast paths to defeat:
						--  * Regular Gun: each shot raycasts the BulletEmitter, whose
						--    IgnoreList is copied from item.IgnoreList in SetupEmitter
						--    (Gun.lua: u90.BulletEmitter.IgnoreList = assert(u90.IgnoreList)).
						--  * Plasma weapons (PlasmaPistol/PlasmaGun/PlasmaShotgun): they
						--    OVERRIDE Shoot with ShootOther, which never touches the
						--    BulletEmitter -- it raycasts directly against item.IgnoreList
						--    (PlasmaGun.lua ShootOther: FilterDescendantsInstances = IgnoreList).
						-- Setting only BulletEmitter.IgnoreList left plasma bullets blocked
						-- by walls, so we set item.IgnoreList too (covers both paths).
						item.IgnoreList = {workspace}
						if item.BulletEmitter then
							item.BulletEmitter.IgnoreList = {workspace}
						end
					end
					task.wait(0.1)
				until not Wallbang.Enabled
			else
				restorefunction(jb.GunController.BulletEmitterOnLocalHitPlayer)
				if wbConn then wbConn:Disconnect() wbConn = nil end
				for root in wbInflated do
					pcall(function() root:SetAttribute('HitRadius', nil) end)
				end
				table.clear(wbInflated)
			end
		end,
		Tooltip = 'Shoot through most walls + always headshot damage. Inflates target hitboxes so through-wall shots actually land (default aim has to be near-perfect otherwise).'
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
	-- BUILD-PROOF arrest: instead of firing a hardcoded obfuscated alias (which the
	-- game re-randomizes every update), call the game's OWN arrest action. Every
	-- nearby criminal has a CircleAction spec; the arrest spec has spec.ShouldArrest
	-- and a spec:Callback that, when run, executes the real arrest with the correct
	-- alias + server remap. We just invoke that callback -- no alias to maintain.
	-- Falls back to the raw remote only if the spec/callback can't be found.
	local function callSpecArrest(name)
		local specs = jb.CircleAction and jb.CircleAction.Specs
		if type(specs) ~= 'table' then return false end
		for _, spec in specs do
			if spec.PlayerName == name and spec.ShouldArrest and type(spec.Callback) == 'function' then
				local ok = pcall(function() spec:Callback(true) end)
				return ok
			end
		end
		return false
	end

	-- Build-proof eject (same idea): the vehicle CircleAction spec has
	-- spec.ShouldEject and a Callback that fires the real eject (u799 ->
	-- u147(spec.Part.Parent)). Call that callback for the spec whose Part is the
	-- given vehicle. Falls back to the Eject remote alias with the vehicle model.
	local function tryEject(vehicle)
		if not vehicle then return end
		local specs = jb.CircleAction and jb.CircleAction.Specs
		if type(specs) == 'table' then
			for _, spec in specs do
				if spec.ShouldEject and type(spec.Callback) == 'function'
					and spec.Part and spec.Part:IsDescendantOf(vehicle) then
					if pcall(function() spec:Callback(true) end) then return end
				end
			end
		end
		-- fallback: the game ejects with spec.Part.Parent (the vehicle model)
		jb:FireServer('Eject', vehicle)
	end

	local function tryArrest(plr)
		if not plr then return end
		local last = arrestDebounce[plr]
		-- small per-target debounce only (avoid hammering the SAME target every
		-- frame while the server processes it); a new target in range is arrested
		-- immediately on the very next frame.
		if not last or tick() - last > 0.25 then
			arrestDebounce[plr] = tick()
			-- Fire the alias immediately so a target that just entered range is
			-- arrested without waiting for the game's spec to update. ALSO call the
			-- game's own spec callback when it's ready (alias-proof) -- whichever
			-- lands first wins; the server ignores the duplicate.
			if not callSpecArrest(plr.Name) then
				jb:FireServer('Arrest', plr)
			end
		end
	end

	-- AutoArrest only acts while YOU have Handcuffs equipped -- it never forces
	-- them out or switches your item. The moment cuffs are out it scans for
	-- nearby criminals and arrests any in range (ejecting them from cars first).
	local function cuffsEquipped()
		local eq = jb.ItemSystemController:GetLocalEquipped()
		return eq and eq.__ClassName == 'Handcuffs' or false
	end

	AutoArrest = vain.Categories.Blatant:CreateModule({
		Name = 'AutoArrest',
		Function = function(callback)
			if callback then
				-- The game's ShouldArrest test (decoded from u756/u803): target is a
				-- Prisoner with a Humanoid, NOT already handcuffed, NOT in a vehicle.
				-- We do NOT auto-equip -- you control when by holding the handcuffs;
				-- whenever they're out, in-range criminals are arrested automatically.
				repeat
					if entitylib.isAlive and teamOf(lplr) == 'Police' and cuffsEquipped() then
						local char = entitylib.character
						local root = char and char.RootPart
						local myPos = root and root.Position
						local range = (ArrestRange and ArrestRange.Value) or 18.4
						if myPos then
							for _, ent in entitylib.AllPosition({ Players = true, Part = 'RootPart', Range = math.max(60, range + 10) }) do
								if not AutoArrest.Enabled then break end
								local plr = ent.Player
								local tchar = plr and plr.Character
								if plr and tchar and ent.RootPart and ent.Humanoid and teamOf(plr) == 'Prisoner'
									and not tchar:GetAttribute('HasHandcuffs') then
									local vehicle = (ent.Humanoid.Sit or tchar:GetAttribute('InVehicle')) and getVehicle(ent) or nil
									if vehicle then
										tryEject(vehicle)
									elseif (myPos - ent.RootPart.Position).Magnitude <= range then
										tryArrest(plr)
									end
								end
							end
						end
					end
					-- run every frame so a criminal entering range is caught instantly
					-- (the per-target debounce in tryArrest prevents server spam)
					task.wait()
				until not AutoArrest.Enabled
				table.clear(arrestDebounce)
			end
		end,
		Tooltip = 'While you have Handcuffs equipped, instantly arrests any criminal that comes within range. Ejects criminals from vehicles first. Does not auto-equip -- you decide when by holding the cuffs.'
	})
	InstaArrest = AutoArrest:CreateToggle({
		Name = 'Insta Arrest',
		Default = true,
		Tooltip = 'Arrest the moment a criminal enters range (no cooldown between arrests).'
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
	
	-- BUILD-PROOF AutoTaze: instead of reconstructing the obfuscated Tase remote
	-- (which re-randomizes every update and needs exact hit args), we call the
	-- taser's OWN :Tase() method -- it does the raycast targeting, validation and
	-- fires the correct remote itself. Tase aims toward the taser's MousePosition,
	-- which comes from TransformLocalMousePosition; we hook that to point at the
	-- nearest criminal so :Tase() locks onto them. No alias to maintain.
	AutoTaze = vain.Categories.Blatant:CreateModule({
		Name = 'AutoTaze',
		Function = function(callback)
			if callback then
					-- We redirect the taser's aim by SHADOWING TransformLocalMousePosition on
					-- each equipped taser INSTANCE (the method lives on the Basic base via
					-- metatable; jb.TaserController is the module table and may lack it / be
					-- nil, which is what errored). Cleared on disable.
					local shadowed = setmetatable({}, {__mode = 'k'})
					repeat
						local item = jb.ItemSystemController:GetLocalEquipped()
						item = item and item.__ClassName == 'Taser' and item or nil
						if item then
							if not shadowed[item] then
								shadowed[item] = true
								rawset(item, 'TransformLocalMousePosition', function(self, pos)
									local range = (self.Config and self.Config.Range) or 50
									local ent = entitylib.EntityPosition({ Players = true, Part = 'RootPart', Range = range })
									if ent and ent.RootPart and isValidCriminal(ent) then
										return ent.RootPart.Position
									end
									return pos
								end)
							end
							local nextUse = item.inventoryItemValue and item.inventoryItemValue:GetAttribute('NextUse')
							local ready = not (type(nextUse) == 'number' and os.clock() < (nextUse or 0))
							local range = (item.Config and item.Config.Range) or 50
							local ent = entitylib.EntityPosition({ Players = true, Part = 'RootPart', Range = range })
							if ready and ent and isValidCriminal(ent) then
								local fakeInput = { UserInputType = Enum.UserInputType.MouseButton1, KeyCode = Enum.KeyCode.Unknown }
								pcall(function() item:Tase(fakeInput) end)
							end
						end
						task.wait(0.05)
					until not AutoTaze.Enabled
					for taser in shadowed do
						pcall(function() rawset(taser, 'TransformLocalMousePosition', nil) end)
					end
				end
		end,
		Tooltip = 'Immobilizes nearby criminals by driving the taser\'s own Tase action (aim auto-locked to the nearest criminal). Build-proof -- no obfuscated remote to maintain.'
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

-- ===========================================================================
-- Vehicle exploits. The AlexChassis is CLIENT-SIDE physics: your client computes
-- your own car's drive force / torque each frame from a chassis state object.
-- VehicleUtils.GetLocalVehiclePacket() returns that live state (it exposes
-- .AreTiresPopped, .LaunchSpeedMult, .Traction, .Model, .Make ...), so mutating
-- those fields changes how YOUR car drives, with no remote -- the server doesn't
-- re-derive your physics. (It still validates POSITION, so an absurd speed can
-- get position-rolled; keep the multiplier reasonable.)
-- ===========================================================================
run(function()
	-- live local-vehicle chassis state, or nil if you're not driving
	local function chassis()
		local vc = jb.VehicleController
		if not vc or not vc.GetLocalVehiclePacket then return nil end
		local ok, packet = pcall(vc.GetLocalVehiclePacket)
		if ok and type(packet) == 'table' and not packet.Passenger then
			return packet
		end
		return nil
	end

	-- Vehicle Speed: LaunchSpeedMult multiplies the drive force (the game sets it
	-- to 4 for a split second on launch, then decays it). Pinning it to a chosen
	-- value gives permanent extra acceleration + top speed.
	--
	-- The same multiplier ALSO scales TurnSpeed (when 'Sync Turning' is on) so you
	-- swerve proportionally harder the faster you go -- the chassis damps turning at
	-- high speed (v366 = exp(-speed/400)...), so a 5x car at 500mph normally barely
	-- turns; scaling TurnSpeed by the multiplier cancels that. We capture each car's
	-- BASE TurnSpeed the first time we see it so we multiply, not pin to a constant.
	local VehicleSpeed
	local SpeedMult
	local SyncTurning
	local VelocityBoost
	local BoostSpeed
	local baseTurn = setmetatable({}, {__mode = 'k'}) -- [chassis] = original TurnSpeed
	VehicleSpeed = vain.Categories.Utility:CreateModule({
		Name = 'Vehicle Speed',
		Function = function(callback)
			if callback then
				task.spawn(function()
					repeat
						local c = chassis()
						if c then
							local mult = (SpeedMult and SpeedMult.Value) or 2
							c.LaunchSpeedMult = mult
							if (not SyncTurning or SyncTurning.Enabled) and type(c.TurnSpeed) == 'number' then
								if baseTurn[c] == nil then baseTurn[c] = c.TurnSpeed end
								c.TurnSpeed = baseTurn[c] * mult
							end
							-- VELOCITY BOOST: re-drive the car along its current HORIZONTAL
							-- heading at the chosen speed and clamp the upward component, so the
							-- energy goes into moving FORWARD instead of bouncing up and down.
							-- Direction comes from the car's own motion, so steering / reverse
							-- still work; we only touch magnitude + kill the vertical launch.
							if VelocityBoost and VelocityBoost.Enabled then
								local model = c.Model
								local part = model and (model.PrimaryPart or model:FindFirstChildWhichIsA('BasePart', true))
								if part then
									local v = part.AssemblyLinearVelocity
									local horiz = Vector3.new(v.X, 0, v.Z)
									if horiz.Magnitude > 2 then -- only while actually driving
										local nh = horiz.Unit * ((BoostSpeed and BoostSpeed.Value) or 200)
										part.AssemblyLinearVelocity = Vector3.new(nh.X, math.min(v.Y, 5), nh.Z)
									end
								end
							end
						end
						task.wait()
					until not VehicleSpeed.Enabled
					-- restore: let speed decay naturally, put turn speed back to stock
					local c = chassis()
					if c then
						c.LaunchSpeedMult = nil
						if baseTurn[c] then c.TurnSpeed = baseTurn[c] end
					end
				end)
			end
		end,
		Tooltip = 'Permanent speed/acceleration boost for your car by pinning the chassis LaunchSpeedMult. With Sync Turning on, the same multiplier sharpens your steering so a fast car still swerves. Client physics only -- keep it modest, the server checks POSITION so extreme values can get you rolled back.'
	})
	SpeedMult = VehicleSpeed:CreateSlider({
		Name = 'Multiplier',
		Min = 1,
		Max = 10,
		Default = 2,
		Decimal = 10,
		Suffix = 'x',
		Tooltip = 'Drive-force multiplier (also scales turning when Sync Turning is on). 2-3x is usually safe; higher may trip the position anticheat.'
	})
	SyncTurning = VehicleSpeed:CreateToggle({
		Name = 'Sync Turning',
		Default = true,
		Tooltip = 'Scale your steering by the same multiplier so you can still swerve sharply at high speed (cancels the game\'s high-speed turn damping).'
	})
	VelocityBoost = VehicleSpeed:CreateToggle({
		Name = 'Velocity Boost',
		Tooltip = 'Fixes a car that only bounces up and down instead of going fast: pushes you along your HORIZONTAL heading at the Boost Speed and cancels upward launch, so all the power goes into forward speed. Holds the set speed while on (toggle off to brake normally). Direction follows your steering.'
	})
	BoostSpeed = VehicleSpeed:CreateSlider({
		Name = 'Boost Speed',
		Min = 50,
		Max = 1000,
		Default = 200,
		Suffix = 'studs/s',
		Tooltip = 'Target horizontal speed while Velocity Boost is on. Higher = faster, but the server validates POSITION -- very high values can get you rolled back.'
	})
end)

run(function()
	-- Ignore Popped Tires: AreTiresPopped is recomputed from tire health every
	-- frame and, when true, spins you out / kills your speed. Force it false so
	-- flat tires never affect how your car drives.
	local function chassis()
		local vc = jb.VehicleController
		if not vc or not vc.GetLocalVehiclePacket then return nil end
		local ok, packet = pcall(vc.GetLocalVehiclePacket)
		if ok and type(packet) == 'table' and not packet.Passenger then return packet end
		return nil
	end
	local IgnorePopped
	IgnorePopped = vain.Categories.Utility:CreateModule({
		Name = 'Ignore Popped Tires',
		Function = function(callback)
			if callback then
				task.spawn(function()
					repeat
						local c = chassis()
						if c then
							c.AreTiresPopped = false
							c._spinOutLeft = nil
							c._spinOutAt = nil
						end
						task.wait()
					until not IgnorePopped.Enabled
				end)
			end
		end,
		Tooltip = 'Drive normally even with popped tires -- forces the chassis AreTiresPopped flag off each frame so you never spin out or slow down. Client physics only.'
	})
end)

run(function()
	-- Perfect Traction / No Flip: pin Traction high (no skidding) and keep the car
	-- upright by clearing the upside-down timer the chassis uses before it flips.
	local function chassis()
		local vc = jb.VehicleController
		if not vc or not vc.GetLocalVehiclePacket then return nil end
		local ok, packet = pcall(vc.GetLocalVehiclePacket)
		if ok and type(packet) == 'table' and not packet.Passenger then return packet end
		return nil
	end
	local Traction
	Traction = vain.Categories.Utility:CreateModule({
		Name = 'Vehicle Traction',
		Function = function(callback)
			if callback then
				task.spawn(function()
					repeat
						local c = chassis()
						if c then
							c.Traction = 1
							c.UpsideDownTime = nil -- never reach the auto-flip threshold
						end
						task.wait()
					until not Traction.Enabled
				end)
			end
		end,
		Tooltip = 'Maximum grip (no skidding/drifting away) and prevents your car from flipping. Pins the chassis Traction and clears its upside-down timer. Client physics only.'
	})
end)

run(function()
	-- Instant Tire Repair: keep every tire on your car topped up to its max health
	-- (VehicleTireHealth attribute) so they can never be popped.
	local IronTires
	IronTires = vain.Categories.Utility:CreateModule({
		Name = 'Iron Tires',
		Function = function(callback)
			if callback then
				task.spawn(function()
					local vc = jb.VehicleController
					repeat
						local ok, packet = pcall(vc.GetLocalVehiclePacket)
						local model = ok and type(packet) == 'table' and packet.Model
						if model and not packet.Passenger then
							for _, part in model:GetDescendants() do
								if part:IsA('BasePart') and part:GetAttribute('VehicleTireHealth') ~= nil then
									local maxh = part:GetAttribute('MaxVehicleTireHealth') or 100
									if part:GetAttribute('VehicleTireHealth') < maxh then
										pcall(function()
											if vc.setTireHealth then vc.setTireHealth(part, maxh) else part:SetAttribute('VehicleTireHealth', maxh) end
										end)
									end
								end
							end
						end
						task.wait(0.2)
					until not IronTires.Enabled
				end)
			end
		end,
		Tooltip = 'Keeps your tires repaired to full health so they can never stay popped (refills the VehicleTireHealth attribute). Pair with Ignore Popped Tires.'
	})
end)

run(function()
	-- Vehicle Fly: WASD + E/Q (up/down), camera-relative. Two modes:
	--   Velocity (default, lower risk) - drive the car's AssemblyLinearVelocity each
	--     frame; movement stays continuous so the position anticheat rarely rolls it.
	--   CFrame (higher risk) - anchor the assembly and step its CFrame; snappier but
	--     jumps position, so the anticheat may roll you back.
	local VehicleFly
	local FlySpeed
	local flyConn
	local flyVelConn
	local anchored = {} -- [part] = previous Anchored state, to restore
	local flyDriveSaved = setmetatable({}, {__mode = 'k'}) -- [chassis] = original LaunchSpeedMult
	local flyTractionSaved = setmetatable({}, {__mode = 'k'}) -- [chassis] = original Traction

	local function chassis()
		local vc = jb.VehicleController
		if not vc or not vc.GetLocalVehiclePacket then return nil end
		local ok, packet = pcall(vc.GetLocalVehiclePacket)
		if ok and type(packet) == 'table' and not packet.Passenger then return packet end
		return nil
	end

	-- WASD + E/Q -> a camera-relative movement direction. We use E (up) and Q
	-- (down) for vertical because Space is bound to the car's jump/exit-vehicle
	-- action -- pressing Space for "up" would eject you from the car instead.
	local function inputDir()
		local d = Vector3.zero
		local cf = gameCamera.CFrame
		if inputService:IsKeyDown(Enum.KeyCode.W) then d += cf.LookVector end
		if inputService:IsKeyDown(Enum.KeyCode.S) then d -= cf.LookVector end
		if inputService:IsKeyDown(Enum.KeyCode.A) then d -= cf.RightVector end
		if inputService:IsKeyDown(Enum.KeyCode.D) then d += cf.RightVector end
		if inputService:IsKeyDown(Enum.KeyCode.E) then d += Vector3.yAxis end
		if inputService:IsKeyDown(Enum.KeyCode.Q) then d -= Vector3.yAxis end
		return d.Magnitude > 0 and d.Unit or Vector3.zero
	end

	local FlyMode

	local function stopFly()
		if flyConn then flyConn:Disconnect() flyConn = nil end
		if flyVelConn then flyVelConn:Disconnect() flyVelConn = nil end

		-- COMMIT THE POSITION before we let go. CFrame fly teleports the car via
		-- PivotTo while anchored; the server's position anticheat never trusts those
		-- jumps, so the moment you exit it rolls your CHARACTER back to the last spot
		-- it believed (HumanoidUnloadServerPosition). The car being anchored is the
		-- problem: an anchored assembly reports no physics, so the server keeps its
		-- old trusted position. Fix: un-anchor and hold the car at its CURRENT pivot
		-- with real (zero) velocity for a short window, so the AlexChassis reports
		-- the new resting position to the server continuously -- the server adopts it
		-- as legitimate, and exiting no longer rolls you back.
		local hadAnchored = next(anchored) ~= nil
		for part, was in anchored do
			pcall(function() part.Anchored = was end)
		end
		table.clear(anchored)

		if hadAnchored then
			local c = chassis()
			local model = c and c.Model
			local engine = model and model:FindFirstChild('Engine')
			if engine then
				local pivot = model:GetPivot()
				-- pin the car in place (kill all motion) for ~0.4s of physics so the
				-- server registers the new position as a stable, driven-to location.
				task.spawn(function()
					local t0 = os.clock()
					while os.clock() - t0 < 0.4 do
						pcall(function()
							model:PivotTo(pivot)
							engine.AssemblyLinearVelocity = Vector3.zero
							engine.AssemblyAngularVelocity = Vector3.zero
						end)
						runService.Heartbeat:Wait()
					end
				end)
			end
		end

		-- restore any chassis drive / traction we neutralized for velocity fly
		for c, was in flyDriveSaved do
			pcall(function() c.LaunchSpeedMult = was end)
		end
		table.clear(flyDriveSaved)
		for c, was in flyTractionSaved do
			pcall(function() c.Traction = was end)
		end
		table.clear(flyTractionSaved)
	end

	-- CFrame fly: anchor the assembly and step the model's CFrame. Snappy but
	-- jumps position -> higher chance the position anticheat rolls you back.
	local function flyCFrame(dt)
		local c = chassis()
		local model = c and c.Model
		local engine = model and model:FindFirstChild('Engine')
		if not engine then return end
		for _, p in model:GetDescendants() do
			if p:IsA('BasePart') and anchored[p] == nil then
				anchored[p] = p.Anchored
				p.Anchored = true
			end
		end
		local speed = (FlySpeed and FlySpeed.Value) or 120
		local dir = inputDir()
		-- TRANSLATE only -- keep the car's current orientation. Re-facing the car to
		-- the camera every frame fought your strafe input (sideways felt slow/weak);
		-- now A/D move you sideways at full speed just like W/E/Q.
		local current = model:GetPivot()
		model:PivotTo(current + dir * speed * dt)
	end

	-- Velocity fly: DON'T anchor -- drive the assembly's velocity toward the input
	-- each frame (gravity cancelled). Movement stays continuous, so the position
	-- anticheat is far less likely to roll you back. Lower risk.
	local function flyVelocity()
		-- ensure nothing is left anchored from a previous CFrame run
		if next(anchored) then
			for part, was in anchored do pcall(function() part.Anchored = was end) end
			table.clear(anchored)
		end
		local c = chassis()
		local model = c and c.Model
		local engine = model and model:FindFirstChild('Engine')
		if not engine then return end
		-- Neutralize the chassis DRIVE FORCE while flying. Without this, the
		-- AlexChassis keeps applying its horizontal wheel/drive force every physics
		-- step, which fights (damps) the horizontal velocity we set -- while the
		-- vertical (E/Q) axis has no such counter-force, so up/down felt much faster
		-- than WASD. Zeroing LaunchSpeedMult removes the drive force so ALL axes hit
		-- the full fly speed equally. Restored in stopFly.
		if type(c.LaunchSpeedMult) == 'number' then
			if flyDriveSaved[c] == nil then flyDriveSaved[c] = c.LaunchSpeedMult end
			c.LaunchSpeedMult = 0
		end
		-- Also drop ground friction. Near the ground the wheels grip and the chassis
		-- bleeds horizontal velocity (vertical lifts you off, so it's unaffected --
		-- the other reason sideways felt slow). Zeroing Traction removes that drag;
		-- skidding is irrelevant because we hard-set the velocity every Heartbeat.
		if type(c.Traction) == 'number' then
			if flyTractionSaved[c] == nil then flyTractionSaved[c] = c.Traction end
			c.Traction = 0
		end
		local speed = (FlySpeed and FlySpeed.Value) or 120
		local dir = inputDir()
		-- set the whole assembly's velocity; if no input, hover (zero velocity) so
		-- gravity doesn't pull the car down. Also kill spin so the car doesn't
		-- tumble (angular velocity is otherwise untouched by the drive removal).
		engine.AssemblyLinearVelocity = dir * speed
		engine.AssemblyAngularVelocity = Vector3.zero
	end

	VehicleFly = vain.Categories.Utility:CreateModule({
		Name = 'Vehicle Fly',
		Function = function(callback)
			if callback then
				-- CFrame mode anchors + PivotTo, so it runs on RenderStepped (timing
				-- vs physics doesn't matter when anchored). Velocity mode must run on
				-- HEARTBEAT (which fires AFTER the AlexChassis physics step) -- if we
				-- set AssemblyLinearVelocity on RenderStepped (before physics), the
				-- chassis's wheel friction/drive step runs afterward and DAMPS our
				-- horizontal velocity, while the airborne vertical axis is untouched ->
				-- horizontal felt extremely slow. Setting it on Heartbeat makes our
				-- velocity the last word each frame, so all axes hit full speed.
				flyConn = runService.RenderStepped:Connect(function(dt)
					if (FlyMode and FlyMode.Value) == 'CFrame' then
						flyCFrame(dt)
					end
				end)
				flyVelConn = runService.Heartbeat:Connect(function()
					if (FlyMode and FlyMode.Value) ~= 'CFrame' then
						flyVelocity()
					end
				end)
			else
				stopFly()
			end
		end,
		Tooltip = 'Fly your car with WASD + E (up) / Q (down), camera-relative. (Space is the car jump/exit, so E/Q are used instead.) Velocity mode is smooth and lower-risk; CFrame is snappier but jumps position so the anticheat may roll you back. Use lower speeds.'
	})
	FlyMode = VehicleFly:CreateDropdown({
		Name = 'Mode',
		List = { 'Velocity', 'CFrame' },
		Tooltip = 'Velocity - smooth, continuous movement (lowest risk of position rollback)\nCFrame - instant/snappy control. On disable it now holds the car in place briefly so the server adopts your new position, so exiting no longer teleports you back. For best results: stop flying (toggle off / land) BEFORE you press Space to get out.'
	})
	FlySpeed = VehicleFly:CreateSlider({
		Name = 'Fly Speed',
		Min = 20,
		Max = 2000,
		Default = 250,
		Suffix = function(val) return val == 1 and 'stud/s' or 'studs/s' end,
		Tooltip = 'How fast the car flies. Lower is less likely to trip the position anticheat; very high values will likely get rolled back.'
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

-- ══════════════════════════════════════════════════════════════════════════════
--  AUTO ARREST BOT: fly your police car to the highest-bounty criminal, get out,
--  and arrest them -- all build-proof (no obfuscated remote ids needed). Set up
--  once: join Police, spawn a car, get in, and hold Handcuffs; it does the hunt.
-- ══════════════════════════════════════════════════════════════════════════════
run(function()
	local Bot
	local MinBounty, FlySpeed, ExitDist, CruiseHeight, Notify
	local httpService = cloneref(game:GetService('HttpService'))

	local function teamOf(plr)
		local tv = plr and plr:FindFirstChild('TeamValue')
		return (tv and tv.Value) or (plr and plr.Team and plr.Team.Name) or nil
	end

	-- bounties live in ReplicatedStorage.Bounty.BountyBoardService.Bounties (or the
	-- BountyData JSON), each entry { UserId, Bounty }
	local function bountyEntries()
		local ok, svc = pcall(function() return require(replicatedStorage.Bounty.BountyBoardService) end)
		if ok and type(svc) == 'table' and type(svc.Bounties) == 'table' then return svc.Bounties end
		local data = replicatedStorage:FindFirstChild('BountyData')
		if data then
			local good, dec = pcall(function() return httpService:JSONDecode(data.Value) end)
			if good and type(dec) == 'table' then return dec end
		end
		return {}
	end

	-- highest-bounty criminal at/above the threshold, alive, out of jail, not cuffed
	local function bestTarget()
		local min = (MinBounty and MinBounty.Value) or 0
		local best, bestB
		for _, e in bountyEntries() do
			if type(e) == 'table' and e.UserId and (e.Bounty or 0) >= min then
				local plr = playersService:GetPlayerByUserId(e.UserId)
				local char = plr and plr ~= lplr and plr.Character
				local hum = char and char:FindFirstChildOfClass('Humanoid')
				local hrp = char and char:FindFirstChild('HumanoidRootPart')
				local tm = plr and teamOf(plr)
				if hrp and hum and hum.Health > 0 and (tm == 'Prisoner' or tm == 'Criminal')
					and not char:GetAttribute('HasHandcuffs') then
					if not bestB or e.Bounty > bestB then best, bestB = plr, e.Bounty end
				end
			end
		end
		return best, bestB
	end

	-- local car chassis packet (nil unless you're the driver)
	local function chassis()
		local vc = jb.VehicleController
		if not vc or not vc.GetLocalVehiclePacket then return nil end
		local ok, packet = pcall(vc.GetLocalVehiclePacket)
		if ok and type(packet) == 'table' and not packet.Passenger then return packet end
		return nil
	end

	-- velocity-fly the car toward a world point (drive/traction neutralised so the
	-- chassis doesn't fight us -- same approach as the Vehicle Fly module)
	local driveSaved = setmetatable({}, {__mode = 'k'})
	local tractionSaved = setmetatable({}, {__mode = 'k'})
	local function flyToward(point, speed)
		local c = chassis()
		local model = c and c.Model
		local engine = model and (model:FindFirstChild('Engine') or model.PrimaryPart
			or model:FindFirstChildWhichIsA('BasePart', true))
		if not engine then return false end
		if type(c.LaunchSpeedMult) == 'number' then
			if driveSaved[c] == nil then driveSaved[c] = c.LaunchSpeedMult end
			c.LaunchSpeedMult = 0
		end
		if type(c.Traction) == 'number' then
			if tractionSaved[c] == nil then tractionSaved[c] = c.Traction end
			c.Traction = 0
		end
		local here = model:GetPivot().Position
		local off = point - here
		local d = off.Magnitude
		local dir = d > 0.5 and off.Unit or Vector3.zero
		-- ease off within ~speed/8 studs so we settle on the waypoint instead of
		-- overshooting it and oscillating
		engine.AssemblyLinearVelocity = dir * math.min(speed, d * 8)
		engine.AssemblyAngularVelocity = Vector3.zero
		return true
	end

	-- pick the next waypoint for a flight that goes OVER buildings instead of
	-- through them: climb to a cruise altitude, cruise across at height, and once
	-- roughly above the target drop STRAIGHT down onto it. Dropping vertically
	-- (rather than chasing a horizontal point) is what stops the car oscillating
	-- back and forth. Returns (point, phase, gentle, horiz); phase 'arrived' means
	-- we're on the target -- get out and arrest.
	local function flyPlan(targetPos, exitAt)
		local c = chassis()
		local model = c and c.Model
		if not model then return nil, nil end
		local here = model:GetPivot().Position
		if (here - targetPos).Magnitude <= exitAt then return nil, 'arrived', false, 0 end
		local horiz = Vector3.new(targetPos.X - here.X, 0, targetPos.Z - here.Z).Magnitude
		local cruiseY = targetPos.Y + ((CruiseHeight and CruiseHeight.Value) or 150)
		if horiz <= 55 then
			-- roughly above the target -> drop straight down onto it (mostly
			-- vertical, so the car can't oscillate back and forth horizontally)
			return Vector3.new(targetPos.X, targetPos.Y + 6, targetPos.Z), 'descending', false, horiz
		elseif here.Y < cruiseY - 15 then
			-- climb to clear the rooftops -- gently
			return Vector3.new(here.X, cruiseY, here.Z), 'climbing', true, horiz
		else
			-- cruise horizontally over the target
			return Vector3.new(targetPos.X, cruiseY, targetPos.Z), 'cruising', false, horiz
		end
	end
	local function restoreCar()
		for c, was in driveSaved do pcall(function() c.LaunchSpeedMult = was end) end
		for c, was in tractionSaved do pcall(function() c.Traction = was end) end
		table.clear(driveSaved); table.clear(tractionSaved)
	end

	-- build-proof: invoke the game's OWN arrest / eject CircleAction callbacks
	local function callArrest(name)
		local specs = jb.CircleAction and jb.CircleAction.Specs
		if type(specs) ~= 'table' then return false end
		for _, spec in specs do
			if spec.PlayerName == name and spec.ShouldArrest and type(spec.Callback) == 'function' then
				return (pcall(function() spec:Callback(true) end))
			end
		end
		return false
	end
	local function exitCar()
		-- get OUT of our OWN car. (Note: the CircleAction ShouldEject specs eject
		-- OTHER players from their vehicles -- using them here can boot the criminal
		-- instead of us.) The game maps a jump to the get-out action (OnJump ->
		-- GetOut), so the build-proof exit is to make our own character jump/unseat;
		-- the exit remotes are fired as backups in case OnJump isn't state-bound.
		local char = lplr.Character
		local hum = char and char:FindFirstChildOfClass('Humanoid')
		if hum then
			pcall(function() hum.Sit = false end)
			pcall(function() hum.Jump = true end)
			pcall(function() hum:ChangeState(Enum.HumanoidStateType.Jumping) end)
		end
		pcall(function() jb:FireServer('GetOut') end)
		local c = chassis()
		if c and c.Model then pcall(function() jb:FireServer('Eject', c.Model) end) end
	end
	local function cuffsOut()
		local eq = jb.ItemSystemController:GetLocalEquipped()
		return (eq and eq.__ClassName == 'Handcuffs') or false
	end

	local notified = {}
	local function once(key, ...)
		if Notify and Notify.Enabled and not notified[key] then
			notified[key] = true
			notif('Auto Arrest Bot', ...)
		end
	end
	local lastStatus = 0
	local function status(msg)
		if Notify and Notify.Enabled and tick() - lastStatus > 1.5 then
			lastStatus = tick()
			notif('Auto Arrest Bot', msg, 2)
		end
	end

	Bot = vain.Categories.Blatant:CreateModule({
		Name = 'Auto Arrest Bot',
		Function = function(callback)
			if callback then
				table.clear(notified)
				-- Vehicle Fly forces the car's velocity from WASD (zero when you're not
				-- pressing keys), which overrides our flying -- turn it off if it's on.
				do
					local vf = vain.Modules and vain.Modules['Vehicle Fly']
					if vf and vf.Enabled then
						pcall(function() vf:Toggle() end)
						notif('Auto Arrest Bot', 'Turned off Vehicle Fly (it was overriding my flying).', 5)
					end
				end
				-- one-time diagnostic: confirm we can read the bounty board and how
				-- many of those bounties are criminals actually in this server
				do
					local entries = bountyEntries()
					local inServer, crims = 0, 0
					for _, e in entries do
						if type(e) == 'table' and e.UserId then
							local plr = playersService:GetPlayerByUserId(e.UserId)
							if plr then
								inServer += 1
								local tm = teamOf(plr)
								if tm == 'Prisoner' or tm == 'Criminal' then crims += 1 end
							end
						end
					end
					notif('Auto Arrest Bot', string.format('bounties: %d | criminals: %d | you: %s | in car: %s',
						#entries, crims, tostring(teamOf(lplr)), chassis() and 'yes' or 'no'), 8,
						(#entries > 0) and nil or 'warning')
				end
				task.spawn(function()
					-- when the car first got near (above) the target, so we can bail out
					-- even if the anti-cheat jitter stops it closing the last few studs
					local nearSince
					repeat
						if not entitylib.isAlive then
							-- wait for respawn
						elseif teamOf(lplr) ~= 'Police' then
							once('team', 'Join the Police team first (spawn a car + hold Handcuffs).', 6, 'alert')
						else
							notified.team = nil
							local target = bestTarget()
							if not target then
								once('none', 'No bounty target >= your minimum here. (Server-hop is coming next.)', 6)
							else
								notified.none = nil
								local tchar = target.Character
								local thrp = tchar and tchar:FindFirstChild('HumanoidRootPart')
								local myHrp = entitylib.character and entitylib.character.RootPart
								if thrp and myHrp then
									local exitAt = (ExitDist and ExitDist.Value) or 25
									local dist = (myHrp.Position - thrp.Position).Magnitude
									if chassis() then
										local point, phase, gentle, horiz = flyPlan(thrp.Position, exitAt)
										-- stall backstop: once we've hovered near (above) the target
										-- for a bit without closing the last studs (anti-cheat jitter
										-- on the car's altitude), bail out anyway -- the on-foot
										-- teleport finishes it
										if horiz and horiz <= 80 then
											nearSince = nearSince or tick()
										elseif not horiz or horiz > 150 then
											nearSince = nil
										end
										local stalled = nearSince and (tick() - nearSince > 2.5)
										if phase == 'arrived' or stalled then
											status(string.format(stalled and 'over %s, close enough -- bailing out'
												or 'above %s -- bailing out', target.Name))
											restoreCar()
											exitCar() -- eject; gravity + on-foot TP finish the drop
											nearSince = nil
											task.wait(0.4)
										elseif point then
											local sp = (FlySpeed and FlySpeed.Value) or 300
											if gentle then sp = math.min(sp, 110) end -- gentle climb vs anti-cheat
											if flyToward(point, sp) then
												status(string.format('%s %s (%.0f studs)', phase, target.Name, dist))
											else
												status('in a car but found no part to move it by')
											end
										end
									elseif cuffsOut() then
										nearSince = nil -- out of the car now
										status(string.format('on foot, snapping to %s', target.Name))
										myHrp.CFrame = thrp.CFrame * CFrame.new(0, 0, 2.5)
										callArrest(target.Name)
									else
										once('cuffs', 'Get in a police car, or equip Handcuffs to arrest on foot.', 5, 'alert')
									end
									if cuffsOut() then notified.cuffs = nil end
								end
							end
						end
						runService.Heartbeat:Wait()
					until not Bot.Enabled
					restoreCar()
				end)
			else
				restoreCar()
			end
		end,
		Tooltip = 'Police bounty-hunter: flies your car to the highest-bounty criminal, gets out, and arrests them -- build-proof (no obfuscated remotes). Set up once: join Police, spawn a car, get in, hold Handcuffs. Server-hop on empty servers + auto-join/spawn come next.'
	})

	MinBounty = Bot:CreateSlider({ Name = 'Min Bounty', Min = 0, Max = 50000, Default = 2000, Suffix = '$',
		Tooltip = 'Only chase criminals with at least this much bounty.' })
	FlySpeed = Bot:CreateSlider({ Name = 'Fly Speed', Min = 50, Max = 1000, Default = 300,
		Suffix = function(v) return v == 1 and 'stud/s' or 'studs/s' end,
		Tooltip = 'How fast the car flies to the target. Lower is safer vs the position anticheat.' })
	ExitDist = Bot:CreateSlider({ Name = 'Exit Distance', Min = 8, Max = 80, Default = 25, Suffix = 'studs',
		Tooltip = 'How close (horizontally) the car gets above the target before you bail out and drop on foot.' })
	CruiseHeight = Bot:CreateSlider({ Name = 'Cruise Height', Min = 50, Max = 600, Default = 150, Suffix = 'studs',
		Tooltip = 'How high the car climbs to clear buildings. LOWER it if climbing gets reset by the anti-cheat; raise it if you clip tall towers.' })
	Notify = Bot:CreateToggle({ Name = 'Notify', Default = true,
		Tooltip = 'Status messages (join police / equip cuffs / no targets).' })
end)
	