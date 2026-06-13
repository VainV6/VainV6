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
	for i, v in jb.CircleAction.Specs do
		if v.Name == 'Arrest' and v.PlayerName == name then
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

	function jb:FireServer(id, ...)
		if not remotes[id] then
			notif('Vain', 'Failed to find remote ('..id..')', 10, 'alert')
			return
		end
		return hook(remotetable, remotes[id], ...)
	end

	local arrests = sessioninfo:AddItem('Arrested')
	local moneymade = sessioninfo:AddItem('Money Made', 0, toMoney, true)
	local bounty = sessioninfo:AddItem('Bounty List', '', function()
		local text, tab = '', workspace.MostWanted:FindFirstChild('Board', true)
		tab = tab and tab:GetChildren() or {}

		for i, v in tab do
			if v:IsA('Frame') then
				local plrname = v:FindFirstChild('PlayerName', true)
				local bounty = v:FindFirstChild('Bounty', true)
				if plrname and bounty then
					text = text..'\n'..(plrname.Text..': '..bounty.Text:gsub(' Bounty', ''))
				end
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

for _, v in {'Reach', 'TriggerBot', 'Disabler', 'AntiFall', 'HitBoxes', 'Killaura', 'MurderMystery'} do
	vain:Remove(v)
end
run(function()
	local SilentAim
	local Target
	local Mode
	local Range
	local HitChance
	local HeadshotChance
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
	
				repeat
					if CircleObject then 
						CircleObject.Position = inputService:GetMouseLocation() 
					end
	
					if Instant.Enabled then 
						local item = jb.ItemSystemController:GetLocalEquipped()
						if item and item.BulletEmitter then
							-- Hitscan: BulletEmitter advances a bullet by (now - LastUpdate); pushing
								-- LastUpdate back almost a full LifeSpan makes the next step move the
								-- bullet its ENTIRE travel distance in one frame, so it arrives
								-- instantly instead of flying at BulletSpeed. The tiny epsilon keeps
								-- it from being culled as expired before the hit registers.
								rawset(item.BulletEmitter, 'LastUpdate', tick() - (item.BulletEmitter.LifeSpan - 0.001))
						end
					end
					task.wait()
				until not SilentAim.Enabled
			else
				jb.GunController.TransformLocalMousePosition = Hooked
			end
		end,
		Tooltip = 'Silently adjusts your aim towards the enemy'
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
	
run(function()
	local Wallbang = {Enabled = false}
	
	Wallbang = vain.Categories.Combat:CreateModule({
		Name = 'Wallbang',
		Function = function(callback)
			if callback then
				local hook
				hook = hookfunction(jb.GunController.BulletEmitterOnLocalHitPlayer, function(...)
					local shotData = select(15, ...)
					shotData.isWallbang = nil
					shotData.isHeadshot = true
					return hook(...)
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
					task.wait(0.1)
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
		Tooltip = 'Removes bullet spread AND the camera shake on your equipped gun for pinpoint, jolt-free shots. Client-side gun config only (no movement), so the anticheat does not flag it.'
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

	-- Parse the Most Wanted board into a name -> bounty-number map.
	local function readBoard()
		local map = {}
		local board = workspace:FindFirstChild('MostWanted')
		board = board and board:FindFirstChild('Board', true)
		if not board then return map end
		for _, v in board:GetChildren() do
			if v:IsA('Frame') then
				local plrname = v:FindFirstChild('PlayerName', true)
				local bounty = v:FindFirstChild('Bounty', true)
				if plrname and bounty then
					local num = tonumber((bounty.Text:gsub('[^%d]', ''))) or 0
					map[plrname.Text] = num
				end
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
			local b = board[plr.Name]
			if not b or b < min or not plr.Character then
				clear(plr)
			end
		end

		for _, ent in entitylib.List do
			local plr = ent.Player
			local b = plr and board[plr.Name]
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
	
	AutoArrest = vain.Categories.Blatant:CreateModule({
		Name = 'AutoArrest',
		Function = function(callback)
			if callback then
				repeat
					local item = jb.ItemSystemController:GetLocalEquipped()
					if item and item.__ClassName == 'Handcuffs' then
						local localPosition = entitylib.character.Humanoid.HumanoidUnloadServerPosition.Value
						local plrs = entitylib.AllPosition({
							Players = true,
							Part = 'RootPart',
							Range = 50
						})
	
						for _, ent in plrs do
							if not AutoArrest.Enabled then break end
							if ent.Player and isIllegal(ent) then
								local vehicle = ent.Humanoid.Sit and getVehicle(ent) or nil
								if vehicle then
									jb:FireServer('Eject', vehicle)
								elseif not isArrested(ent.Player.Name) and (localPosition - ent.RootPart.Position).Magnitude < 18.4 then
									jb:FireServer('Arrest', ent.Player.Name)
									task.wait(0.6)
								end
							end
						end
					end
					task.wait(0.016)
				until not AutoArrest.Enabled
			end
		end,
		Tooltip = 'Automatically uses handcuffs on nearby entities'
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
					item = item and item.__ClassName == 'Taser' or nil
					if not AutoTazeHandCheck.Enabled or item then
						local ent = entitylib.EntityPosition({
							Players = true,
							Part = 'RootPart',
							Range = 50
						})
	
						if ent and isIllegal(ent) and not isArrested(ent.Player.Name) then
							if item then 
								jb:FireServer('TaseReplicate', ent.Head.Position) 
							end
							jb:FireServer('Tase', ent.Humanoid, ent.Head, ent.Head.Position)
							task.wait(10)
						end
					end
					task.wait(0.016)
				until not AutoTaze.Enabled
			end
		end,
		Tooltip = 'Immobilizes entities around you'
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
		Enum.HumanoidStateType.PlatformStand,
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
	